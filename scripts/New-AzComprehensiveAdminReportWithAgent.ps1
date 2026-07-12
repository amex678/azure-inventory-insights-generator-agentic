<#
.SYNOPSIS
    Agentic workflow 向けに、AI を使って Azure 棚卸しデータから
    comprehensive-report.html を生成する。

.DESCRIPTION
    - 入力 JSON から compact data を構築
    - prompt seed と結合して AI に HTML 生成を依頼
    - 生成結果を最小限検証して保存
    - 失敗時はルールベース生成へフォールバック
#>
[CmdletBinding()]
param(
    [string]$ResourcesJson = (Join-Path $PSScriptRoot '..\output\resources.json'),
    [string]$RbacJson      = (Join-Path $PSScriptRoot '..\output\rbac.json'),
    [string]$NsgJson       = (Join-Path $PSScriptRoot '..\output\nsg-rules.json'),
    [string]$DefenderJson  = (Join-Path $PSScriptRoot '..\output\defender-recommendations.json'),
    [string]$AdvisorJson   = (Join-Path $PSScriptRoot '..\output\advisor-recommendations.json'),
    [string]$PromptFile    = (Join-Path $PSScriptRoot '..\.github\prompts\azure-comprehensive-report.prompt.md'),
    [string]$OutputPath    = (Join-Path $PSScriptRoot '..\output\comprehensive-report.html'),
    [string]$EvidencePath  = (Join-Path $PSScriptRoot '..\output\report-evidence.json'),
    [string]$ApiEndpoint   = $(if ($env:AI_REPORT_API_ENDPOINT) { $env:AI_REPORT_API_ENDPOINT } else { 'https://models.inference.ai.azure.com/chat/completions' }),
    [string]$Model         = $(if ($env:AI_REPORT_MODEL) { $env:AI_REPORT_MODEL } else { 'gpt-4o-mini' }),
    [switch]$FailOnError
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

function Build-CompactInput {
    param(
        [array]$Resources,
        [array]$Rbac,
        [array]$Nsg,
        [array]$Defender,
        [array]$Advisor
    )

    $nsgRisky = @($Nsg | Where-Object { $_.IsRiskyMgmtFromInternet -eq $true -or $_.IsRiskyMgmtFromInternet -eq 'True' }).Count
    $defUnhealthy = @($Defender | Where-Object Status -eq 'Unhealthy').Count
    $defHigh = @($Defender | Where-Object { $_.Status -eq 'Unhealthy' -and $_.Severity -eq 'High' }).Count
    $advHigh = @($Advisor | Where-Object Impact -eq 'High').Count
    $untagged = @($Resources | Where-Object { [string]::IsNullOrWhiteSpace($_.Tags) }).Count
    $tagCoverage = if ($Resources.Count -gt 0) { [math]::Round((($Resources.Count - $untagged) / $Resources.Count) * 100, 1) } else { 0 }

    [ordered]@{
        generatedAt = (Get-Date).ToString('o')
        metrics = [ordered]@{
            resourcesTotal = $Resources.Count
            resourceGroups = ($Resources | Group-Object ResourceGroupName).Count
            regions = ($Resources | Group-Object Location).Count
            ownerAssignments = @($Rbac | Where-Object RoleDefinitionName -eq 'Owner').Count
            uaaAssignments = @($Rbac | Where-Object RoleDefinitionName -eq 'User Access Administrator').Count
            orphanAssignments = @($Rbac | Where-Object { [string]::IsNullOrWhiteSpace($_.DisplayName) }).Count
            nsgRisky = $nsgRisky
            defenderUnhealthy = $defUnhealthy
            defenderHigh = $defHigh
            advisorHigh = $advHigh
            tagCoverage = $tagCoverage
        }
        samples = [ordered]@{
            riskyNsgRules = @(
                $Nsg | Where-Object { $_.IsRiskyMgmtFromInternet -eq $true -or $_.IsRiskyMgmtFromInternet -eq 'True' } |
                Select-Object -First 20 NsgName, RuleName, Priority, Direction, Access, SourceAddressPrefix, DestinationPortRange
            )
            defenderUnhealthy = @(
                $Defender | Where-Object Status -eq 'Unhealthy' |
                Select-Object -First 20 DisplayName, Severity, Status, ResourceType, ResourceId
            )
            advisor = @(
                $Advisor | Select-Object -First 20 Category, Impact, Problem, Solution, ResourceType, ResourceId
            )
        }
    }
}

function Get-TextFromChoice($choiceMessage) {
    if ($null -eq $choiceMessage) { return $null }

    if ($choiceMessage.content -is [string]) {
        return $choiceMessage.content
    }

    if ($choiceMessage.content -is [System.Array]) {
        $parts = @($choiceMessage.content | ForEach-Object {
            if ($_.text) { $_.text } elseif ($_.content) { $_.content } else { '' }
        })
        return ($parts -join "`n").Trim()
    }

    return $null
}

function Wrap-AsHtml([string]$content) {
@"
<!DOCTYPE html>
<html lang='ja'>
<head>
  <meta charset='UTF-8'>
  <meta name='viewport' content='width=device-width, initial-scale=1.0'>
  <title>Azure Comprehensive Admin Report</title>
</head>
<body>
$content
</body>
</html>
"@
}

function Ensure-RequiredSections {
    param(
        [string]$Html
    )

    $requiredSections = @(
        @{
            Name = 'エグゼクティブサマリ'
            Pattern = 'エグゼクティブ\s*サマリ'
            Snippet = "<section><h2>エグゼクティブサマリ</h2><p>データなし（生成時補完）</p></section>"
        },
        @{
            Name = '全体サマリ表'
            Pattern = '全体\s*サマリ(表)?'
            Snippet = "<section><h2>全体サマリ表</h2><p>データなし（生成時補完）</p></section>"
        },
        @{
            Name = '潜在リスク Top 5'
            Pattern = '潜在\s*リスク\s*Top\s*5'
            Snippet = "<section><h2>潜在リスク Top 5</h2><p>データなし（生成時補完）</p></section>"
        },
        @{
            Name = '30日アクションプラン'
            Pattern = '30\s*日\s*アクション\s*プラン'
            Snippet = "<section><h2>30日アクションプラン</h2><ol><li>Week 1: 優先リスクの棚卸しと担当割り当て</li><li>Week 2: 高優先度項目の対処開始</li><li>Week 3: 対処結果の検証と未対応項目の再計画</li><li>Week 4: 定例レビューと次月計画の確定</li></ol></section>"
        }
    )

    $updated = $Html
    foreach ($section in $requiredSections) {
        if ($updated -notmatch $section.Pattern) {
            if ($updated -match '</main>') {
                $updated = $updated -replace '</main>', ("`n" + $section.Snippet + "`n</main>")
            } elseif ($updated -match '</body>') {
                $updated = $updated -replace '</body>', ("`n" + $section.Snippet + "`n</body>")
            } else {
                $updated += "`n" + $section.Snippet
            }
            Write-Warning "Missing required section was auto-inserted: $($section.Name)"
        }
    }

    return $updated
}

$apiKey = $env:AI_REPORT_API_KEY
$githubToken = $env:GITHUB_TOKEN

$runId = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { 'local' }
$repo = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { 'local' }

$resources = Read-JsonArray $ResourcesJson
$rbac      = Read-JsonArray $RbacJson
$nsg       = Read-JsonArray $NsgJson
$defender  = Read-JsonArray $DefenderJson
$advisor   = Read-JsonArray $AdvisorJson

$compact = Build-CompactInput -Resources $resources -Rbac $rbac -Nsg $nsg -Defender $defender -Advisor $advisor
$promptSeed = if (Test-Path $PromptFile) { Get-Content -Path $PromptFile -Raw -Encoding UTF8 } else { '' }

$systemPrompt = @'
あなたは Azure 運用監査レポート作成エージェントです。
出力は必ず HTML 全文のみ。
厳守ルール:
- 入力 JSON に存在しない数値や事実を作らない
- 不明値は「未取得」または「データなし」と記載
- 日本語で記述
- script タグを含めない
- 外部 CDN 参照を含めない
- 必須セクション: エグゼクティブサマリ / 全体サマリ表 / 潜在リスク Top 5 / 30日アクションプラン / 付録(NSG, Defender, Advisor)
- 各主要主張に根拠数値を併記
- Top 5 リスクは High/Medium/Low バッジを表示

## エグゼクティブサマリの構成（重要）
エグゼクティブサマリは **数字カードを 5 枚以内** に絞り、残りは AI による **日本語の推察文** で構成すること。
- KPI カード（最大 5 枚）に表示する指標: リソース総数 / Defender High 件数 / Advisor High Impact 件数 / Owner 割り当て数 / タグ付与率
- カードの下に **200〜300 文字程度の総評パラグラフ** を 1〜2 段落書く。データから読み取れる環境の特徴・リスクの背景・優先対応理由を文章で説明する
- その後に **主要懸念事項** と **強み** を箇条書きで 3〜5 件ずつ続ける
- 数値の羅列は「全体サマリ表」に委ねること

## スタイル指示（ライトテーマ・モダンデザイン）
HTML には以下の CSS を埋め込むこと:
- カラーパレット: 背景 #f5f7fa / カード #ffffff / 強調 #0078d4 / 高リスク #d93025 / 中リスク #f9ab00 / 低リスク #38bdf8
- ヘッダー: グラデーション(#0078d4→#50e6ff)、白テキスト、padding 28px 32px
- KPI グリッド: 5列レスポンシブ（960px→3列 / 768px→2列）、グラデーション背景、影付き
- セクション: border 1px solid #e5e7eb、border-radius 8px、box-shadow 0 1px 2px rgba(0,0,0,0.05)
- テーブル: 交互背景 #f9fafb、フォント 13px
- バッジ: 重大度別に色分け（High 赤→左ボーダー4px、Medium 橙、Low 青）
- フォント: Yu Gothic / Segoe UI、行間 1.7、レスポンシブ対応
'@

$userPrompt = @"
以下の情報をもとに comprehensive-report.html を生成してください。

## Context Prompt
$promptSeed

## Data (Compact JSON)
$(($compact | ConvertTo-Json -Depth 8))

## Metadata
- runId: $runId
- repo: $repo
- generatedAtUtc: $([DateTime]::UtcNow.ToString('o'))

## 出力制約
- 単一ファイルの自己完結 HTML（style 埋め込み）
- UTF-8 前提
- フッターに「⚙️ AI-Generated Report」と「Generated by GitHub Agentic Workflow」を明記
  - フッター表示例: 「⚙️ AI-Generated Report | Generated by GitHub Agentic Workflow | 2026-07-10」
- HTML 末尾コメントとして MACHINE_EVIDENCE を埋め込む
"@

$payload = @{
    model = $Model
    messages = @(
        @{ role = 'system'; content = $systemPrompt },
        @{ role = 'user'; content = $userPrompt }
    )
    temperature = 0.2
    max_tokens = 16000
}

$headers = @{
    'Content-Type' = 'application/json'
}

$isGitHubModelsEndpoint = $ApiEndpoint -match 'models\.github\.ai'

if ($isGitHubModelsEndpoint -and -not [string]::IsNullOrWhiteSpace($githubToken)) {
    # GitHub Models endpoint expects Bearer token authentication.
    $headers['Authorization'] = "Bearer $githubToken"
}
elseif (-not [string]::IsNullOrWhiteSpace($apiKey)) {
    # Azure/OpenAI-compatible gateways that expect api-key header.
    $headers['api-key'] = $apiKey
}

$body = $payload | ConvertTo-Json -Depth 12

try {
    if ($isGitHubModelsEndpoint -and [string]::IsNullOrWhiteSpace($githubToken)) {
        throw 'GitHub Models を使うには GITHUB_TOKEN が必要です。'
    }

    if (-not $isGitHubModelsEndpoint -and [string]::IsNullOrWhiteSpace($apiKey)) {
        throw 'AI_REPORT_API_KEY が未設定です。GitHub Models を使う場合は AI_REPORT_API_ENDPOINT を models.github.ai に設定してください。'
    }

    $response = Invoke-RestMethod -Method Post -Uri $ApiEndpoint -Headers $headers -Body $body -TimeoutSec 180
    $content = $null
    $usage = $null

    if ($response.choices -and $response.choices.Count -gt 0) {
        $content = Get-TextFromChoice -choiceMessage $response.choices[0].message
    }

    if ($response.usage) {
        $usage = [ordered]@{
            promptTokens = [int]$response.usage.prompt_tokens
            completionTokens = [int]$response.usage.completion_tokens
            totalTokens = [int]$response.usage.total_tokens
        }
    }

    if ([string]::IsNullOrWhiteSpace($content)) {
        throw 'モデル応答から HTML を抽出できませんでした。'
    }

    if (-not ($content.TrimStart().StartsWith('<!DOCTYPE html', [System.StringComparison]::OrdinalIgnoreCase) -or $content.TrimStart().StartsWith('<html', [System.StringComparison]::OrdinalIgnoreCase))) {
        $content = Wrap-AsHtml -content $content
    }

    if ($content -match '<script[\s>]') {
        throw '生成 HTML に script タグが含まれています。'
    }

    $content = Ensure-RequiredSections -Html $content

    $evidence = [ordered]@{
        runId = $runId
        repository = $repo
        generatedAt = (Get-Date).ToString('o')
        model = $Model
        endpoint = $ApiEndpoint
        metrics = $compact.metrics
        usage = $usage
    }

    New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($OutputPath)) -Force | Out-Null
    $content | Set-Content -Path $OutputPath -Encoding utf8
    ($evidence | ConvertTo-Json -Depth 8) | Set-Content -Path $EvidencePath -Encoding utf8
    Write-Host "AI HTML report generated: $OutputPath"
}
catch {
    Write-Warning "AI HTML generation was skipped or failed. Fallback to rule-based script. Reason: $($_.Exception.Message)"

    if ($FailOnError) {
        throw
    }

    $fallbackScript = Join-Path $PSScriptRoot 'New-AzComprehensiveAdminReport.ps1'
    if (Test-Path $fallbackScript) {
        & $fallbackScript -ResourcesJson $ResourcesJson -RbacJson $RbacJson -NsgJson $NsgJson -DefenderJson $DefenderJson -AdvisorJson $AdvisorJson -OutputPath $OutputPath

        if (Test-Path $OutputPath) {
            $fallbackHtml = Get-Content -Path $OutputPath -Raw -Encoding UTF8
            $fallbackHtml = $fallbackHtml -replace 'AI Insights authored by GitHub Copilot', 'Rule-based insights authored by PowerShell logic'
            $fallbackHtml | Set-Content -Path $OutputPath -Encoding utf8
        }
    } else {
        throw 'Fallback script New-AzComprehensiveAdminReport.ps1 が見つかりません。'
    }
}
