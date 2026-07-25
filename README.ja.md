# Claude Auto Review

**Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [Português](README.pt.md)

> 英語版が権威あるソースです。他の言語はコミュニティ翻訳であり、英語版から遅れる場合があります。

プルリクエストのコードレビューを自動生成する再利用可能な GitHub Action です。`anthropics/claude-code-action@v1` をラップし、以下の機能を追加します:

- **マルチモデル並列レビュー + サマリー**: 2つ以上のモデルを設定した場合、各モデルが独立してレビューを実施します。summarize ジョブが指摘事項をマージ・重複排除し、信頼度 (`[Consensus N/M]` / `[Single model]`) を付与し、TODO リストの番号を振り直します。設定が空の場合はシングルモデルモードにフォールバックします。
- PR 変更行数のしきい値 (デフォルト 10000)。超過時は自動スキップし、手動再実行で強制実行できます。
- 各実行前に過去の Claude コメントを最小化し、PR のノイズを抑えます。
- Claude CLI の自動検出 + フォールバックインストール (セルフホステッドランナーではプレインストール済みの CLI を再利用)。
- レビュー品質チェック (コメントが短すぎる場合に1回だけ自動リトライ)。
- パラメータ化可能なレビュー言語 (`review_language`、デフォルトは英語、空の場合は英語にフォールバック) + 機械可読な `## TODO Fix List` ブロック + "Requires manual attention" セクションテンプレート。

## 2つの利用モード

### モード 1: コンポジットアクション (軽量なシングルモデルシナリオ)

アクションを既存の PR ワークフローの1ステップとして組み込みます。柔軟性が最も高いです。**シングルモデルレビューのみ**。出力は PR コメントとして直接投稿されます。

```yaml
# .github/workflows/pr-review.yml (呼び出し元リポジトリ)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    runs-on: [self-hosted, Linux, fargate-runner]   # または ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      issues: write
      actions: read
    concurrency:
      group: claude-review-${{ github.event.pull_request.number || github.event.issue.number }}
      cancel-in-progress: true
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 1
      - uses: gatellm-io/gatellm-code-review@v1
        with:
          anthropic_api_key: ${{ secrets.CODE_REVIEW_API_KEY }}
          anthropic_base_url: ${{ vars.CODE_REVIEW_BASE_URL }}
          # その他の入力はすべてデフォルト値があります。必要に応じて上書きしてください
```

### モード 2: 再利用可能なワークフロー (推奨、マルチモデル対応)

完全な `setup → review(matrix) → summarize` の3段階ワークフローを呼び出します。**マルチモデル並列レビューとサマリー集約をサポート**。`permissions` / `concurrency` / `runs-on` を自分で設定する手間を省けます。

```yaml
# .github/workflows/pr-review.yml (呼び出し元リポジトリ)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    uses: gatellm-io/gatellm-code-review/.github/workflows/claude-auto-review.yml@v1
    secrets: inherit           # CODE_REVIEW_API_KEY を引き継ぐため
    with:
      runs_on: "self-hosted, Linux, fargate-runner"
      # シングルモデル: `models` を空にすると `model` にフォールバックします
      # マルチモデル: カンマ区切りのモデルリストを指定します
      # models: "deepseek-v4-pro,claude-sonnet-4,glm-4-plus"
      # summary_model: "claude-sonnet-4"
```

## 入力

### コンポジットアクションの入力 (`action.yml`)

| 名前 | 型 | デフォルト | 説明 |
|---|---|---|---|
| `anthropic_api_key` | string | `""` | Anthropic API キー (呼び出し元が明示的に渡す必要があります。例: `${{ secrets.CODE_REVIEW_API_KEY }}`) |
| `anthropic_base_url` | string | `""` | Anthropic API ベース URL (呼び出し元が明示的に渡す必要があります。例: `${{ vars.CODE_REVIEW_BASE_URL }}`。ゲートウェイ経由でプロキシする場合に使用) |
| `github_token` | string | `${{ github.token }}` | GitHub トークン。`pull-requests: write`、`issues: write`、`actions: read` が必要 |
| `model` | string | `""` | シングルモデル名 (呼び出し元は `${{ vars.CODE_REVIEW_MODEL }}` またはリテラル値を渡せます。空 = Claude CLI のデフォルトモデルを使用) |
| `max_lines` | number | `10000` | PR の最大変更行数。超過時はレビューをスキップ。`-1` は無制限 |
| `user_request` | string | `""` | `@claude` コメントでトリガーされた場合のユーザーリクエスト内容 |
| `review_language` | string | `"English"` | レビューコメントの言語 (例: `English`、`Simplified Chinese`、`Traditional Chinese`、`Japanese`、`Korean`)。空または未対応の値は英語にフォールバック |
| `prompt` | string | (`action.yml` を参照) | カスタムレビュープロンプト (言語要件は `review_language` に基づき別途注入され、プロンプトのデフォルトに焼き付けられません) |

### 再利用可能なワークフローの入力 (`.github/workflows/claude-auto-review.yml`)

| 名前 | 型 | デフォルト | 説明 |
|---|---|---|---|
| `runs_on` | string | `"self-hosted, Linux, fargate-runner"` | ランナーラベル。カンマ区切りまたは単一ラベル。setup/review/summarize ジョブに適用 |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | シングルモデル名 (`models` が空の場合に使用) |
| `models` | string | `${{ vars.CODE_REVIEW_MODELS }}` | カンマ区切りのモデルリスト (≥2 でマルチモデル並列モードを有効化、最大 3、超過分は切り捨て) |
| `summary_model` | string | `${{ vars.CODE_REVIEW_SUMMARY_MODEL }}` | サマリーモデル名 (マルチモデルモードで使用。空の場合は `models` の先頭を採用) |
| `max_lines` | number | `10000` | PR の最大変更行数。超過時はレビューをスキップ。`-1` は無制限 |
| `user_request` | string | `""` | `@claude` コメントでトリガーされた場合のユーザーリクエスト内容 |
| `review_language` | string | `"English"` | レビューコメントの言語 (例: `English`、`Simplified Chinese`、`Traditional Chinese`、`Japanese`、`Korean`)。空または未対応の値は英語にフォールバック |
| `prompt` | string | (ワークフローファイルを参照) | カスタムレビュープロンプト (言語要件は `review_language` に基づき別途注入され、プロンプトのデフォルトに焼き付けられません) |

## 呼び出し元が設定すべき Secrets / vars

呼び出し元リポジトリでは Settings → Secrets and variables → Actions で以下を設定する必要があります:

| 種類 | 名前 | 必須 | 用途 |
|---|---|---|---|
| Secret | `CODE_REVIEW_API_KEY` | ✅ | Anthropic API キー |
| Variable | `CODE_REVIEW_BASE_URL` | 任意 | ゲートウェイ経由でプロキシする場合に使用。公式 API に直接アクセスする場合は省略可能 |
| Variable | `CODE_REVIEW_MODEL` | 不要 | シングルモデルモードでのデフォルトモデル名 |
| Variable | `CODE_REVIEW_MODELS` | 不要 | マルチモデルモードでのカンマ区切りリスト |
| Variable | `CODE_REVIEW_SUMMARY_MODEL` | 不要 | マルチモデルモードでのサマリーモデル名 |

> 組織内のすべてのリポジトリで同じ認証情報を共有するには、[組織レベルの Secrets と Variables](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization) の利用を検討してください。

## 権限要件

呼び出し元ジョブの `permissions` には以下を含める必要があります:

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  actions: read
```

コンポジットアクション自体は `permissions` を設定しません。呼び出し元ジョブが制御します。再利用可能なワークフローは3つの各ジョブ (`setup`、`review`、`summarize`) に `permissions` を設定します (`setup` は `contents: read` + `pull-requests: read` のみ必要。`review`/`summarize` は上記のフルセットが必要)。

## バージョニング

- `v1`: ローリングタグ。最新の 1.x リリースを指します。
- `v1.0.0` など: 特定バージョンを固定するセマンティックタグ。
- `main`: 開発ブランチ。本番使用は推奨されません。

リリースフロー:

```bash
git tag v1.1.0
git push origin v1.1.0
# ローリングタグを移動
git tag -f v1 v1.1.0
git push origin v1 --force
```

## 挙動メモ

### モード解決 (再利用可能なワークフローのみ)

setup ジョブはパースされた `models` の数に基づいてモードを決定します:

- `models` が ≥2 にパースされる → `mode=multi`: マトリクス並列レビュー。結果は `./claude-review-output.md` に書き込まれ、アーティファクトとしてパッケージ化されます。`summarize` ジョブがすべてのアーティファクトをダウンロードし、マージ・重複排除・信頼度付与を行い、1つのサマリーコメントを投稿します。
- `models` が ≤1 にパースされる → `mode=single`: シングルモデルレビュー。PR コメントを直接投稿し、品質チェックと短結果リトライを実施します。

> コンポジットアクションは常にシングルモデルモードで、`mode=single` と同等です。

### PR 変更行数しきい値

- `max_lines > 0`: PR の `additions + deletions` がこの値を超える場合、レビューをスキップします。手動再実行はしきい値チェックをスキップします。
- `max_lines == -1`: 無制限。
- `max_lines == 0`: いかなる PR も拒否します。

### コメントの最小化

各レビュー前に、GraphQL の `minimizeComment` を呼び出し、過去の Claude コメントを `OUTDATED` として折り畳みます。レビューコメントが 100 文字未満になった場合、自動的に最小化して1回リトライします。マルチモデルモードでは、このロジックは `summarize` ジョブで実行されます。

### Claude CLI のインストール

- ランナーに Claude CLI がプレインストール済み (典型的なセルフホステッドケース): そのまま再利用。
- プレインストールされていない場合 (典型的な `ubuntu-latest` ケース): `action.yml` はまず `npm install -g @anthropic-ai/claude-code` を試行し、次に `curl -fsSL https://claude.ai/install.sh | bash` にフォールバックします (npm は Claude.ai の地域ブロックの影響を受けないため推奨)。再利用可能なワークフローは PATH の検出のみ行い、インストールは行いません (セルフホステッドランナーのプレインストールに依存)。

### レビュー出力フォーマット

コメントの言語は `review_language` で制御します (デフォルトは英語。空または未対応の値は英語にフォールバック。中国語レビューの場合は `Simplified Chinese` を指定)。構造:

1. **指摘事項分析**: 重要度順、`file:line` 参照付き。マルチモデルモードでは各指摘に `[Consensus N/M]` または `[Single model]` が付与されます。
2. **`## TODO Fix List`**: 機械可読な固定フォーマット。1エントリ1行: `- [ ] **[TODO-n] [Pn] `file:line** — 問題サマリー; 修正要件: ...`
   - 重要度グレード: `[P0]` 重大バグ / セキュリティ; `[P1]` ロジックリスク / 挙動の後退; `[P2]` パフォーマンス / テスト不足; `[P3]` スタイル。
   - マルチモデルサマリーでは、エントリはマージ・重複排除され、連番 `TODO-1..n` として採番し直されます。合意注釈は重要度タグの後に配置されます。
3. **Requires manual attention**: 人間のレビューが必要な項目。
4. **(マルチモデルのみ)** 各モデルのオリジナルレビューを含む折り畳みブロックが末尾に配置されます。

詳細は `action.yml` / ワークフローファイルの `prompt` デフォルトを参照してください。

## ローカル検証

```bash
# YAML 構文チェック
python3 -c "import yaml; yaml.safe_load(open('action.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/claude-auto-review.yml'))"

# actionlint (インストールされている場合)
actionlint
```

## ライセンス

MIT
