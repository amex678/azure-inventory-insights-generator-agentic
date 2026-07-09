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

$apiKey = $env:AI_REPORT_API_KEY

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
- フッターに「Generated by GitHub Agentic Workflow」を明記
- HTML 末尾コメントとして MACHINE_EVIDENCE を埋め込む
"@

$payload = @{
    model = $Model
    messages = @(
        @{ role = 'system'; content = $systemPrompt },
        @{ role = 'user'; content = $userPrompt }
    )
    temperature = 0.2
    max_tokens = 3500
}

$headers = @{
    'Content-Type' = 'application/json'
    'api-key' = $apiKey
}

$body = $payload | ConvertTo-Json -Depth 12

try {
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw 'AI_REPORT_API_KEY が未設定です。'
    }

    $response = Invoke-RestMethod -Method Post -Uri $ApiEndpoint -Headers $headers -Body $body -TimeoutSec 180
    $content = $null

    if ($response.choices -and $response.choices.Count -gt 0) {
        $content = Get-TextFromChoice -choiceMessage $response.choices[0].message
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

    $evidence = [ordered]@{
        runId = $runId
        repository = $repo
        generatedAt = (Get-Date).ToString('o')
        model = $Model
        metrics = $compact.metrics
    }

    New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($OutputPath)) -Force | Out-Null
    $content | Set-Content -Path $OutputPath -Encoding utf8
    ($evidence | ConvertTo-Json -Depth 8) | Set-Content -Path $EvidencePath -Encoding utf8
    Write-Host "AI HTML report generated: $OutputPath"
}
catch {
    Write-Warning "AI HTML generation was skipped or failed. Fallback to rule-based script. Reason: $($_.Exception.Message)"
    $fallbackScript = Join-Path $PSScriptRoot 'New-AzComprehensiveAdminReport.ps1'
    if (Test-Path $fallbackScript) {
        & $fallbackScript -ResourcesJson $ResourcesJson -RbacJson $RbacJson -NsgJson $NsgJson -DefenderJson $DefenderJson -AdvisorJson $AdvisorJson -OutputPath $OutputPath
    } else {
        if ($FailOnError) { throw }
        throw 'Fallback script New-AzComprehensiveAdminReport.ps1 が見つかりません。'
    }
}
