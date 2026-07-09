[CmdletBinding()]
param(
    [string]$ResourcesJson = (Join-Path $PSScriptRoot '..\output\resources.json'),
    [string]$RbacJson      = (Join-Path $PSScriptRoot '..\output\rbac.json'),
    [string]$NsgJson       = (Join-Path $PSScriptRoot '..\output\nsg-rules.json'),
    [string]$DefenderJson  = (Join-Path $PSScriptRoot '..\output\defender-recommendations.json'),
    [string]$AdvisorJson   = (Join-Path $PSScriptRoot '..\output\advisor-recommendations.json'),
    [string]$HtmlPath      = (Join-Path $PSScriptRoot '..\output\comprehensive-report.html'),
    [string]$EvidencePath  = (Join-Path $PSScriptRoot '..\output\report-evidence.json')
)

$ErrorActionPreference = 'Stop'

function Read-JsonArray([string]$path) {
    if (-not (Test-Path $path)) { return @() }
    $raw = Get-Content -Path $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $data = $raw | ConvertFrom-Json
    if ($null -eq $data) { return @() }
    return @($data)
}

if (-not (Test-Path $HtmlPath)) {
    throw "Report HTML not found: $HtmlPath"
}

$html = Get-Content -Path $HtmlPath -Raw -Encoding UTF8

$requiredSectionPatterns = @(
    @{ Name = 'エグゼクティブサマリ'; Pattern = 'エグゼクティブ\s*サマリ' },
    @{ Name = '全体サマリ(表)'; Pattern = '全体\s*サマリ(表)?' },
    @{ Name = '潜在リスク Top 5'; Pattern = '潜在\s*リスク\s*Top\s*5' },
    @{ Name = '30日アクションプラン'; Pattern = '30\s*日\s*アクション\s*プラン' }
)

foreach ($section in $requiredSectionPatterns) {
    if ($html -notmatch $section.Pattern) {
        throw "Required section missing: $($section.Name)"
    }
}

if ((Test-Path $EvidencePath) -and $html -match '<script[\s>]') {
    throw 'Generated AI HTML contains script tag, which is not allowed.'
}

$resources = Read-JsonArray $ResourcesJson
$rbac      = Read-JsonArray $RbacJson
$nsg       = Read-JsonArray $NsgJson
$defender  = Read-JsonArray $DefenderJson
$advisor   = Read-JsonArray $AdvisorJson

$expectedResourceTotal = $resources.Count
$expectedOwner = @($rbac | Where-Object RoleDefinitionName -eq 'Owner').Count
$expectedRiskyNsg = @($nsg | Where-Object { $_.IsRiskyMgmtFromInternet -eq $true -or $_.IsRiskyMgmtFromInternet -eq 'True' }).Count
$expectedDefenderUnhealthy = @($defender | Where-Object Status -eq 'Unhealthy').Count
$expectedAdvisorHigh = @($advisor | Where-Object Impact -eq 'High').Count

# 根拠数値の少なくとも一部が本文中に現れていることを簡易検証
$mustContain = @(
    "$expectedResourceTotal",
    "$expectedOwner",
    "$expectedRiskyNsg",
    "$expectedDefenderUnhealthy",
    "$expectedAdvisorHigh"
)

$missing = @()
foreach ($v in $mustContain) {
    if ([string]::IsNullOrWhiteSpace($v)) { continue }
    if ($html -notmatch [regex]::Escape($v)) {
        $missing += $v
    }
}

if ($missing.Count -ge 3) {
    throw "Too many metric values are missing from report body: $($missing -join ', ')"
}

Write-Host 'Report validation passed.'
