# Claude Auto Review

**Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [Português](README.pt.md)

> 英文版本為權威來源。其他語言為社群翻譯,可能落後於英文版本。

可重複使用的 GitHub Action,可自動為 Pull Request 產生程式碼審查。封裝 `anthropics/claude-code-action@v1` 並新增以下功能:

- **多模型並行審查 + 摘要**:當設定 ≥2 個模型時,每個模型會獨立審查;摘要任務會合併並去重複發現、標註信心度 (`[Consensus N/M]` / `[Single model]`),並重新編號 TODO 清單。未設定時回退為單一模型模式。
- PR 變更行數閾值(預設 10000);超過時自動跳過;支援手動重新執行以強制執行。
- 每次執行前會最小化歷史 Claude 留言,以降低 PR 雜訊。
- Claude CLI 自動偵測 + 備援安裝(在自託管 runner 上會重用預裝的 CLI)。
- 審查品質檢查(當留言過短時自動重試一次)。
- 可參數化設定審查語言(`review_language`,預設英文,回退為英文)+ 機器可解析的 `## TODO Fix List` 區塊 + "Requires manual attention" 區段範本。

## 兩種使用模式

### 模式一:組合式 Action(輕量單一模型情境)

將 action 作為現有 PR 工作流程的一個步驟嵌入。彈性最大。**僅支援單一模型審查**;輸出會直接以 PR 留言發佈。

```yaml
# .github/workflows/pr-review.yml (呼叫端 repo)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    if: >-
      github.event_name == 'pull_request' ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request != null &&
       github.event.comment.user.type != 'Bot' &&
       contains(github.event.comment.body, '@claude'))
    runs-on: [self-hosted, Linux, fargate-runner]   # 或 ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      issues: write
      actions: read
    concurrency:
      group: claude-review-${{ github.event.pull_request.number || github.event.issue.number }}-${{ github.event_name }}
      cancel-in-progress: true
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 1
      - uses: gatellm-io/gatellm-code-review@v1
        with:
          anthropic_api_key: ${{ secrets.CODE_REVIEW_API_KEY }}
          anthropic_base_url: ${{ vars.CODE_REVIEW_BASE_URL }}
          # 所有其他輸入都有預設值;可視需要覆寫
```

### 模式二:可重複使用的工作流程(推薦,支援多模型)

呼叫完整的 `setup → review(matrix) → summarize` 三階段工作流程。**支援多模型並行審查與摘要**;讓您不必自行設定 `permissions` / `concurrency` / `runs-on`。

```yaml
# .github/workflows/pr-review.yml (呼叫端 repo)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    if: >-
      github.event_name == 'pull_request' ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request != null &&
       github.event.comment.user.type != 'Bot' &&
       contains(github.event.comment.body, '@claude'))
    uses: gatellm-io/gatellm-code-review/.github/workflows/claude-auto-review.yml@v1
    secrets: inherit           # 讓 CODE_REVIEW_API_KEY 通過
    with:
      runs_on: "self-hosted, Linux, fargate-runner"
      # 單一模型:將 `models` 留空以回退為 `model`
      # 多模型:傳入逗號分隔的模型清單
      # models: "deepseek-v4-pro,claude-sonnet-4,glm-4-plus"
      # summary_model: "claude-sonnet-4"
```

## 輸入

### 組合式 Action 輸入(`action.yml`)

| 名稱 | 型別 | 預設值 | 說明 |
|---|---|---|---|
| `anthropic_api_key` | string | `""` | Anthropic API 金鑰(呼叫端必須明確傳入,例如 `${{ secrets.CODE_REVIEW_API_KEY }}`) |
| `anthropic_base_url` | string | `""` | Anthropic API 基底 URL(呼叫端必須明確傳入,例如 `${{ vars.CODE_REVIEW_BASE_URL }}`;用於透過閘道代理時) |
| `github_token` | string | `${{ github.token }}` | GitHub token;需要 `pull-requests: write`、`issues: write`、`actions: read` |
| `model` | string | `""` | 單一模型名稱(呼叫端可傳入 `${{ vars.CODE_REVIEW_MODEL }}` 或字面值;留空 = 使用 Claude CLI 預設模型) |
| `max_lines` | number | `10000` | PR 最大變更行數;超過則跳過審查;`-1` 表示無限制 |
| `user_request` | string | `""` | 由 `@claude` 留言觸發時的使用者請求內容 |
| `review_language` | string | `"English"` | 審查留言語言(例如 `English`、`Simplified Chinese`、`Traditional Chinese`、`Japanese`、`Korean`);留空或不支援的值會回退為英文 |
| `prompt` | string | (見 `action.yml`) | 自訂審查 prompt(語言要求會依 `review_language` 個別注入,不會寫死在 prompt 預設值中) |

### 可重複使用工作流程的輸入(`.github/workflows/claude-auto-review.yml`)

| 名稱 | 型別 | 預設值 | 說明 |
|---|---|---|---|
| `runs_on` | string | `"self-hosted, Linux, fargate-runner"` | Runner 標籤,以逗號分隔或單一標籤;套用至 setup/review/summarize 任務 |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | 單一模型名稱(在 `models` 為空時使用) |
| `models` | string | `${{ vars.CODE_REVIEW_MODELS }}` | 逗號分隔的模型清單(≥2 啟用多模型並行模式;最多 3 個,超過會截斷) |
| `summary_model` | string | `${{ vars.CODE_REVIEW_SUMMARY_MODEL }}` | 摘要模型名稱(用於多模型模式;留空時取 `models` 的第一個) |
| `max_lines` | number | `10000` | PR 最大變更行數;超過則跳過審查;`-1` 表示無限制 |
| `user_request` | string | `""` | 由 `@claude` 留言觸發時的使用者請求內容 |
| `review_language` | string | `"English"` | 審查留言語言(例如 `English`、`Simplified Chinese`、`Traditional Chinese`、`Japanese`、`Korean`);留空或不支援的值會回退為英文 |
| `prompt` | string | (見工作流程檔案) | 自訂審查 prompt(語言要求會依 `review_language` 個別注入,不會寫死在 prompt 預設值中) |

## 呼叫端必須設定的 Secrets / 變數

呼叫端 repo 需要在 Settings → Secrets and variables → Actions 中設定以下項目:

| 型別 | 名稱 | 必要 | 用途 |
|---|---|---|---|
| Secret | `CODE_REVIEW_API_KEY` | ✅ | Anthropic API 金鑰 |
| Variable | `CODE_REVIEW_BASE_URL` | 選填 | 用於透過閘道代理時;直接連接官方 API 時可省略 |
| Variable | `CODE_REVIEW_MODEL` | 否 | 單一模型模式下的預設模型名稱 |
| Variable | `CODE_REVIEW_MODELS` | 否 | 多模型模式下的逗號分隔清單 |
| Variable | `CODE_REVIEW_SUMMARY_MODEL` | 否 | 多模型模式下的摘要模型名稱 |

> 若要在組織內所有 repo 共用同一組憑證,請考慮使用[組織層級的 secrets 與變數](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization)。

## 權限需求

呼叫端任務的 `permissions` 必須包含:

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  actions: read
```

組合式 action 本身不設定 `permissions`;由呼叫端任務控制。可重複使用的工作流程會在三個任務上分別設定 `permissions`(`setup` 僅需 `contents: read` + `pull-requests: read`;`review`/`summarize` 需要上述完整集合)。

## 版本管理

- `v1`:滾動標籤,指向最新的 1.x 版本
- `v1.0.0` 等:語意化標籤,釘選確切版本
- `main`:開發分支,不建議用於正式環境

發佈流程:

```bash
git tag v1.1.0
git push origin v1.1.0
# 移動滾動標籤
git tag -f v1 v1.1.0
git push origin v1 --force
```

## 行為說明

### 模式解析(僅適用於可重複使用的工作流程)

setup 任務會依據解析後的 `models` 數量決定模式:

- `models` 解析為 ≥2 → `mode=multi`:矩陣並行審查;結果寫入 `./claude-review-output.md`,打包為 artifact;`summarize` 任務會下載所有 artifact、合併、去重複、標註信心度,並發佈一則摘要留言。
- `models` 解析為 ≤1 → `mode=single`:單一模型審查,直接發佈 PR 留言,並具備品質檢查與簡短結果重試。

> 組合式 action 始終為單一模型模式,等同於 `mode=single`。

### PR 變更行數閾值

- `max_lines > 0`:當 PR 的 `additions + deletions` 超過此值時跳過審查;手動重新執行會跳過閾值檢查。
- `max_lines == -1`:無限制。
- `max_lines == 0`:拒絕任何 PR。

### 留言最小化

每次審查前,會呼叫 GraphQL `minimizeComment` 將歷史 Claude 留言摺疊為 `OUTDATED`。若審查留言長度短於 100 字元,會自動最小化並重試一次。在多模型模式下,此邏輯會在 `summarize` 任務中執行。

### Claude CLI 安裝

- Runner 已預裝 Claude CLI(典型自託管情況):直接重用。
- Runner 未預裝(典型 `ubuntu-latest` 情況):`action.yml` 會先嘗試 `npm install -g @anthropic-ai/claude-code`,再備援至 `curl -fsSL https://claude.ai/install.sh | bash`(npm 不受 Claude.ai 地理封鎖影響,建議使用)。可重複使用的工作流程僅偵測 PATH,不會安裝(依賴自託管 runner 預裝)。

### 審查輸出格式

留言語言由 `review_language` 控制(預設英文;留空或不支援的值會回退為英文;中文審查請傳入 `Simplified Chinese`)。結構:

1. **發現分析**:依嚴重程度排序,附有 `file:line` 參照;在多模型模式下,每個發現都會標註 `[Consensus N/M]` 或 `[Single model]`。
2. **`## TODO Fix List`**:機器可解析的固定格式,每筆一行:`- [ ] **[TODO-n] [Pn] \`file:line\`** — 問題摘要;修正要求:...`
   - 嚴重程度分級:`[P0]` 重大錯誤 / 安全問題;`[P1]` 邏輯風險 / 行為回歸;`[P2]` 效能 / 缺少測試;`[P3]` 風格。
   - 多模型摘要中,項目會被合併、去重複,並重新編號為連續的 `TODO-1..n`;共識標註位於嚴重程度標籤之後。
3. **需要人工關注**:需要人工審查的項目。
4. **(僅多模型)** 底部的摺疊區塊,包含每個模型的原始審查內容。

完整詳情請見 `action.yml` / 工作流程檔案中的 `prompt` 預設值。

## 本地驗證

```bash
# YAML 語法檢查
python3 -c "import yaml; yaml.safe_load(open('action.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/claude-auto-review.yml'))"

# actionlint(若已安裝)
actionlint
```

## 授權

MIT
