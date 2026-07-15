# 本番運用runbook

## 通常運用

本番処理は毎日 06:07 JST に自動実行されます。通常は次の3つのworkflowが順番に成功することを確認します。

1. `Azure 棚卸しデータ収集（本番）`
2. `Azure 棚卸し分析レポート（本番）`
3. `Agentic レポートを GitHub Pages に公開`

公開先は <https://amex678.github.io/azure-inventory-insights-generator-agentic/> です。

## 手動実行

Actions画面で `Azure 棚卸しデータ収集（本番）` を開き、`Run workflow` を実行します。後続workflowを個別に手動実行する必要はありません。

CLIで実行する場合:

```powershell
gh workflow run collect-azure-inventory-production.yml --repo amex678/azure-inventory-insights-generator-agentic
```

## 監視項目

- 収集workflowが30分以内に完了している
- `azure-inventory-agent-input` Artifactに `inventory-summary.json` だけが含まれる
- Agentic Workflowの `safe_outputs` と `conclusion` が成功している
- Pages公開workflowが成功し、公開ページの生成日時が更新されている
- Agentic WorkflowのAI Creditsが1runあたり100、24時間あたり300を超えていない

## データ保持

| データ | 保存先 | 保持期間 |
| --- | --- | --- |
| Azure raw JSON / CSV | runner一時領域のみ | workflow内で削除 |
| 匿名化済みAgent入力 | GitHub Actions Artifact | 1日 |
| Agent生成HTML | GitHub Actions Artifact | 7日 |
| gh-aw内部監査Artifact | GitHub Actions Artifact | フレームワーク既定（最大90日） |
| 公開HTML | GitHub Pages | 次回成功デプロイまで |

## 障害対応

### Azureログイン失敗

1. Repository Secretsの `AZURE_CLIENT_ID`、`AZURE_TENANT_ID`、`AZURE_SUBSCRIPTION_ID` が存在することを確認する。
2. EntraアプリのFederated Credentialが次のsubjectに限定されていることを確認する。

```text
repo:amex678@280604931/azure-inventory-insights-generator-agentic@1301115013:ref:refs/heads/main
```

GitHubのOIDC subject customizationにより、ownerとrepositoryは名前ではなくimmutable ID付きで発行されます。Actionsログの `AADSTS700213` に表示されるsubjectとFederated Credentialを完全一致させます。

3. workflowが `main` ブランチから実行されていることを確認する。

### Azure収集失敗

1. 失敗した5ドメインの収集ステップを確認する。
2. Service Principalに対象サブスクリプションの `Reader` と `Security Reader` があることを確認する。
3. rawデータをArtifactへアップロードしない。必要な調査はActionsログの件数とエラーだけで行う。

### 匿名化検証失敗

Agentic Workflowを迂回して公開しません。`New-AzAgentInput.ps1` と `Test-AzAgentInput.ps1` を修正し、ローカルテストと再収集を実行します。

```powershell
pwsh -NoProfile -File ./tests/Test-New-AzAgentInput.ps1
gh aw compile azure-inventory-production --strict
```

### AgentまたはPages公開失敗

最後に成功したPagesは維持されます。収集を再実行する前に、Agentic Workflowの `conclusion` とSafe Outputsのログを確認します。

## ロールバック

本番Agentic経路を一時停止する場合は、GitHub Actionsで `collect-azure-inventory-production.yml` を無効化します。レポートが必要な間は、旧 `azure-report-public.yml` を `rule-based` モードで手動実行できます。

本番経路を再開するときは、収集workflowを有効化して手動実行し、3つのworkflowが順番に成功することを確認します。

## 変更時の必須検証

```powershell
pwsh -NoProfile -File ./tests/Test-New-AzAgentInput.ps1
gh aw compile azure-inventory-production --strict
git diff --check
```

Agentic Workflowの `.md` を変更した場合は、生成された `.lock.yml` も同じ変更に含めます。