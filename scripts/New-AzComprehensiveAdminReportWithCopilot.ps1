<#
.SYNOPSIS
    GitHub Copilot (GitHub Models) を使って Azure 棚卸しデータから
    comprehensive-report.html を直接生成する。

.DESCRIPTION
    期待フロー:
      1) Azure データ収集
      2) AI による HTML レポート生成

    失敗時は既存の New-AzComprehensiveAdminReport.ps1 にフォールバックし、
    HTML 生成のパイプラインを停止させない。
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
    [string]$ApiEndpoint   = 'https://models.inference.ai.azure.com/chat/completions',
    [string]$Model         = 'openai/gpt-4o-mini',
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

    $sampleResources = @(
        $Resources | Select-Object -First 20 ResourceName, ResourceType, ResourceGroupName, Location, Sku
    )
    $sampleRiskyNsg = @(
        $Nsg | Where-Object { $_.IsRiskyMgmtFromInternet -eq $true -or $_.IsRiskyMgmtFromInternet -eq 'True' } |
        Select-Object -First 20 NsgName, RuleName, Priority, Direction, Access, SourceAddressPrefix, DestinationPortRange
    )
    $sampleDefender = @(
        $Defender | Where-Object Status -eq 'Unhealthy' |
        Select-Object -First 20 DisplayName, Severity, Status, ResourceType, ResourceId
    )
    $sampleAdvisor = @(
        $Advisor | Select-Object -First 20 Category, Impact, Problem, Solution, ResourceType, ResourceId
    )

    [ordered]@{
        generatedAt = (Get-Date).ToString('o')
        metrics = [ordered]@{
            resourcesTotal = $Resources.Count
            resourceGroups = ($Resources | Group-Object ResourceGroupName).Count
            regions = ($Resources | Group-Object Location).Count
            rbacTotal = $Rbac.Count
            ownerAssignments = @($Rbac | Where-Object RoleDefinitionName -eq 'Owner').Count
            uaaAssignments = @($Rbac | Where-Object RoleDefinitionName -eq 'User Access Administrator').Count
            orphanAssignments = @($Rbac | Where-Object { [string]::IsNullOrWhiteSpace($_.DisplayName) }).Count
            nsgRulesTotal = $Nsg.Count
            nsgRisky = $nsgRisky
            defenderTotal = $Defender.Count
            defenderUnhealthy = $defUnhealthy
            defenderHigh = $defHigh
            advisorTotal = $Advisor.Count
            advisorHigh = $advHigh
            tagCoverage = $tagCoverage
        }
        samples = [ordered]@{
            resources = $sampleResources
            riskyNsgRules = $sampleRiskyNsg
            defenderUnhealthy = $sampleDefender
            advisor = $sampleAdvisor
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

$token = $env:GITHUB_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'GITHUB_TOKEN が未設定です。Workflow step で env に渡してください。'
}

$resources = Read-JsonArray $ResourcesJson
$rbac      = Read-JsonArray $RbacJson
$nsg       = Read-JsonArray $NsgJson
$defender  = Read-JsonArray $DefenderJson
$advisor   = Read-JsonArray $AdvisorJson

$compact = Build-CompactInput -Resources $resources -Rbac $rbac -Nsg $nsg -Defender $defender -Advisor $advisor
$promptSeed = if (Test-Path $PromptFile) { Get-Content -Path $PromptFile -Raw -Encoding UTF8 } else { '' }

$systemPrompt = @'
あなたは Azure 運用レポート作成の専門家です。
出力は必ず HTML 全文にしてください。
必須セクション:
1. エグゼクティブサマリ
2. 全体サマリ表
3. 潜在リスク Top 5
4. 30日アクションプラン
5. 付録（NSG/Defender/Advisor ハイライト）

制約:
- 日本語で記述
- 過剰な誇張を避け、入力データに基づく内容のみ
- 単一ファイルの自己完結 HTML（style 埋め込み）
- 文字コードは UTF-8 前提
'@

$userPrompt = @"
以下の情報をもとに、comprehensive-report.html を生成してください。

## Context Prompt
$promptSeed

## Data (Compact JSON)
$(($compact | ConvertTo-Json -Depth 8))

## HTML 要件
- タイトル: Azure Comprehensive Admin Report
- サマリカードを先頭に表示
- Top 5 リスクは severity (High/Medium/Low) バッジ付き
- 30日アクションは週ごとに整理
- フッターに「Generated by GitHub Actions + GitHub Copilot」を明記
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
    Authorization = "Bearer $token"
    'Content-Type' = 'application/json'
}

if ($ApiEndpoint -like '*api.githubcopilot.com*') {
    $headers['Copilot-Integration-Id'] = 'azure-inventory-insights-generator-ai'
}

$body = $payload | ConvertTo-Json -Depth 12

try {
    $response = Invoke-RestMethod -Method Post -Uri $ApiEndpoint -Headers $headers -Body $body -TimeoutSec 180
    $content = $null

    if ($response.choices -and $response.choices.Count -gt 0) {
        $content = Get-TextFromChoice -choiceMessage $response.choices[0].message
    }

    if ([string]::IsNullOrWhiteSpace($content)) {
        throw 'モデル応答から HTML を抽出できませんでした。'
    }

    if (-not ($content.TrimStart().StartsWith('<!DOCTYPE html', [System.StringComparison]::OrdinalIgnoreCase) -or $content.TrimStart().StartsWith('<html', [System.StringComparison]::OrdinalIgnoreCase))) {
        $content = @"
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

    New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($OutputPath)) -Force | Out-Null
    $content | Set-Content -Path $OutputPath -Encoding utf8
    Write-Host "AI HTML report generated: $OutputPath"
}
catch {
    Write-Warning "AI HTML generation failed. Fallback to rule-based script. Reason: $($_.Exception.Message)"
    $fallbackScript = Join-Path $PSScriptRoot 'New-AzComprehensiveAdminReport.ps1'
    if (Test-Path $fallbackScript) {
        & $fallbackScript -ResourcesJson $ResourcesJson -RbacJson $RbacJson -NsgJson $NsgJson -DefenderJson $DefenderJson -AdvisorJson $AdvisorJson -OutputPath $OutputPath
    } else {
        if ($FailOnError) { throw }
        throw 'Fallback script New-AzComprehensiveAdminReport.ps1 が見つかりません。'
    }
}
