[CmdletBinding()]
param(
    [string]$InputDirectory = (Join-Path $PSScriptRoot '..\output'),
    [string]$OutputPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'gh-aw\agent\inventory-summary.json'),
    [Nullable[datetimeoffset]]$GeneratedAt,
    [ValidateRange(0, 20)]
    [int]$MaxRiskSamples = 5
)

$ErrorActionPreference = 'Stop'

function Read-JsonArray([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $data = $raw | ConvertFrom-Json
    if ($null -eq $data) {
        return @()
    }

    return @($data)
}

function Get-SafeValue($InputObject, [string]$PropertyName, [string]$Fallback = 'Unknown') {
    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        return $Fallback
    }

    return [string]$property.Value
}

function Get-CountMap([object[]]$Items, [string]$PropertyName, [int]$Limit = 10) {
    $map = [ordered]@{}
    $groups = @($Items | Group-Object -Property $PropertyName | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } | Select-Object -First $Limit)

    foreach ($group in $groups) {
        $name = if ([string]::IsNullOrWhiteSpace($group.Name)) { 'Unknown' } else { $group.Name }
        $map[$name] = $group.Count
    }

    return $map
}

$paths = [ordered]@{
    resources = Join-Path $InputDirectory 'resources.json'
    rbac = Join-Path $InputDirectory 'rbac.json'
    nsg = Join-Path $InputDirectory 'nsg-rules.json'
    defender = Join-Path $InputDirectory 'defender-recommendations.json'
    advisor = Join-Path $InputDirectory 'advisor-recommendations.json'
}

$resources = Read-JsonArray $paths.resources
$rbac = Read-JsonArray $paths.rbac
$nsg = Read-JsonArray $paths.nsg
$defender = Read-JsonArray $paths.defender
$advisor = Read-JsonArray $paths.advisor

$riskyNsg = @($nsg | Where-Object { $_.IsRiskyMgmtFromInternet -eq $true -or $_.IsRiskyMgmtFromInternet -eq 'True' })
$defenderUnhealthy = @($defender | Where-Object Status -eq 'Unhealthy')
$defenderHigh = @($defenderUnhealthy | Where-Object Severity -eq 'High')
$advisorHigh = @($advisor | Where-Object Impact -eq 'High')
$ownerAssignments = @($rbac | Where-Object RoleDefinitionName -eq 'Owner')

$riskCandidates = @()

$nsgGroups = @($riskyNsg | Group-Object -Property Protocol, DestinationPortRange | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
foreach ($group in $nsgGroups) {
    $first = $group.Group[0]
    $riskCandidates += [pscustomobject][ordered]@{
        riskType = 'NsgInternetManagementExposure'
        severity = 'High'
        category = 'Network'
        resourceType = 'Microsoft.Network/networkSecurityGroups'
        protocol = Get-SafeValue $first 'Protocol'
        destinationPort = Get-SafeValue $first 'DestinationPortRange'
        count = $group.Count
        sortRank = 1
    }
}

$defenderGroups = @($defenderUnhealthy | Group-Object -Property Severity, RecommendationCategory, ResourceType | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
foreach ($group in $defenderGroups) {
    $first = $group.Group[0]
    $severity = Get-SafeValue $first 'Severity'
    $rank = switch ($severity) {
        'High' { 1 }
        'Medium' { 2 }
        'Low' { 3 }
        default { 4 }
    }
    $riskCandidates += [pscustomobject][ordered]@{
        riskType = 'DefenderRecommendation'
        severity = $severity
        category = Get-SafeValue $first 'RecommendationCategory'
        resourceType = Get-SafeValue $first 'ResourceType'
        count = $group.Count
        sortRank = $rank
    }
}

$advisorGroups = @($advisor | Group-Object -Property Impact, Category, ResourceType | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
foreach ($group in $advisorGroups) {
    $first = $group.Group[0]
    $impact = Get-SafeValue $first 'Impact'
    $rank = switch ($impact) {
        'High' { 1 }
        'Medium' { 2 }
        'Low' { 3 }
        default { 4 }
    }
    $riskCandidates += [pscustomobject][ordered]@{
        riskType = 'AdvisorRecommendation'
        severity = $impact
        category = Get-SafeValue $first 'Category'
        resourceType = Get-SafeValue $first 'ResourceType'
        count = $group.Count
        sortRank = $rank
    }
}

$topRiskSamples = @($riskCandidates | Sort-Object -Property sortRank, @{ Expression = 'count'; Descending = $true }, riskType, category, resourceType | Select-Object -First $MaxRiskSamples | ForEach-Object {
    $sample = [ordered]@{
        riskType = $_.riskType
        severity = $_.severity
        category = $_.category
        resourceType = $_.resourceType
        count = $_.count
    }
    if ($_.riskType -eq 'NsgInternetManagementExposure') {
        $sample.protocol = $_.protocol
        $sample.destinationPort = $_.destinationPort
    }
    [pscustomobject]$sample
})

$timestamp = if ($PSBoundParameters.ContainsKey('GeneratedAt')) { $GeneratedAt.ToUniversalTime() } else { [datetimeoffset]::UtcNow }

$summary = [pscustomobject][ordered]@{
    schemaVersion = '1.0'
    generatedAt = $timestamp.ToString('yyyy-MM-ddTHH:mm:ssZ')
    dataAvailability = [pscustomobject][ordered]@{
        resources = [pscustomobject][ordered]@{ available = Test-Path -LiteralPath $paths.resources; count = $resources.Count }
        rbac = [pscustomobject][ordered]@{ available = Test-Path -LiteralPath $paths.rbac; count = $rbac.Count }
        nsg = [pscustomobject][ordered]@{ available = Test-Path -LiteralPath $paths.nsg; count = $nsg.Count }
        defender = [pscustomobject][ordered]@{ available = Test-Path -LiteralPath $paths.defender; count = $defender.Count }
        advisor = [pscustomobject][ordered]@{ available = Test-Path -LiteralPath $paths.advisor; count = $advisor.Count }
    }
    metrics = [pscustomobject][ordered]@{
        resourceTotal = $resources.Count
        roleAssignmentTotal = $rbac.Count
        ownerAssignmentTotal = $ownerAssignments.Count
        nsgRuleTotal = $nsg.Count
        riskyNsgRuleTotal = $riskyNsg.Count
        defenderRecommendationTotal = $defender.Count
        defenderUnhealthyTotal = $defenderUnhealthy.Count
        defenderHighSeverityTotal = $defenderHigh.Count
        advisorRecommendationTotal = $advisor.Count
        advisorHighImpactTotal = $advisorHigh.Count
    }
    riskSummary = [pscustomobject][ordered]@{
        defenderBySeverity = Get-CountMap $defenderUnhealthy 'Severity'
        defenderByCategory = Get-CountMap $defenderUnhealthy 'RecommendationCategory'
        advisorByImpact = Get-CountMap $advisor 'Impact'
        advisorByCategory = Get-CountMap $advisor 'Category'
    }
    topRiskSamples = $topRiskSamples
    governanceSummary = [pscustomobject][ordered]@{
        resourcesByType = Get-CountMap $resources 'ResourceType'
        roleAssignmentsByScope = Get-CountMap $rbac 'ScopeKind'
        roleAssignmentsByPrincipalType = Get-CountMap $rbac 'ObjectType'
    }
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Agent input written: $OutputPath"