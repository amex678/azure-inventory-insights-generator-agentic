[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HtmlPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $HtmlPath -PathType Leaf)) {
    throw "Agent report not found: $HtmlPath"
}

$html = Get-Content -LiteralPath $HtmlPath -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($html)) {
    throw 'Agent report is empty.'
}

$requiredSections = [ordered]@{
    ExecutiveSummary = 'エグゼクティブ\s*サマリ(?:ー)?'
    OverallSummary = '全体\s*サマリ(?:ー)?\s*表'
    TopRisks = '潜在\s*リスク\s*Top\s*5'
    ActionPlan = '30\s*日\s*アクション\s*プラン'
    DataDetails = 'データ\s*詳細'
    Assumptions = '前提\s*[・･]\s*制約'
}

$positions = [ordered]@{}
foreach ($section in $requiredSections.GetEnumerator()) {
    $match = [regex]::Match($html, $section.Value, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "Required section missing: $($section.Key)"
    }
    $positions[$section.Key] = $match.Index
}

$previousPosition = -1
foreach ($sectionName in $requiredSections.Keys) {
    if ($positions[$sectionName] -le $previousPosition) {
        throw "Report sections are out of order near: $sectionName"
    }
    $previousPosition = $positions[$sectionName]
}

$firstSecondaryHeading = [regex]::Match($html, '<h2\b[^>]*>(?<text>.*?)</h2>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $firstSecondaryHeading.Success -or $firstSecondaryHeading.Groups['text'].Value -notmatch $requiredSections.ExecutiveSummary) {
    throw 'Executive Summary must be the first H2 section.'
}

$requiredNarrativePatterns = [ordered]@{
    OverallAssessment = '総評'
    Concerns = '主要\s*懸念\s*事項'
    Strengths = '強み(?:\s*[・･]\s*確認できた統制)?'
    FirstWeek = '0\s*[〜～-]\s*7\s*日'
    SecondWeek = '8\s*[〜～-]\s*14\s*日'
    FinalPeriod = '15\s*[〜～-]\s*30\s*日'
}

foreach ($pattern in $requiredNarrativePatterns.GetEnumerator()) {
    if ($html -notmatch $pattern.Value) {
        throw "Required report content missing: $($pattern.Key)"
    }
}

$forbiddenPatterns = [ordered]@{
    Script = '<script\b'
    ExternalResource = '(?i)(?:src|href)\s*=\s*["'']\s*(?:https?:)?//'
    Form = '<form\b'
    InlineEventHandler = '(?i)\son[a-z]+\s*='
}

foreach ($pattern in $forbiddenPatterns.GetEnumerator()) {
    if ($html -match $pattern.Value) {
        throw "Forbidden HTML content found: $($pattern.Key)"
    }
}

Write-Host "Agent report validation passed: $HtmlPath"