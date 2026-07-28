[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$validationScript = Join-Path $repositoryRoot 'scripts\Test-AzAgentReport.ps1'
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "az-agent-report-test-$([guid]::NewGuid().ToString('N'))"
$validReport = Join-Path $testDirectory 'valid.html'
$validDivReport = Join-Path $testDirectory 'valid-div.html'
$validUnlabeledReport = Join-Path $testDirectory 'valid-unlabeled.html'
$missingAssessmentReport = Join-Path $testDirectory 'missing-assessment.html'
$invalidReport = Join-Path $testDirectory 'invalid.html'

$validHtml = @'
<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>Azure report</title></head><body>
<h1>Azure 棚卸し分析レポート</h1>
<h2>エグゼクティブサマリー</h2><h3>総評</h3><p>本環境は複数の Azure リソースで構成され、収集済みデータから公開境界と特権境界の状態を確認できます。最優先事項は重大度の高い推奨事項の精査と、影響範囲に基づく是正順序の決定です。既存統制が機能している領域も維持しながら、追加確認が必要な項目を担当者と期限に結び付けて継続的に改善します。</p><h3>主要懸念事項</h3><ul><li>要確認</li></ul><h3>強み・確認できた統制</h3><ul><li>取得済み</li></ul>
<h2>全体サマリー表</h2><table><tr><td>Resources</td></tr></table>
<h2>潜在リスク Top 5</h2><p>優先度 高</p>
<h2>30日アクションプラン</h2><h3>0〜7日</h3><h3>8〜14日</h3><h3>15〜30日</h3>
<h2>データ詳細</h2><p>集計</p>
<h2>前提・制約</h2><p>匿名化済み</p>
</body></html>
'@

$validDivHtml = $validHtml -replace '<h3>総評</h3><p>(.*?)</p>', '<div class="summary-text"><strong>総評：</strong>$1</div>'
$validUnlabeledHtml = $validHtml -replace '<h3>総評</h3>', ''
$missingAssessmentHtml = $validHtml -replace '<h3>総評</h3><p>.*?</p>', ''

$invalidHtml = @'
<!doctype html><html lang="ja"><body>
<h1>Azure 棚卸し分析レポート</h1>
<h2>全体サマリー表</h2>
<h2>エグゼクティブサマリー</h2><h3>総評</h3><h3>主要懸念事項</h3><h3>強み</h3>
<h2>潜在リスク Top 5</h2><h2>30日アクションプラン</h2><p>0〜7日 8〜14日 15〜30日</p>
<h2>データ詳細</h2><h2>前提・制約</h2><script>alert(1)</script>
</body></html>
'@

try {
    New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null
    $validHtml | Set-Content -LiteralPath $validReport -Encoding UTF8
    $validDivHtml | Set-Content -LiteralPath $validDivReport -Encoding UTF8
    $validUnlabeledHtml | Set-Content -LiteralPath $validUnlabeledReport -Encoding UTF8
    $missingAssessmentHtml | Set-Content -LiteralPath $missingAssessmentReport -Encoding UTF8
    $invalidHtml | Set-Content -LiteralPath $invalidReport -Encoding UTF8

    & $validationScript -HtmlPath $validReport
    & $validationScript -HtmlPath $validDivReport
    & $validationScript -HtmlPath $validUnlabeledReport

    $missingAssessmentRejected = $false
    try {
        & $validationScript -HtmlPath $missingAssessmentReport
    }
    catch {
        $missingAssessmentRejected = $_.Exception.Message -match 'OverallAssessment'
    }
    Assert-True $missingAssessmentRejected 'Validation must reject a report without a substantive overall assessment.'

    $invalidRejected = $false
    try {
        & $validationScript -HtmlPath $invalidReport
    }
    catch {
        $invalidRejected = $true
    }
    Assert-True $invalidRejected 'Validation must reject a report with incorrect section order and script content.'

    Write-Host 'Agent report tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testDirectory) {
        Remove-Item -LiteralPath $testDirectory -Recurse -Force
    }
}