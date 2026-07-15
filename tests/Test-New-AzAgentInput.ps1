[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "$Message Expected: '$Expected'. Actual: '$Actual'."
    }
}

function Assert-False([bool]$Condition, [string]$Message) {
    if ($Condition) {
        throw $Message
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repositoryRoot 'scripts\New-AzAgentInput.ps1'
$fixturePath = Join-Path $PSScriptRoot 'fixtures\agent-input'
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "az-agent-input-test-$([guid]::NewGuid().ToString('N'))"
$firstOutput = Join-Path $testDirectory 'first.json'
$secondOutput = Join-Path $testDirectory 'second.json'
$generatedAt = '2026-07-15T00:00:00Z'

try {
    & $scriptPath -InputDirectory $fixturePath -OutputPath $firstOutput -GeneratedAt $generatedAt -MaxRiskSamples 3
    & $scriptPath -InputDirectory $fixturePath -OutputPath $secondOutput -GeneratedAt $generatedAt -MaxRiskSamples 3

    $firstRaw = Get-Content -LiteralPath $firstOutput -Raw -Encoding UTF8
    $secondRaw = Get-Content -LiteralPath $secondOutput -Raw -Encoding UTF8
    Assert-Equal $firstRaw $secondRaw 'Output must be deterministic for the same input and generatedAt value.'

    $summary = $firstRaw | ConvertFrom-Json
    Assert-Equal '1.0' $summary.schemaVersion 'Unexpected schema version.'
    Assert-Equal $generatedAt $summary.generatedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') 'Unexpected generation timestamp.'
    Assert-Equal 2 $summary.metrics.resourceTotal 'Unexpected resource count.'
    Assert-Equal 3 $summary.metrics.roleAssignmentTotal 'Unexpected role assignment count.'
    Assert-Equal 2 $summary.metrics.ownerAssignmentTotal 'Unexpected Owner count.'
    Assert-Equal 1 $summary.metrics.riskyNsgRuleTotal 'Unexpected risky NSG count.'
    Assert-Equal 1 $summary.metrics.defenderUnhealthyTotal 'Unexpected Defender unhealthy count.'
    Assert-Equal 1 $summary.metrics.defenderHighSeverityTotal 'Unexpected Defender high-severity count.'
    Assert-Equal 1 $summary.metrics.advisorHighImpactTotal 'Unexpected Advisor high-impact count.'
    Assert-False (@($summary.topRiskSamples).Count -gt 3) 'Risk samples exceed the configured maximum.'

    $sensitivePatterns = [ordered]@{
        SubscriptionPath = '(?i)/subscriptions/'
        Guid = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b'
        IpAddress = '\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b'
        Email = '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'
        ForbiddenField = '(?i)"(?:SubscriptionId|TenantId|ResourceId|ResourceGroupName|ResourceName|DisplayName|SignInName|ObjectId|Scope|NsgName|SourceAddressPrefix|DestinationAddressPrefix|Problem|Solution|Description)"\s*:'
        FixtureSecret = '(?i)secret|rg-secret-prod|vm-secret-prod-01|storage-secret-prod'
    }

    foreach ($pattern in $sensitivePatterns.GetEnumerator()) {
        Assert-False ($firstRaw -match $pattern.Value) "Sensitive pattern found in output: $($pattern.Key)."
    }

    Write-Host 'New-AzAgentInput tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testDirectory) {
        Remove-Item -LiteralPath $testDirectory -Recurse -Force
    }
}