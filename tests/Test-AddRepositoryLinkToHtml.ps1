[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repositoryRoot 'scripts\Add-RepositoryLinkToHtml.ps1'
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "repository-link-test-$([guid]::NewGuid().ToString('N'))"
$htmlPath = Join-Path $testDirectory 'report.html'
$repositoryUrl = 'https://github.com/example/example-report'

$sourceHtml = @'
<!doctype html>
<html lang="ja">
<head><meta charset="utf-8"><title>Report</title></head>
<body class="report-body">
<header><h1>Azure レポート</h1></header>
</body>
</html>
'@

try {
    New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null
    $sourceHtml | Set-Content -LiteralPath $htmlPath -Encoding utf8NoBOM

    & $scriptPath -HtmlPath $htmlPath -RepositoryUrl $repositoryUrl
    & $scriptPath -HtmlPath $htmlPath -RepositoryUrl $repositoryUrl

    $result = Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8
    $bodyIndex = $result.IndexOf('<body class="report-body">', [System.StringComparison]::Ordinal)
    $linkIndex = $result.IndexOf('data-repository-link="true"', [System.StringComparison]::Ordinal)
    $headerIndex = $result.IndexOf('<header>', [System.StringComparison]::Ordinal)
    $linkCount = [regex]::Matches($result, 'data-repository-link\s*=', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count

    Assert-True ($bodyIndex -ge 0) 'The body element must be preserved.'
    Assert-True ($linkIndex -gt $bodyIndex -and $linkIndex -lt $headerIndex) 'The repository link must be the first visible content in the body.'
    Assert-True ($linkCount -eq 1) 'The repository link must not be inserted more than once.'
    Assert-True ($result.Contains(('href="{0}"' -f $repositoryUrl))) 'The repository URL is missing from the link.'
    Assert-True ($result.Contains('target="_blank" rel="noopener noreferrer"')) 'The external link must use safe target attributes.'

    Write-Host 'Add-RepositoryLinkToHtml tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testDirectory) {
        Remove-Item -LiteralPath $testDirectory -Recurse -Force
    }
}