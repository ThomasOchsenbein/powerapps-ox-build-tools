#Requires -Version 3
#Requires -Modules Microsoft.PowerShell.Utility

[CmdletBinding()]

param()


######################################################################################

# Convert https://orgname.crmx.dynamics.com to https://orgname.api.crmx.dynamics.com

function ConvertCdsUrlToApiUrl()
{

    Param
    (
        [parameter(Mandatory=$true)]
        [string] $cdsUrl
    )

    $result = [regex]::Match($cdsUrl,'\.crm.*\.dynamics\.com')

    if ( $result.Success -ne $true ) { throw "Invalid URL: $cdsUrl" }

    $pos = $result.Index

    if ( $pos -lt 10 ) { throw "Invalid URL pos: $cdsUrl" }
    
    $before = $cdsUrl.Substring(0,$pos)

    $after = $cdsUrl.Substring($pos)

    # If api already exists in the url don't change it...
    if ( $before.EndsWith('.api') )
        { return $cdsUrl }

    # Insert .api into url
    return ($before + '.api' + $after)

}



function GetAccessToken()
{

    Param
    (
        [parameter(Mandatory=$true)]
        [string] $cdsApiUrl, 
        [parameter(Mandatory=$true)]
        [string] $cdsUserName, 
        [parameter(Mandatory=$true)]
        [string] $cdsPassword 
    )

    $bodyEncoded = 
        "client_id=2ad88395-b77d-4561-9441-d0e40824f9bc&" + `
        "resource=" + [uri]::EscapeDataString($cdsApiUrl) + "&" + `
        "username=" + [uri]::EscapeDataString($cdsUserName) + "&" + `
        "password=" + [uri]::EscapeDataString($cdsPassword) + "&grant_type=password"

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Content-Type", "application/x-www-form-urlencoded")

    $response = Invoke-RestMethod 'https://login.microsoftonline.com/common/oauth2/token' `
        -Method 'POST' -Headers $headers -Body $bodyEncoded -ErrorVariable RestError

    if ($RestError)
    {
        $HttpStatusCode = $RestError.ErrorRecord.Exception.Response.StatusCode.value__
        $HttpStatusDescription = $RestError.ErrorRecord.Exception.Response.StatusDescription
    
        throw "Get token error. Http Status Code: $($HttpStatusCode) Http Status Description: $($HttpStatusDescription)"
    }

    if ( $response -eq $null -or -not( $response.PSObject.Properties['access_token'] ) )
        { throw ("access token not returned for " + $cdsApiUrl) }

    return $response.PSObject.Properties['access_token'].value

}       #function GetAccessToken()



function GetWebHookId()
{

    Param
    (
        [parameter(Mandatory=$true)]
        [string] $cdsApiUrl, 
        [parameter(Mandatory=$true)]
        [string] $cdsAccessToken, 
        [parameter(Mandatory=$true)]
        [string] $cdsWebHookName
    )

    $bearer = ("Bearer " + $cdsAccessToken)

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Accept", "application/json")
    $headers.Add("OData-Version", "4.0")
    $headers.Add("OData-MaxVersion", "4.0")
    $headers.Add("Authorization", $bearer)

    $filterValue = `
        "name eq '$cdsWebHookName' and contract eq 8"

    $invokeUrl =
        $cdsApiUrl.TrimEnd('/') + `
        "/api/data/v9.0/serviceendpoints?`$select=serviceendpointid,name,contract,authtype&`$filter=$filterValue"

    $response = Invoke-WebRequest $invokeUrl -Method 'GET' -Headers $headers -UseBasicParsing

    if ( $response -eq $null  )
        { throw "Error retrieving webhook - response is null.  $invokeUrl" }

    $responseObj = ConvertFrom-Json -InputObject $response

    if( -not ( $responseObj.psobject.properties.match('value') ) )
        { throw "Error retrieving webhook - value is missing.  $invokeUrl" }

    if( ($responseObj.value).Count -ne 1 )
        { throw "Error retrieving webhook - not found.  $invokeUrl" }

    return $responseObj.value[0].serviceendpointid

}        # GetWebHookId



function UpdateWebHook()
{

    Param
    (
        [parameter(Mandatory=$true)]
        [string] $cdsApiUrl, 
        [parameter(Mandatory=$true)]
        [string] $cdsAccessToken, 
        [parameter(Mandatory=$true)]
        [string] $webHookId, 
        [parameter(Mandatory=$true)]
        [string] $whUrl,
        [parameter(Mandatory=$true)]
        [int]    $whAuthtype, 
        [parameter(Mandatory=$true)]
        [string] $whAuthvalue    # Example: '[{ "x-functions-key": "miRV3be3uwLYw==", "subscription": "4a97b09b-45cd-4a9a-8734-d9cb8de77758" }]'
    )

    $bearer = "Bearer " + $cdsAccessToken

    $whAuthValueJson = ConvertFrom-Json -InputObject $whAuthvalue
    if( ($whAuthValueJson).Count -ne 1 )
        { throw "Authvalue is invalid.  $whAuthValue" }

    #authValue needs to be in xml format e.g.
    #"<settings><setting name="x-functions-key" value="okbD3brCfcT2kKtQ/K02==" /></settings>"

    $whAuthValueXml = '<settings>'

    foreach($objProperties in $whAuthValueJson[0].PSObject.Properties)
    {
        $whAuthValueXml += `
        '<setting name="' + $objProperties.Name + '" value="' + $objProperties.Value + '" />'
    }

    $whAuthValueXml += '</settings>'

    #submit the PATCH webapi call

    $invokeUrl =
        $cdsApiUrl.TrimEnd('/') + "/api/data/v9.0/serviceendpoints(" + $webHookId + ")"

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Content-Type", "application/json;charset=utf-8")
    $headers.Add("Accept", "application/json")
    $headers.Add("OData-Version", "4.0")
    $headers.Add("OData-MaxVersion", "4.0")
    $headers.Add("Authorization", $bearer)

    [HashTable]$Body = @{
      url = $whUrl
      authtype = $whAuthtype
      authvalue = $whAuthValueXml
    }

    $bodyJson = ConvertTo-Json -InputObject $body

    $response = Invoke-RestMethod -Uri $invokeUrl -Method 'PATCH' `
        -Headers $headers -Body $bodyJson -ContentType "application/json" -UseBasicParsing -ErrorVariable RestError
    
    if ($RestError)
    {
        $HttpStatusCode = $RestError.ErrorRecord.Exception.Response.StatusCode.value__
        $HttpStatusDescription = $RestError.ErrorRecord.Exception.Response.StatusDescription
    
        throw "Update WebHook error. Http Status Code: $($HttpStatusCode) Http Status Description: $($HttpStatusDescription)"
    }

    return $true

}        # UpdateWebHook



######################################################################################



$powerAppsEnvironmentURL = Get-VstsInput -Name 'powerAppsEnvironmentURL' -Require

$webHookName = Get-VstsInput -Name 'webHookName' -Require

$webHookUrl = Get-VstsInput -Name 'webHookUrl' -Require

$webAuthType = 5 #Http Header

$webAuthValue = Get-VstsInput -Name 'webHookKeyValues' -Require

$cdsEndPoint = Get-VstsEndpoint $powerAppsEnvironmentURL

$cdsUrl = $cdsEndPoint.Url

$cdsUserName = $cdsEndPoint.Auth.parameters.username

$cdsPassword = $cdsEndPoint.Auth.parameters.password

$cdsApiUrl = ConvertCdsUrlToApiUrl $cdsUrl

Write-Host "Initial parameters:"

Write-Host "powerAppsEnvironmentURL = $powerAppsEnvironmentURL"

Write-Host "cdsUrl = $cdsUrl"

Write-Host "cdsApiUrl = $cdsApiUrl"

Write-Host "webHookName = $webHookName"

Write-Host "webHookUrl = $webHookUrl"

Write-Host "----------"

Write-Host "Logging in to CDS...."

$accessToken = GetAccessToken $cdsApiUrl $cdsUserName $cdsPassword

Write-Host "Login successful."

Write-Host "Retrieving WebHook ID...."

$webHookId = GetWebHookId $cdsApiUrl $accessToken $webHookName

Write-Host "Webhook found. ID: $webHookId"

Write-Host "Updating WebHook configuration...."

$result = UpdateWebHook $cdsApiUrl $accessToken $webHookId $webHookUrl $webAuthType $webAuthValue

Write-Host "Update successful."



######################################################################################
