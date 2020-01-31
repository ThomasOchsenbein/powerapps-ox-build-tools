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



function GetServiceBusEndPointId()
{

    Param
    (
        [parameter(Mandatory=$true)]
        [string] $cdsApiUrl, 
        [parameter(Mandatory=$true)]
        [string] $cdsAccessToken, 
        [parameter(Mandatory=$true)]
        [string] $cdsServiceBusEndPointName
    )

    $bearer = ("Bearer " + $cdsAccessToken)

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Accept", "application/json")
    $headers.Add("OData-Version", "4.0")
    $headers.Add("OData-MaxVersion", "4.0")
    $headers.Add("Authorization", $bearer)

    $filterValue = `
        "name eq '$cdsServiceBusEndPointName' and authtype eq 2 and contract ne 8"

    $invokeUrl =
        $cdsApiUrl.TrimEnd('/') + `
        "/api/data/v9.0/serviceendpoints?`$select=serviceendpointid,name,contract,authtype&`$filter=$filterValue"

    $response = Invoke-WebRequest $invokeUrl -Method 'GET' -Headers $headers -UseBasicParsing

    if ( $response -eq $null  )
        { throw "Error retrieving service endpoint - response is null.  $invokeUrl" }

    $responseObj = ConvertFrom-Json -InputObject $response

    if( -not ( $responseObj.psobject.properties.match('value') ) )
        { throw "Error retrieving service endpoint - value is missing.  $invokeUrl" }

    if( ($responseObj.value).Count -ne 1 )
        { throw "Error retrieving service endpoint - not found.  $invokeUrl" }

    return $responseObj.value[0].serviceendpointid

}        # GetServiceBusEndPointId



function UpdateServiceBusEndPoint()
{

    Param
    (
        [parameter(Mandatory=$true)]
        [string] $cdsApiUrl, 
        [parameter(Mandatory=$true)]
        [string] $cdsAccessToken, 
        [parameter(Mandatory=$true)]
        [string] $serviceBusEndPointId, 
        [parameter(Mandatory=$true)]
        [string] $sbUrl,
        [parameter(Mandatory=$true)]
        [string] $sbSASKeyName, 
        [parameter(Mandatory=$true)]
        [string] $sbSASKey
    )

    $bearer = "Bearer " + $cdsAccessToken

    #submit the PATCH webapi call

    $invokeUrl =
        $cdsApiUrl.TrimEnd('/') + "/api/data/v9.0/serviceendpoints(" + $serviceBusEndPointId + ")"

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Content-Type", "application/json;charset=utf-8")
    $headers.Add("Accept", "application/json")
    $headers.Add("OData-Version", "4.0")
    $headers.Add("OData-MaxVersion", "4.0")
    $headers.Add("Authorization", $bearer)

    [HashTable]$body = @{
      namespaceaddress = $sbUrl
      saskeyname = $sbSASKeyName
      saskey = $sbSASKey
    }

    $bodyJson = ConvertTo-Json -InputObject $body

    $response = Invoke-RestMethod -Uri $invokeUrl -Method 'PATCH' `
        -Headers $headers -Body $bodyJson -ContentType "application/json" -UseBasicParsing -ErrorVariable RestError
    
    if ($RestError)
    {
        $HttpStatusCode = $RestError.ErrorRecord.Exception.Response.StatusCode.value__
        $HttpStatusDescription = $RestError.ErrorRecord.Exception.Response.StatusDescription
    
        throw "Update Service EndPoint error. Http Status Code: $($HttpStatusCode) Http Status Description: $($HttpStatusDescription)"
    }

    return $true

}        # UpdateServiceBusEndPoint



######################################################################################



$powerAppsEnvironmentURL = Get-VstsInput -Name 'powerAppsEnvironmentURL' -Require

$serviceEndPointName = Get-VstsInput -Name 'serviceEndPointName' -Require

$serviceEndPointUrl = Get-VstsInput -Name 'serviceEndPointUrl' -Require

$serviceEndPointSASKeyName = Get-VstsInput -Name 'serviceEndPointSASKeyName' -Require

$serviceEndPointSASKey = Get-VstsInput -Name 'serviceEndPointSASKey' -Require

$cdsEndPoint = Get-VstsEndpoint $powerAppsEnvironmentURL

$cdsUrl = $cdsEndPoint.Url

$cdsUserName = $cdsEndPoint.Auth.parameters.username

$cdsPassword = $cdsEndPoint.Auth.parameters.password

$cdsApiUrl = ConvertCdsUrlToApiUrl $cdsUrl

Write-Host "Initial parameters:"

Write-Host "powerAppsEnvironmentURL = $powerAppsEnvironmentURL"

Write-Host "cdsUrl = $cdsUrl"

Write-Host "cdsApiUrl = $cdsApiUrl"

Write-Host "serviceEndPointName = $serviceEndPointName"

Write-Host "serviceEndPointUrl = $serviceEndPointUrl"

Write-Host "serviceEndPointSASKeyName = $serviceEndPointSASKeyName"

Write-Host "----------"

Write-Host "Logging in to CDS...."

$accessToken = GetAccessToken $cdsApiUrl $cdsUserName $cdsPassword

Write-Host "Login successful."

Write-Host "Retrieving Service EndPoint ID...."

$serviceEndPointId = GetServiceBusEndPointId $cdsApiUrl $accessToken $serviceEndPointName

Write-Host "Service EndPoint found. ID: $serviceEndPointId"

Write-Host "Updating Service EndPoint configuration...."

$result = UpdateServiceBusEndPoint $cdsApiUrl $accessToken $serviceEndPointId `
            $serviceEndPointUrl $serviceEndPointSASKeyName $serviceEndPointSASKey

Write-Host "Update successful."



######################################################################################
