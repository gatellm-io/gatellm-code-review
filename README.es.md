# Claude Auto Review

**Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [Português](README.pt.md)

> La versión en inglés es la fuente autoritativa. Los demás idiomas son traducciones de la comunidad y pueden estar desactualizadas.

Una GitHub Action reutilizable que genera automáticamente revisiones de código para pull requests. Envuelve `anthropics/claude-code-action@v1` y añade:

- **Revisión paralela multi-modelo + resumen**: cuando se configuran ≥2 modelos, cada modelo revisa de forma independiente; el job de resumen fusiona y desduplica los hallazgos, anota la confianza (`[Consensus N/M]` / `[Single model]`) y renumera la lista de TODO. Una configuración vacía vuelve al modo de un solo modelo.
- Umbral de líneas modificadas del PR (por defecto 10000); se omite automáticamente al superarlo; admite re-ejecución manual para forzar la ejecución.
- Minimiza los comentarios históricos de Claude antes de cada ejecución para mantener bajo el ruido del PR.
- Auto-detección del Claude CLI + instalación de respaldo (reutiliza el CLI preinstalado en runners self-hosted).
- Verificación de calidad de la revisión (reintenta una vez automáticamente cuando el comentario es demasiado corto).
- Lenguaje de revisión parametrizable (`review_language`, por defecto inglés, vuelve al inglés si no se especifica) + bloque `## TODO Fix List` interpretable por máquina + plantilla de sección "Requires manual attention".

## Dos modos de uso

### Modo 1: Composite Action (escenarios ligeros de un solo modelo)

Incrusta la action como un paso en tu flujo de PR existente. Máxima flexibilidad. **Solo revisión de un solo modelo**; el resultado se publica directamente como comentario del PR.

```yaml
# .github/workflows/pr-review.yml (repo del invocador)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    runs-on: [self-hosted, Linux, fargate-runner]   # o ubuntu-latest
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
          # Todos los demás inputs tienen valores por defecto; sobrescribir según sea necesario
```

### Modo 2: Reusable Workflow (recomendado, soporta multi-modelo)

Llama al flujo completo de tres etapas `setup → review(matrix) → summarize`. **Soporta revisión paralela y resumen multi-modelo**; te evita configurar `permissions` / `concurrency` / `runs-on` por tu cuenta.

```yaml
# .github/workflows/pr-review.yml (repo del invocador)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    uses: gatellm-io/gatellm-code-review/.github/workflows/claude-auto-review.yml@v1
    secrets: inherit           # permite que CODE_REVIEW_API_KEY pase a través
    with:
      runs_on: "self-hosted, Linux, fargate-runner"
      # Modelo único: dejar `models` vacío para usar `model` como fallback
      # Multi-modelo: pasar una lista de modelos separada por comas
      # models: "deepseek-v4-pro,claude-sonnet-4,glm-4-plus"
      # summary_model: "claude-sonnet-4"
```

## Inputs

### Inputs de la Composite Action (`action.yml`)

| Nombre | Tipo | Por defecto | Descripción |
|---|---|---|---|
| `anthropic_api_key` | string | `""` | API key de Anthropic (el invocador debe pasarla explícitamente, p. ej. `${{ secrets.CODE_REVIEW_API_KEY }}`) |
| `anthropic_base_url` | string | `""` | URL base de la API de Anthropic (el invocador debe pasarla explícitamente, p. ej. `${{ vars.CODE_REVIEW_BASE_URL }}`; se usa al enrutar a través de un gateway) |
| `github_token` | string | `${{ github.token }}` | Token de GitHub; necesita `pull-requests: write`, `issues: write`, `actions: read` |
| `model` | string | `""` | Nombre del modelo único (el invocador puede pasar `${{ vars.CODE_REVIEW_MODEL }}` o un literal; vacío = usar el modelo por defecto del Claude CLI) |
| `max_lines` | number | `10000` | Máximo de líneas modificadas del PR; omite la revisión si se supera; `-1` significa ilimitado |
| `user_request` | string | `""` | Contenido de la solicitud del usuario cuando se activa mediante un comentario `@claude` |
| `review_language` | string | `"English"` | Idioma del comentario de revisión (p. ej. `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`); un valor vacío o no soportado vuelve al inglés |
| `prompt` | string | (ver `action.yml`) | Prompt de revisión personalizado (el requisito de idioma se inyecta por separado según `review_language`, no está integrado en el prompt por defecto) |

### Inputs del Reusable Workflow (`.github/workflows/claude-auto-review.yml`)

| Nombre | Tipo | Por defecto | Descripción |
|---|---|---|---|
| `runs_on` | string | `"self-hosted, Linux, fargate-runner"` | Etiquetas del runner, separadas por comas o una sola etiqueta; aplicadas a los jobs setup/review/summarize |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | Nombre del modelo único (se usa cuando `models` está vacío) |
| `models` | string | `${{ vars.CODE_REVIEW_MODELS }}` | Lista de modelos separada por comas (≥2 habilita el modo paralelo multi-modelo; máximo 3, los extra se truncan) |
| `summary_model` | string | `${{ vars.CODE_REVIEW_SUMMARY_MODEL }}` | Nombre del modelo de resumen (se usa en modo multi-modelo; vacío toma el primero de `models`) |
| `max_lines` | number | `10000` | Máximo de líneas modificadas del PR; omite la revisión si se supera; `-1` significa ilimitado |
| `user_request` | string | `""` | Contenido de la solicitud del usuario cuando se activa mediante un comentario `@claude` |
| `review_language` | string | `"English"` | Idioma del comentario de revisión (p. ej. `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`); un valor vacío o no soportado vuelve al inglés |
| `prompt` | string | (ver archivo del workflow) | Prompt de revisión personalizado (el requisito de idioma se inyecta por separado según `review_language`, no está integrado en el prompt por defecto) |

## Secrets / vars que el invocador debe configurar

El repo del invocador necesita lo siguiente en Settings → Secrets and variables → Actions:

| Tipo | Nombre | Requerido | Propósito |
|---|---|---|---|
| Secret | `CODE_REVIEW_API_KEY` | ✅ | API key de Anthropic |
| Variable | `CODE_REVIEW_BASE_URL` | Opcional | Se usa al enrutar a través de un gateway; se puede omitir cuando se accede a la API oficial directamente |
| Variable | `CODE_REVIEW_MODEL` | No | Nombre del modelo por defecto en modo de un solo modelo |
| Variable | `CODE_REVIEW_MODELS` | No | Lista separada por comas en modo multi-modelo |
| Variable | `CODE_REVIEW_SUMMARY_MODEL` | No | Nombre del modelo de resumen en modo multi-modelo |

> Para compartir las mismas credenciales entre todos los repos de una organización, considera [Secrets y variables a nivel de organización](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization).

## Requisitos de permisos

El `permissions` del job invocador debe incluir:

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  actions: read
```

La composite action en sí no establece `permissions`; el job invocador las controla. El reusable workflow establece `permissions` en cada uno de sus tres jobs (`setup` solo necesita `contents: read` + `pull-requests: read`; `review`/`summarize` necesitan el conjunto completo anterior).

## Versionamiento

- `v1`: etiqueta rolling, apunta a la última release 1.x
- `v1.0.0` etc.: etiquetas semánticas que fijan una versión exacta
- `main`: rama de desarrollo, no recomendada para uso en producción

Flujo de release:

```bash
git tag v1.1.0
git push origin v1.1.0
# Mover la etiqueta rolling
git tag -f v1 v1.1.0
git push origin v1 --force
```

## Notas de comportamiento

### Resolución de modo (solo reusable workflow)

El job setup decide el modo según el número de `models` parseado:

- `models` parsea a ≥2 → `mode=multi`: revisión paralela en matriz; los resultados se escriben en `./claude-review-output.md`, empaquetados como artifact; el job `summarize` descarga todos los artifacts, fusiona, desduplica, anota la confianza y publica un comentario de resumen.
- `models` parsea a ≤1 → `mode=single`: revisión de un solo modelo, publica un comentario del PR directamente, con verificación de calidad y reintento ante resultados cortos.

> La composite action siempre está en modo de un solo modelo, equivalente a `mode=single`.

### Umbral de líneas modificadas del PR

- `max_lines > 0`: omite la revisión si `additions + deletions` del PR supera este valor; la re-ejecución manual omite la verificación del umbral.
- `max_lines == -1`: ilimitado.
- `max_lines == 0`: rechaza cualquier PR.

### Minimización de comentarios

Antes de cada revisión, llama a `minimizeComment` de GraphQL para plegar los comentarios históricos de Claude como `OUTDATED`. Si un comentario de revisión termina con menos de 100 caracteres, se minimiza automáticamente y se reintenta una vez. En modo multi-modelo, esta lógica se ejecuta en el job `summarize`.

### Instalación del Claude CLI

- El runner tiene el Claude CLI preinstalado (caso típico self-hosted): se reutiliza directamente.
- El runner no lo tiene (caso típico `ubuntu-latest`): `action.yml` primero prueba `npm install -g @anthropic-ai/claude-code`, luego recurre a `curl -fsSL https://claude.ai/install.sh | bash` (npm no se ve afectado por el bloqueo geográfico de Claude.ai, recomendado). El reusable workflow solo detecta PATH y no instala (depende de la preinstalación del runner self-hosted).

### Formato de salida de la revisión

El idioma del comentario se controla con `review_language` (por defecto inglés; un valor vacío o no soportado vuelve al inglés; pasa `Simplified Chinese` para revisiones en chino). Estructura:

1. **Análisis de hallazgos**: ordenado por severidad, con referencias `file:line`; en modo multi-modelo cada hallazgo se anota con `[Consensus N/M]` o `[Single model]`.
2. **`## TODO Fix List`**: formato fijo interpretable por máquina, una línea por entrada: `- [ ] **[TODO-n] [Pn] \`file:line\`** — Resumen del problema; Requisito de corrección: ...`
   - Clasificación de severidad: `[P0]` bug crítico / seguridad; `[P1]` riesgo lógico / regresión de comportamiento; `[P2]` rendimiento / tests faltantes; `[P3]` estilo.
   - En el resumen multi-modelo, las entradas se fusionan, desduplican y renumeran como `TODO-1..n` continuo; las anotaciones de consenso van después de la etiqueta de severidad.
3. **Requires manual attention**: elementos que necesitan revisión humana.
4. **(Solo multi-modelo)** Bloques colapsados al final con la revisión original de cada modelo.

Consulta los valores por defecto del `prompt` en `action.yml` / el archivo del workflow para más detalles.

## Validación local

```bash
# Verificación de sintaxis YAML
python3 -c "import yaml; yaml.safe_load(open('action.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/claude-auto-review.yml'))"

# actionlint (si está instalado)
actionlint
```

## Licencia

MIT
