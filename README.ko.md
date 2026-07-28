# Claude Auto Review

**Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [Português](README.pt.md)

> 영문 버전이 권위 있는 원본입니다. 다른 언어는 커뮤니티 번역으로, 원본보다 뒤처질 수 있습니다.

Pull Request에 대한 코드 리뷰를 자동 생성하는 재사용 가능한 GitHub Action입니다. `anthropics/claude-code-action@v1`을 래핑하며, 다음 기능을 추가합니다:

- **다중 모델 병렬 리뷰 + 요약**: 2개 이상의 모델이 구성된 경우, 각 모델이 독립적으로 리뷰합니다. summarize 잡이 발견 사항을 병합 및 중복 제거하고, 신뢰도(`[Consensus N/M]` / `[Single model]`)를 표시하며, TODO 목록을 다시 매깁니다. 설정이 비어 있으면 단일 모델 모드로 폴백합니다.
- PR 변경 라인 임계값(기본값 10000); 초과 시 자동 건너뜀; 수동 재실행으로 강제 실행을 지원합니다.
- 각 실행 전에 과거 Claude 코멘트를 최소화하여 PR 노이즈를 낮게 유지합니다.
- Claude CLI 자동 감지 + 폴백 설치(self-hosted runner에 사전 설치된 CLI를 재사용).
- 리뷰 품질 검사(코멘트가 너무 짧을 경우 한 번 자동 재시도).
- 리뷰 언어 파라미터화(`review_language`, 기본값 영어, 미지원 시 영어로 폴백) + 머신 파싱 가능한 `## TODO Fix List` 블록 + "Requires manual attention" 섹션 템플릿.

## 두 가지 사용 모드

### 모드 1: Composite Action (경량 단일 모델 시나리오)

이 Action을 기존 PR 워크플로의 한 단계로 임베드하세요. 최대의 유연성을 제공합니다. **단일 모델 리뷰만 지원**; 결과는 PR 코멘트로 직접 게시됩니다.

```yaml
# .github/workflows/pr-review.yml (호출 저장소)
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
    runs-on: [self-hosted, Linux, fargate-runner]   # 또는 ubuntu-latest
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
          # 다른 모든 입력에는 기본값이 있습니다; 필요에 따라 재정의하세요
```

### 모드 2: Reusable Workflow (권장, 다중 모델 지원)

`setup → review(matrix) → summarize` 3단계 워크플로 전체를 호출합니다. **다중 모델 병렬 리뷰 및 요약 지원**; `permissions` / `concurrency` / `runs-on`을 직접 구성할 필요가 없습니다.

```yaml
# .github/workflows/pr-review.yml (호출 저장소)
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
    secrets: inherit           # CODE_REVIEW_API_KEY가 전달되도록 허용
    with:
      runs_on: "self-hosted, Linux, fargate-runner"
      # 단일 모델: `models`를 비워두면 `model`로 폴백
      # 다중 모델: 쉼표로 구분된 모델 목록을 전달
      # models: "deepseek-v4-pro,claude-sonnet-4,glm-4-plus"
      # summary_model: "claude-sonnet-4"
```

## 입력

### Composite Action 입력 (`action.yml`)

| 이름 | 유형 | 기본값 | 설명 |
|---|---|---|---|
| `anthropic_api_key` | string | `""` | Anthropic API 키 (호출자가 명시적으로 전달해야 함, 예: `${{ secrets.CODE_REVIEW_API_KEY }}`) |
| `anthropic_base_url` | string | `""` | Anthropic API 베이스 URL (호출자가 명시적으로 전달해야 함, 예: `${{ vars.CODE_REVIEW_BASE_URL }}`; 게이트웨이를 통해 프록시할 때 사용) |
| `github_token` | string | `${{ github.token }}` | GitHub 토큰; `pull-requests: write`, `issues: write`, `actions: read` 필요 |
| `model` | string | `""` | 단일 모델 이름 (호출자가 `${{ vars.CODE_REVIEW_MODEL }}` 또는 리터럴을 전달할 수 있음; 비어 있으면 Claude CLI 기본 모델 사용) |
| `max_lines` | number | `10000` | 최대 PR 변경 라인 수; 초과 시 리뷰 건너뜀; `-1`은 무제한을 의미 |
| `user_request` | string | `""` | `@claude` 코멘트로 트리거된 경우 사용자 요청 내용 |
| `review_language` | string | `"English"` | 리뷰 코멘트 언어 (예: `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`); 비어 있거나 지원하지 않는 값은 영어로 폴백 |
| `prompt` | string | (`action.yml` 참조) | 커스텀 리뷰 프롬프트 (언어 요구사항은 `review_language`를 기반으로 별도 주입되며, 프롬프트 기본값에 박혀 있지 않음) |

### Reusable Workflow 입력 (`.github/workflows/claude-auto-review.yml`)

| 이름 | 유형 | 기본값 | 설명 |
|---|---|---|---|
| `runs_on` | string | `"self-hosted, Linux, fargate-runner"` | Runner 라벨, 쉼표로 구분하거나 단일 라벨; setup/review/summarize 잡에 적용 |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | 단일 모델 이름 (`models`가 비어 있을 때 사용) |
| `models` | string | `${{ vars.CODE_REVIEW_MODELS }}` | 쉼표로 구분된 모델 목록 (≥2이면 다중 모델 병렬 모드 활성화; 최대 3개, 초과분은 잘림) |
| `summary_model` | string | `${{ vars.CODE_REVIEW_SUMMARY_MODEL }}` | 요약 모델 이름 (다중 모델 모드에서 사용; 비어 있으면 `models`의 첫 번째 값을 사용) |
| `max_lines` | number | `10000` | 최대 PR 변경 라인 수; 초과 시 리뷰 건너뜀; `-1`은 무제한을 의미 |
| `user_request` | string | `""` | `@claude` 코멘트로 트리거된 경우 사용자 요청 내용 |
| `review_language` | string | `"English"` | 리뷰 코멘트 언어 (예: `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`); 비어 있거나 지원하지 않는 값은 영어로 폴백 |
| `prompt` | string | (워크플로 파일 참조) | 커스텀 리뷰 프롬프트 (언어 요구사항은 `review_language`를 기반으로 별도 주입되며, 프롬프트 기본값에 박혀 있지 않음) |

## 호출자가 구성해야 하는 Secrets / vars

호출 저장소는 Settings → Secrets and variables → Actions에서 다음을 구성해야 합니다:

| 유형 | 이름 | 필수 | 용도 |
|---|---|---|---|
| Secret | `CODE_REVIEW_API_KEY` | ✅ | Anthropic API 키 |
| Variable | `CODE_REVIEW_BASE_URL` | 선택 | 게이트웨이를 통해 프록시할 때 사용; 공식 API에 직접 호출 시 생략 가능 |
| Variable | `CODE_REVIEW_MODEL` | 아니오 | 단일 모델 모드의 기본 모델 이름 |
| Variable | `CODE_REVIEW_MODELS` | 아니오 | 다중 모델 모드의 쉼표로 구분된 목록 |
| Variable | `CODE_REVIEW_SUMMARY_MODEL` | 아니오 | 다중 모델 모드의 요약 모델 이름 |

> org의 모든 저장소에서 동일한 자격 증명을 공유하려면 [조직 수준 secrets 및 variables](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization)를 고려하세요.

## 권한 요구사항

호출 잡의 `permissions`는 다음을 포함해야 합니다:

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  actions: read
```

Composite Action 자체는 `permissions`를 설정하지 않습니다; 호출 잡이 이를 제어합니다. Reusable workflow는 3개 잡 각각에 `permissions`를 설정합니다 (`setup`은 `contents: read` + `pull-requests: read`만 필요; `review`/`summarize`은 위의 전체 세트가 필요).

## 버전 관리

- `v1`: 롤링 태그, 최신 1.x 릴리스를 가리킴
- `v1.0.0` 등: 정확한 버전을 고정하는 시맨틱 태그
- `main`: 개발 브랜치, 프로덕션 사용에 권장되지 않음

릴리스 흐름:

```bash
git tag v1.1.0
git push origin v1.1.0
# 롤링 태그 이동
git tag -f v1 v1.1.0
git push origin v1 --force
```

## 동작 참고사항

### 모드 결정 (reusable workflow 전용)

setup 잡은 파싱된 `models` 수를 기준으로 모드를 결정합니다:

- `models`가 ≥2로 파싱 → `mode=multi`: 매트릭스 병렬 리뷰; 결과는 `./claude-review-output.md`에 기록되어 아티팩트로 패키징; `summarize` 잡이 모든 아티팩트를 다운로드하여 병합, 중복 제거, 신뢰도 표시 후 하나의 요약 코멘트를 게시.
- `models`가 ≤1로 파싱 → `mode=single`: 단일 모델 리뷰, 품질 검사 및 짧은 결과 재시도와 함께 PR 코멘트를 직접 게시.

> Composite Action은 항상 단일 모델 모드이며, `mode=single`과 동일합니다.

### PR 변경 라인 임계값

- `max_lines > 0`: PR `additions + deletions`이 이 값을 초과하면 리뷰를 건너뜀; 수동 재실행은 임계값 검사를 건너뜀.
- `max_lines == -1`: 무제한.
- `max_lines == 0`: 모든 PR을 거부.

### 코멘트 최소화

각 리뷰 전에 GraphQL `minimizeComment`를 호출하여 과거 Claude 코멘트를 `OUTDATED`로 접습니다. 리뷰 코멘트가 100자 미만으로 끝나면 자동으로 최소화되고 한 번 재시도됩니다. 다중 모델 모드에서는 이 로직이 `summarize` 잡에서 실행됩니다.

### Claude CLI 설치

- Runner에 Claude CLI가 사전 설치됨 (일반적인 self-hosted 케이스): 직접 재사용.
- 설치되지 않음 (일반적인 `ubuntu-latest` 케이스): `action.yml`이 먼저 `npm install -g @anthropic-ai/claude-code`를 시도하고, 실패하면 `curl -fsSL https://claude.ai/install.sh | bash`로 폴백 (npm은 Claude.ai 지역 차단의 영향을 받지 않으므로 권장). Reusable workflow는 PATH만 감지하고 설치하지 않음 (self-hosted runner 사전 설치에 의존).

### 리뷰 출력 형식

코멘트 언어는 `review_language`로 제어됩니다 (기본값 영어; 비어 있거나 지원하지 않는 값은 영어로 폴백; 중국어 리뷰를 원하면 `Simplified Chinese` 전달). 구조:

1. **발견 사항 분석**: 심각도순으로 정렬, `file:line` 참조 포함; 다중 모델 모드에서는 각 발견 사항에 `[Consensus N/M]` 또는 `[Single model]` 표시.
2. **`## TODO Fix List`**: 머신 파싱 가능한 고정 형식, 한 항목당 한 줄: `- [ ] **[TODO-n] [Pn] \`file:line\`** — 이슈 요약; 수정 요구사항: ...`
   - 심각도 등급: `[P0]` 치명적 버그 / 보안; `[P1]` 로직 위험 / 동작 회귀; `[P2]` 성능 / 누락된 테스트; `[P3]` 스타일.
   - 다중 모델 요약에서 항목은 병합, 중복 제거, 연속 `TODO-1..n`로 다시 매겨집니다; 합의 표시는 심각도 태그 뒤에 위치.
3. **Requires manual attention**: 사람이 검토해야 할 항목.
4. **(다중 모델 전용)** 하단에 각 모델의 원본 리뷰가 있는 접힌 블록.

자세한 내용은 `action.yml` / 워크플로 파일의 `prompt` 기본값을 참조하세요.

## 로컬 검증

```bash
# YAML 구문 검사
python3 -c "import yaml; yaml.safe_load(open('action.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/claude-auto-review.yml'))"

# actionlint (설치된 경우)
actionlint
```

## 라이선스

MIT
