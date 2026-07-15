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

このリポジトリでは、PR を経由せず GitHub Actions 実行だけで Agentic Workflow による AI HTML レポート生成ができます。

- ワークフロー: `.github/workflows/azure-report-public.yml`
- AI 生成スクリプト: `scripts/New-AzComprehensiveAdminReportWithAgent.ps1`
- 検証スクリプト: `scripts/Test-AzComprehensiveAdminReport.ps1`
- 生成物:
	- `output/comprehensive-report.html`
	- `output/report-evidence.json`
	- `reports/latest/comprehensive-report.html`
	- `reports/history/{yyyy-MM-dd}/comprehensive-report.html`

ジョブ構成は以下です。

1. `collect-data`: Azure の各種データを収集（resources/rbac/nsg/defender/advisor）
2. `agent-generate-report`: prompt + compact JSON から AI で HTML を生成
3. `validate-report`: 必須セクション・危険タグ・主要数値の整合性を検証
4. `publish-report`: `reports/latest` / `reports/history` / Pages 用 `_site` を更新

必要な設定:

- Secret:
	- `AI_REPORT_API_KEY`
- Variable（任意）:
	- `AI_REPORT_API_ENDPOINT`
	- `AI_REPORT_MODEL`
	- `ENABLE_GITHUB_PAGES`（`true` のときのみ Pages デプロイ）

`workflow_dispatch` の `report_mode` で生成モードを選択できます。

- `auto`（既定）: AI を試行し、失敗または Secret 未設定時は rule-based にフォールバック
- `ai-only`: AI 生成のみ実行。失敗時はジョブ失敗
- `rule-based`: AI を使わず `New-AzComprehensiveAdminReport.ps1` のみ実行

> 補足:
> - AI 生成が失敗した場合は、既存のルールベース HTML 生成 (`New-AzComprehensiveAdminReport.ps1`) にフォールバックして処理を継続します。
> - `azure-comprehensive-report.prompt.md` を seed として利用し、Agent 側で事実拘束ルールを適用します。

## GitHub Agentic Workflows の試行

[Azure 棚卸し分析ワークフロー](.github/workflows/azure-inventory-insights.md) は、既存の [公開ワークフロー](.github/workflows/azure-report-public.yml) と並行して評価する最小構成の PoC です。Azure には接続せず、匿名化 fixture から作った集約 JSON だけを Agent に渡します。生成する HTML は承認待ちにせず artifact に保存し、[Pages 公開ワークフロー](.github/workflows/publish-agentic-report-pages.yml) が GitHub Pages へ自動公開します。Git のファイルは更新しません。

ローカルで匿名化と決定性を検証します。

```powershell
pwsh -NoProfile -File ./tests/Test-New-AzAgentInput.ps1
```

GitHub CLI と `gh-aw` extension を用意し、Markdown workflow から lock file を生成します。

```powershell
gh extension install github/gh-aw
gh aw --version
gh aw compile azure-inventory-insights --strict
```

`gh-aw` は `0.68.4` から `0.71.3` までのバージョンを使用しないでください。このリポジトリで検証したバージョンは `v0.81.6` です。compile 後の [GitHub Actions 実行用ファイル](.github/workflows/azure-inventory-insights.lock.yml) も、[人が編集する日本語のワークフロー](.github/workflows/azure-inventory-insights.md) と一緒にコミットします。

初回実行前に、GitHub の `Settings` → `Pages` → `Build and deployment` → `Source` で `GitHub Actions` を選択してください。

手動試行は GitHub の Actions 画面で `Azure 棚卸し分析サンプルレポート` を選び、`Run workflow` を実行します。処理が成功すると `Agentic レポートを GitHub Pages に公開` が自動起動し、[GitHub Pages のレポート](https://amex678.github.io/azure-inventory-insights-generator-agentic/) に公開します。artifact の保持期間は7日です。

> 注意: GitHub Pages は1リポジトリにつき1サイトです。この PoC と既存の `azure-report-public.yml` の Pages デプロイを両方有効にすると、最後に成功したデプロイの内容がサイトに表示されます。

この PoC の境界:

- 入力は `tests/fixtures/agent-input/` の匿名化テストデータのみ
- Agent 起動前に raw fixture と checkout 内容を削除
- Agent に Azure 資格情報、OIDC、GitHub 書き込み権限を付与しない
- Agent 自身には Pages 公開権限を与えず、成功後の専用 workflow だけが公開
- スケジュール実行は行わない
- Agent の出力先を `agent-output/azure-inventory-insights.html` に限定

## セキュリティと取り扱い上の注意

- 生成物にはサブスクリプション ID、リソース ID、プリンシパル名、IP アドレス、NSG ルール、セキュリティ評価結果が含まれます。社外共有前に必ず確認してください。
- `output/` は `.gitignore` 対象です。Git でコミットしないでください。
- 収集対象を制限したい場合は、`Export-Az*.ps1` を編集してリソースグループ / リソースタイプ / スコープでフィルタしてください。
- HTML はローカル閲覧を想定しています。
- 本ツールは読み取りのみを行い、Azure リソースの作成・変更・削除は行いません。

## ライセンス

[MIT License](LICENSE)
