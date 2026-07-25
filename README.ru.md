# Claude Auto Review

**Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [Português](README.pt.md)

> Английская версия является авторитетным источником. Другие языки — переводы сообщества и могут отставать от оригинала.

Переиспользуемый GitHub Action, который автоматически генерирует ревью кода для pull request'ов. Оборачивает `anthropics/claude-code-action@v1` и добавляет:

- **Параллельное ревью несколькими моделями + саммари**: когда настроено ≥2 моделей, каждая модель ревьюит независимо; задача summarize сливает и дедуплицирует находки, помечает уверенность (`[Consensus N/M]` / `[Single model]`) и перенумеровывает TODO-список. Пустая конфигурация откатывается к одномодельному режиму.
- Порог изменённых строк PR (по умолчанию 10000); авто-пропуск при превышении; поддерживает ручной повторный запуск для принудительного выполнения.
- Сворачивает исторические комментарии Claude перед каждым запуском, чтобы уменьшить шум в PR.
- Авто-детекция Claude CLI + fallback-установка (переиспользует предустановленный CLI на self-hosted runner'ах).
- Проверка качества ревью (один авто-ретрай, если комментарий слишком короткий).
- Настраиваемый язык ревью (`review_language`, по умолчанию английский, откат к английскому при пустом значении) + машиночитаемый блок `## TODO Fix List` + шаблон секции "Requires manual attention".

## Два режима использования

### Режим 1: Composite Action (лёгкие одномодельные сценарии)

Встройте action как один шаг в ваш существующий PR-workflow. Максимальная гибкость. **Только одномодельное ревью**; результат постится напрямую как комментарий к PR.

```yaml
# .github/workflows/pr-review.yml (репозиторий-вызыватель)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    runs-on: [self-hosted, Linux, fargate-runner]   # или ubuntu-latest
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
          # Все остальные входы имеют значения по умолчанию; переопределяйте при необходимости
```

### Режим 2: Reusable Workflow (рекомендуется, поддерживает многомодельность)

Вызывает полный трёхстадийный workflow `setup → review(matrix) → summarize`. **Поддерживает параллельное ревью и саммаризацию несколькими моделями**; избавляет от необходимости самим настраивать `permissions` / `concurrency` / `runs-on`.

```yaml
# .github/workflows/pr-review.yml (репозиторий-вызыватель)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    uses: gatellm-io/gatellm-code-review/.github/workflows/claude-auto-review.yml@v1
    secrets: inherit           # пропускает CODE_REVIEW_API_KEY сквозь workflow
    with:
      runs_on: "self-hosted, Linux, fargate-runner"
      # Одна модель: оставьте `models` пустым, чтобы откатиться к `model`
      # Несколько моделей: передайте список через запятую
      # models: "deepseek-v4-pro,claude-sonnet-4,glm-4-plus"
      # summary_model: "claude-sonnet-4"
```

## Входы

### Входы Composite Action (`action.yml`)

| Имя | Тип | По умолчанию | Описание |
|---|---|---|---|
| `anthropic_api_key` | string | `""` | API-ключ Anthropic (вызыватель должен передать явно, например `${{ secrets.CODE_REVIEW_API_KEY }}`) |
| `anthropic_base_url` | string | `""` | Базовый URL API Anthropic (вызыватель должен передать явно, например `${{ vars.CODE_REVIEW_BASE_URL }}`; используется при проксировании через шлюз) |
| `github_token` | string | `${{ github.token }}` | GitHub-токен; нужны `pull-requests: write`, `issues: write`, `actions: read` |
| `model` | string | `""` | Имя одной модели (вызыватель может передать `${{ vars.CODE_REVIEW_MODEL }}` или литерал; пусто = использовать модель Claude CLI по умолчанию) |
| `max_lines` | number | `10000` | Максимальное число изменённых строк PR; пропуск ревью при превышении; `-1` означает без лимита |
| `user_request` | string | `""` | Содержимое пользовательского запроса при срабатывании через комментарий `@claude` |
| `review_language` | string | `"English"` | Язык комментариев ревью (например `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`); пустое или неподдерживаемое значение откатывается к английскому |
| `prompt` | string | (см. `action.yml`) | Кастомный промпт ревью (требование языка инжектируется отдельно на основе `review_language`, а не вшито в дефолт промпта) |

### Входы Reusable Workflow (`.github/workflows/claude-auto-review.yml`)

| Имя | Тип | По умолчанию | Описание |
|---|---|---|---|
| `runs_on` | string | `"self-hosted, Linux, fargate-runner"` | Лейблы runner'а, через запятую или один лейбл; применяются к задачам setup/review/summarize |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | Имя одной модели (используется, когда `models` пусто) |
| `models` | string | `${{ vars.CODE_REVIEW_MODELS }}` | Список моделей через запятую (≥2 включает многомодельный параллельный режим; максимум 3, лишние обрезаются) |
| `summary_model` | string | `${{ vars.CODE_REVIEW_SUMMARY_MODEL }}` | Имя модели саммаризации (используется в многомодельном режиме; пусто берёт первую из `models`) |
| `max_lines` | number | `10000` | Максимальное число изменённых строк PR; пропуск ревью при превышении; `-1` означает без лимита |
| `user_request` | string | `""` | Содержимое пользовательского запроса при срабатывании через комментарий `@claude` |
| `review_language` | string | `"English"` | Язык комментариев ревью (например `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`); пустое или неподдерживаемое значение откатывается к английскому |
| `prompt` | string | (см. файл workflow) | Кастомный промпт ревью (требование языка инжектируется отдельно на основе `review_language`, а не вшито в дефолт промпта) |

## Секреты / переменные, которые должен настроить вызывающий

Репозиторию-вызывателю нужны следующие записи в Settings → Secrets and variables → Actions:

| Тип | Имя | Обязательно | Назначение |
|---|---|---|---|
| Secret | `CODE_REVIEW_API_KEY` | ✅ | API-ключ Anthropic |
| Variable | `CODE_REVIEW_BASE_URL` | Опционально | Используется при проксировании через шлюз; можно опустить при прямом обращении к официальному API |
| Variable | `CODE_REVIEW_MODEL` | Нет | Имя модели по умолчанию в одномодельном режиме |
| Variable | `CODE_REVIEW_MODELS` | Нет | Список через запятую в многомодельном режиме |
| Variable | `CODE_REVIEW_SUMMARY_MODEL` | Нет | Имя модели саммаризации в многомодельном режиме |

> Чтобы использовать одни и те же учётные данные во всех репозиториях организации, рассмотрите [секреты и переменные уровня организации](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization).

## Требования к разрешениям

`permissions` вызывающей задачи должны включать:

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  actions: read
```

Сам composite action не задаёт `permissions`; их контролирует вызывающая задача. Reusable workflow задаёт `permissions` для каждой из трёх своих задач (`setup` нужны только `contents: read` + `pull-requests: read`; `review`/`summarize` нужен полный набор выше).

## Версионирование

- `v1`: плавающий тег, указывает на последний релиз 1.x
- `v1.0.0` и т.д.: семантические теги, фиксирующие точную версию
- `main`: ветка разработки, не рекомендуется для production-использования

Процесс релиза:

```bash
git tag v1.1.0
git push origin v1.1.0
# Сдвинуть плавающий тег
git tag -f v1 v1.1.0
git push origin v1 --force
```

## Замечания по поведению

### Разрешение режима (только для reusable workflow)

Задача setup определяет режим на основе количества распарсенных `models`:

- `models` парсится в ≥2 → `mode=multi`: матричное параллельное ревью; результаты пишутся в `./claude-review-output.md`, упаковываются как артефакт; задача `summarize` скачивает все артефакты, сливает, дедуплицирует, помечает уверенность и постит один summary-комментарий.
- `models` парсится в ≤1 → `mode=single`: одномодельное ревью, постит PR-комментарий напрямую, с проверкой качества и ретраем при коротком результате.

> Composite action всегда в одномодельном режиме, эквивалентно `mode=single`.

### Порог изменённых строк PR

- `max_lines > 0`: пропустить ревью, если `additions + deletions` PR превышает это значение; ручной повторный запуск пропускает проверку порога.
- `max_lines == -1`: без лимита.
- `max_lines == 0`: отклоняет любой PR.

### Сворачивание комментариев

Перед каждым ревью вызывается GraphQL `minimizeComment`, чтобы свернуть исторические комментарии Claude как `OUTDATED`. Если комментарий ревью оказывается короче 100 символов, он авто-сворачивается и ретраится один раз. В многомодельном режиме эта логика выполняется в задаче `summarize`.

### Установка Claude CLI

- У runner'а предустановлен Claude CLI (типичный self-hosted случай): переиспользуется напрямую.
- Не предустановлен (типичный `ubuntu-latest` случай): `action.yml` сначала пробует `npm install -g @anthropic-ai/claude-code`, затем откатывается к `curl -fsSL https://claude.ai/install.sh | bash` (npm не подвержен гео-блокировке Claude.ai, рекомендуется). Reusable workflow только детектирует PATH и не устанавливает (полагается на предустановку на self-hosted runner'е).

### Формат вывода ревью

Язык комментариев управляется `review_language` (по умолчанию английский; пустое или неподдерживаемое значение откатывается к английскому; передайте `Simplified Chinese` для ревью на китайском). Структура:

1. **Анализ находок**: упорядочен по серьёзности, со ссылками `file:line`; в многомодельном режиме каждая находка помечается `[Consensus N/M]` или `[Single model]`.
2. **`## TODO Fix List`**: машиночитаемый фиксированный формат, по одной строке на запись: `- [ ] **[TODO-n] [Pn] \`file:line\`** — Описание проблемы; Требование к исправлению: ...`
   - Градация серьёзности: `[P0]` критический баг / безопасность; `[P1]` логический риск / поведенческая регрессия; `[P2]` производительность / отсутствующие тесты; `[P3]` стиль.
   - В многомодельном саммари записи сливаются, дедуплицируются и перенумеровываются как непрерывные `TODO-1..n`; аннотации консенсуса идут после тега серьёзности.
3. **Requires manual attention**: пункты, требующие человеческого ревью.
4. **(Только многомодельный)** Свёрнутые блоки внизу с оригинальным ревью каждой модели.

Полные детали см. в дефолтах `prompt` в `action.yml` / файле workflow.

## Локальная валидация

```bash
# Проверка синтаксиса YAML
python3 -c "import yaml; yaml.safe_load(open('action.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/claude-auto-review.yml'))"

# actionlint (если установлен)
actionlint
```

## Лицензия

MIT
