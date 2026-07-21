# Azure Inventory & Insights Reports

現在ログイン中の Azure サブスクリプションを対象に、リソース / RBAC / NSG / Microsoft Defender for Cloud / Azure Advisor の情報を PowerShell で収集し、CSV / JSON のローデータと総合 HTML レポートを 1 本生成するリポジトリです。

GitHub Copilot の prompt から対話的に実行することも、PowerShell スクリプトを直接実行することもできます。

> 重要: 本リポジトリはデモ / 学習目的のサンプルコードです。Microsoft 公式製品ではなく、無保証 (AS-IS) で提供されます。本番環境で使用する場合は、お客様自身で十分なレビューとテストを実施してください。詳細は [LICENSE](LICENSE) を参照してください。

## できること

| ドメイン | 取得対象 | 出力 |
| --- | --- | --- |
| リソース | `Get-AzResource` 全リソース | CSV / JSON |
| RBAC | `Get-AzRoleAssignment` 全割り当て | CSV / JSON |
| NSG | `Get-AzNetworkSecurityGroup` のルールをフラット化 | CSV / JSON |
| Microsoft Defender for Cloud | `Microsoft.Security/assessments` REST API | CSV / JSON |
| Azure Advisor | `Get-AzAdvisorRecommendation` | CSV / JSON |
| 総合レポート | 上記 5 ドメイン横断分析 | HTML |

総合レポートには以下を含みます。

- エグゼクティブ サマリ
- ドメイン別サマリ表
- 潜在リスク Top 5
- 30 日アクション プラン
- NSG / Defender / Advisor の付録一覧

## 前提条件

- PowerShell 7.x 以上
- Az モジュール
- `Az.Accounts`, `Az.Resources`, `Az.Network` は必須
- `Az.Advisor` は推奨
- 対象 Azure サブスクリプションへの Reader 以上の権限
- Defender for Cloud の評価取得には Security Reader ロール

## セットアップ

```powershell
Install-Module -Name Az         -Scope CurrentUser -Repository PSGallery -Force
Install-Module -Name Az.Advisor -Scope CurrentUser -Repository PSGallery -Force

Connect-AzAccount
Set-AzContext -Subscription "<サブスクリプション名 または ID>"
```

## 使い方

すべてのスクリプトは引数なしで実行できます。出力先は既定で `output/` ディレクトリです。

```powershell
cd scripts

./Export-AzResources.ps1
./Export-AzRoleAssignments.ps1
./Export-AzNsgRules.ps1
./Export-AzDefenderRecommendations.ps1
./Export-AzAdvisorRecommendations.ps1
./New-AzComprehensiveAdminReport.ps1
```

主な成果物:

- `output/resources.{csv,json}`
- `output/rbac.{csv,json}`
- `output/nsg-rules.{csv,json}`
- `output/defender-recommendations.{csv,json}`
- `output/advisor-recommendations.{csv,json}`
- `output/comprehensive-report.html`

## ディレクトリ構成

```
.
├── README.md
├── LICENSE
├── .gitignore
├── .github/
│   └── prompts/
│       └── azure-comprehensive-report.prompt.md
├── scripts/
│   ├── Export-AzResources.ps1
│   ├── Export-AzRoleAssignments.ps1
│   ├── Export-AzNsgRules.ps1
│   ├── Export-AzDefenderRecommendations.ps1
│   ├── Export-AzAdvisorRecommendations.ps1
│   ├── New-AzComprehensiveAdminReport.ps1
│   ├── New-AzComprehensiveAdminReportWithAgent.ps1
│   └── Test-AzComprehensiveAdminReport.ps1
└── output/
```

## Copilot prompt での実行

VS Code + GitHub Copilot Chat 環境では、以下の prompt を使って一連の収集とレポート生成を実行できます。

```text
/azure-comprehensive-report
```

## GitHub Actions で Agentic Workflow 実行

このリポジトリでは、パターンXのローカル実行フローをできる限り維持しながら、GitHub Actions上で GitHub Agentic Workflow による AI HTML レポート生成ができます。

パターンXから変えないもの:

- 既存のAzure棚卸し収集スクリプト
- 既存の5ドメイン出力: `resources.json`, `rbac.json`, `nsg-rules.json`, `defender-recommendations.json`, `advisor-recommendations.json`
- 生成HTML名: `comprehensive-report.html`
- `reports/latest` / `reports/history` への保存
- GitHub Pagesで最新HTMLを確認する運用

パターンAで追加するもの:

- Azure収集workflow: `.github/workflows/collect-azure-inventory-production.yml`
- Agentic Workflow: `.github/workflows/azure-inventory-production.md`
- Actions実行用lock file: `.github/workflows/azure-inventory-production.lock.yml`
- Agent入力生成: `scripts/New-AzAgentInput.ps1`
- Agent入力検証: `scripts/Test-AzAgentInput.ps1`
- Agent出力HTML検証: `scripts/Test-AzAgentReport.ps1`
- Pages/reports公開workflow: `.github/workflows/publish-agentic-report-pages.yml`

本番経路のジョブ構成は以下です。

1. `collect-azure-inventory-production.yml`: Azure の各種データを収集し、匿名化済み `inventory-summary.json` だけをArtifact化
2. `azure-inventory-production.lock.yml`: Agentic Workflow が `inventory-summary.json` だけを読み、AIでHTMLを生成
3. `publish-agentic-report-pages.yml`: Agent出力を検証し、Pages公開と `reports/latest` / `reports/history/{yyyy-MM-dd}` への保存を実行

主な生成物:

- `reports/latest/comprehensive-report.html`
- `reports/latest/index.html`
- `reports/latest/report-evidence.json`
- `reports/history/{yyyy-MM-dd}/comprehensive-report.html`
- `reports/history/{yyyy-MM-dd}/report-evidence.json`

`report-evidence.json` には `generation_method=agentic-workflow` と、元になったAgentic Workflow run IDを記録します。

## GitHub Agentic Workflows の本番運用

本番経路は Azure 収集と AI 分析を別workflowへ分離しています。

1. `Azure 棚卸しレポート - Agentic 1/3 収集` が毎日 06:07 JST に起動する
2. Azure OIDC でログインし、5ドメインのrawデータをrunner内だけに収集する
3. rawデータを匿名化・集約し、共通検証に合格した `inventory-summary.json` だけを1日保持する
4. 成功した収集runを受けて `Azure 棚卸しレポート - Agentic 2/3 分析` が起動する
5. Agentは匿名化済みJSONだけを読み、Safe OutputsでHTMLを生成する
6. 専用workflowが検証済みPages artifactをGitHub Pagesへ公開する

必要なRepository Secrets:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

Azure側では、GitHubの `main` ブランチに限定したFederated Credentialを使用します。Service Principalの権限は対象サブスクリプションの `Reader` と `Security Reader` だけです。クライアントシークレットは使用しません。

手動実行はGitHubのActions画面で `Azure 棚卸しレポート - Agentic 1/3 収集` を選び、`Run workflow` を実行します。収集に成功すると、AI分析とPages公開が順番に自動起動します。詳細な監視・障害対応・ロールバックは [本番運用runbook](docs/production-operations.md) を参照してください。

本番経路のセキュリティ境界:

- Azure OIDCの `id-token: write` は収集workflowだけに付与
- raw JSON / CSVはArtifact、Git、Pagesへ保存せず、匿名化後にrunnerから削除
- Agent入力Artifactは匿名化済みJSON 1ファイルだけで、保持期間は1日
- AgentにAzure資格情報、OIDC、GitHub書き込み権限を付与しない
- Agent出力はSafe OutputsでHTML 1ファイル、最大1 MiB、保持期間7日に限定
- Pagesへの書き込み権限は専用公開workflowだけに付与
- 1runあたり100、24時間あたり300のAI Credits上限を設定

## セキュリティと取り扱い上の注意

- 生成物にはサブスクリプション ID、リソース ID、プリンシパル名、IP アドレス、NSG ルール、セキュリティ評価結果が含まれます。社外共有前に必ず確認してください。
- `output/` は `.gitignore` 対象です。Git でコミットしないでください。
- 収集対象を制限したい場合は、`Export-Az*.ps1` を編集してリソースグループ / リソースタイプ / スコープでフィルタしてください。
- HTML はローカル閲覧を想定しています。
- 本ツールは読み取りのみを行い、Azure リソースの作成・変更・削除は行いません。

## ライセンス

[MIT License](LICENSE)
