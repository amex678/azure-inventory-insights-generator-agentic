[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HtmlPath,

    [Parameter(Mandatory)]
    [string]$RepositoryUrl
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $HtmlPath -PathType Leaf)) {
    throw "Report HTML not found: $HtmlPath"
}

$parsedRepositoryUrl = $null
if (-not [uri]::TryCreate($RepositoryUrl, [System.UriKind]::Absolute, [ref]$parsedRepositoryUrl) -or
    $parsedRepositoryUrl.Scheme -ne [System.Uri]::UriSchemeHttps) {
    throw 'RepositoryUrl must be an absolute HTTPS URL.'
}

$html = Get-Content -LiteralPath $HtmlPath -Raw -Encoding UTF8
if ($html -match 'data-repository-link\s*=') {
    Write-Host "Repository link already exists: $HtmlPath"
    return
}

$bodyMatch = [regex]::Match(
    $html,
    '<body\b[^>]*>',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
if (-not $bodyMatch.Success) {
    throw 'Report HTML does not contain a body element.'
}

$encodedRepositoryUrl = [System.Net.WebUtility]::HtmlEncode($parsedRepositoryUrl.AbsoluteUri)
$newLine = if ($html.Contains("`r`n")) { "`r`n" } else { "`n" }
$repositoryLink = @(
    '<nav data-repository-link="true" aria-label="リポジトリ" style="display:flex;justify-content:flex-end;align-items:center;padding:10px clamp(16px,4vw,32px);background:#fff;border-bottom:1px solid #d0d7de;font-family:&quot;Segoe UI&quot;,&quot;Meiryo&quot;,sans-serif;font-size:14px;line-height:1.5;">'
    ('  <a href="{0}" target="_blank" rel="noopener noreferrer" style="color:#0969da;text-decoration:underline;text-underline-offset:3px;">GitHub リポジトリ</a>' -f $encodedRepositoryUrl)
    '</nav>'
) -join $newLine

$insertionIndex = $bodyMatch.Index + $bodyMatch.Length
$updatedHtml = $html.Insert($insertionIndex, "$newLine$repositoryLink")
Set-Content -LiteralPath $HtmlPath -Value $updatedHtml -Encoding utf8NoBOM -NoNewline

Write-Host "Repository link added: $HtmlPath"