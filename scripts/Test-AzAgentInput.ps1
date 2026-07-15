[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InputPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "Agent input not found: $InputPath"
}

$raw = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($raw)) {
    throw 'Agent input is empty.'
}

$summary = $raw | ConvertFrom-Json
$requiredDomains = @('resources', 'rbac', 'nsg', 'defender', 'advisor')
foreach ($domain in $requiredDomains) {
    $availability = $summary.dataAvailability.PSObject.Properties[$domain]
    if ($null -eq $availability -or $availability.Value.available -ne $true) {
        throw "Required data domain is unavailable: $domain"
    }
}

if ($summary.schemaVersion -ne '1.0') {
    throw "Unsupported agent input schema: $($summary.schemaVersion)"
}

$sensitivePatterns = [ordered]@{
    SubscriptionPath = '(?i)/subscriptions/'
    Guid = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b'
    IpAddress = '\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b'
    Email = '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'
    ForbiddenField = '(?i)"(?:SubscriptionId|TenantId|ResourceId|ResourceGroupName|ResourceName|DisplayName|SignInName|ObjectId|Scope|NsgName|SourceAddressPrefix|DestinationAddressPrefix|Problem|Solution|Description)"\s*:'
}

foreach ($pattern in $sensitivePatterns.GetEnumerator()) {
    if ($raw -match $pattern.Value) {
        throw "Sensitive pattern found in agent input: $($pattern.Key)"
    }
}

Write-Host "Agent input validation passed: $InputPath"