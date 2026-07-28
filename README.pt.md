# Claude Auto Review

**Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [Português](README.pt.md)

> A versão em inglês é a fonte autoritativa. Outros idiomas são traduções da comunidade e podem estar desatualizadas.

Uma GitHub Action reutilizável que gera automaticamente revisão de código para pull requests. Encapsula o `anthropics/claude-code-action@v1` e adiciona:

- **Revisão paralela multi-modelo + sumário**: quando ≥2 modelos são configurados, cada modelo revisa independentemente; o job de sumarização mescla e deduplica achados, anota a confiança (`[Consensus N/M]` / `[Single model]`) e renumera a lista TODO. Configuração vazia cai para o modo de modelo único.
- Limite de linhas alteradas do PR (padrão 10000); ignora automaticamente quando excedido; suporta reexecução manual para forçar a execução.
- Minimiza comentários históricos do Claude antes de cada execução para manter o ruído do PR baixo.
- Detecção automática + instalação de fallback do Claude CLI (reutiliza o CLI pré-instalado em runners auto-hospedados).
- Verificação de qualidade da revisão (retries automáticos uma vez quando o comentário é muito curto).
- Idioma da revisão parametrizável (`review_language`, padrão inglês, cai para inglês) + bloco `## TODO Fix List` parseável por máquina + template da seção "Requires manual attention".

## Dois modos de uso

### Modo 1: Composite Action (cenários leves de modelo único)

Incorpore a action como um passo no seu fluxo de PR existente. Flexibilidade máxima. **Apenas revisão de modelo único**; a saída é publicada diretamente como um comentário no PR.

```yaml
# .github/workflows/pr-review.yml (repositório chamador)
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
    runs-on: [self-hosted, Linux, fargate-runner]   # ou ubuntu-latest
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
          # Todas as outras entradas têm padrões; sobrescreva conforme necessário
```

### Modo 2: Reusable Workflow (recomendado, suporta multi-modelo)

Chama o fluxo completo de três estágios `setup → review(matrix) → summarize`. **Suporta revisão paralela multi-modelo e sumarização**; poupa você de configurar `permissions` / `concurrency` / `runs-on` por conta própria.

```yaml
# .github/workflows/pr-review.yml (repositório chamador)
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
    secrets: inherit           # permite que CODE_REVIEW_API_KEY passe
    with:
      runs_on: "self-hosted, Linux, fargate-runner"
      # Modelo único: deixe `models` vazio para cair para `model`
      # Multi-modelo: passe uma lista de modelos separada por vírgulas
      # models: "deepseek-v4-pro,claude-sonnet-4,glm-4-plus"
      # summary_model: "claude-sonnet-4"
```

## Entradas

### Entradas da Composite Action (`action.yml`)

| Nome | Tipo | Padrão | Descrição |
|---|---|---|---|
| `anthropic_api_key` | string | `""` | Chave da API da Anthropic (o chamador deve passar explicitamente, ex. `${{ secrets.CODE_REVIEW_API_KEY }}`) |
| `anthropic_base_url` | string | `""` | URL base da API da Anthropic (o chamador deve passar explicitamente, ex. `${{ vars.CODE_REVIEW_BASE_URL }}`; usado ao proxyar por um gateway) |
| `github_token` | string | `${{ github.token }}` | Token do GitHub; precisa de `pull-requests: write`, `issues: write`, `actions: read` |
| `model` | string | `""` | Nome do modelo único (o chamador pode passar `${{ vars.CODE_REVIEW_MODEL }}` ou um literal; vazio = usar o modelo padrão do Claude CLI) |
| `max_lines` | número | `10000` | Máximo de linhas alteradas do PR; ignora a revisão se excedido; `-1` significa ilimitado |
| `user_request` | string | `""` | Conteúdo da solicitação do usuário quando acionado por comentário `@claude` |
| `review_language` | string | `"English"` | Idioma do comentário de revisão (ex. `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`); valor vazio ou não suportado cai para inglês |
| `prompt` | string | (ver `action.yml`) | Prompt de revisão personalizado (o requisito de idioma é injetado separadamente com base em `review_language`, não embutido no padrão do prompt) |

### Entradas do Reusable Workflow (`.github/workflows/claude-auto-review.yml`)

| Nome | Tipo | Padrão | Descrição |
|---|---|---|---|
| `runs_on` | string | `"self-hosted, Linux, fargate-runner"` | Labels do runner, separadas por vírgulas ou um único label; aplicado aos jobs setup/review/summarize |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | Nome do modelo único (usado quando `models` está vazio) |
| `models` | string | `${{ vars.CODE_REVIEW_MODELS }}` | Lista de modelos separada por vírgulas (≥2 habilita o modo paralelo multi-modelo; máximo 3, extras truncados) |
| `summary_model` | string | `${{ vars.CODE_REVIEW_SUMMARY_MODEL }}` | Nome do modelo de sumário (usado no modo multi-modelo; vazio pega o primeiro de `models`) |
| `max_lines` | número | `10000` | Máximo de linhas alteradas do PR; ignora a revisão se excedido; `-1` significa ilimitado |
| `user_request` | string | `""` | Conteúdo da solicitação do usuário quando acionado por comentário `@claude` |
| `review_language` | string | `"English"` | Idioma do comentário de revisão (ex. `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`); valor vazio ou não suportado cai para inglês |
| `prompt` | string | (ver arquivo de workflow) | Prompt de revisão personalizado (o requisito de idioma é injetado separadamente com base em `review_language`, não embutido no padrão do prompt) |

## Secrets / vars que o chamador deve configurar

O repositório chamador precisa do seguinte em Settings → Secrets and variables → Actions:

| Tipo | Nome | Obrigatório | Propósito |
|---|---|---|---|
| Secret | `CODE_REVIEW_API_KEY` | ✅ | Chave da API da Anthropic |
| Variable | `CODE_REVIEW_BASE_URL` | Opcional | Usado ao proxyar por um gateway; pode ser omitido ao acessar a API oficial diretamente |
| Variable | `CODE_REVIEW_MODEL` | Não | Nome do modelo padrão no modo de modelo único |
| Variable | `CODE_REVIEW_MODELS` | Não | Lista separada por vírgulas no modo multi-modelo |
| Variable | `CODE_REVIEW_SUMMARY_MODEL` | Não | Nome do modelo de sumário no modo multi-modelo |

> Para compartilhar as mesmas credenciais entre todos os repositórios em uma organização, considere [Secrets e variáveis a nível de organização](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization).

## Requisitos de permissão

O `permissions` do job chamador deve incluir:

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  actions: read
```

A composite action em si não define `permissions`; o job chamador os controla. O reusable workflow define `permissions` em cada um de seus três jobs (`setup` precisa apenas de `contents: read` + `pull-requests: read`; `review`/`summarize` precisam do conjunto completo acima).

## Versionamento

- `v1`: tag móvel, aponta para a versão 1.x mais recente
- `v1.0.0` etc.: tags semânticas que fixam uma versão exata
- `main`: branch de desenvolvimento, não recomendado para uso em produção

Fluxo de release:

```bash
git tag v1.1.0
git push origin v1.1.0
# Move a tag móvel
git tag -f v1 v1.1.0
git push origin v1 --force
```

## Notas de comportamento

### Resolução de modo (apenas reusable workflow)

O job setup decide o modo com base na contagem de `models` parseada:

- `models` parseia para ≥2 → `mode=multi`: revisão paralela em matrix; resultados são escritos em `./claude-review-output.md`, empacotados como artifact; o job `summarize` baixa todos os artifacts, mescla, deduplica, anota a confiança e publica um comentário de sumário.
- `models` parseia para ≤1 → `mode=single`: revisão de modelo único, publica um comentário de PR diretamente, com verificação de qualidade e retry em resultados curtos.

> A composite action está sempre no modo de modelo único, equivalente a `mode=single`.

### Limite de linhas alteradas do PR

- `max_lines > 0`: ignora a revisão se `additions + deletions` do PR exceder este valor; a reexecução manual ignora a verificação do limite.
- `max_lines == -1`: ilimitado.
- `max_lines == 0`: rejeita qualquer PR.

### Minimização de comentários

Antes de cada revisão, chama GraphQL `minimizeComment` para recolher comentários históricos do Claude como `OUTDATED`. Se um comentário de revisão acabar com menos de 100 caracteres, ele é automaticamente minimizado e reexecutado uma vez. No modo multi-modelo, essa lógica roda no job `summarize`.

### Instalação do Claude CLI

- Runner tem o Claude CLI pré-instalado (caso típico de self-hosted): reutilizado diretamente.
- Runner não tem (caso típico de `ubuntu-latest`): o `action.yml` primeiro tenta `npm install -g @anthropic-ai/claude-code`, depois cai para `curl -fsSL https://claude.ai/install.sh | bash` (npm não é afetado por bloqueio geográfico do Claude.ai, recomendado). O reusable workflow apenas detecta o PATH e não instala (depende da pré-instalação no runner self-hosted).

### Formato de saída da revisão

O idioma do comentário é controlado por `review_language` (padrão inglês; valor vazio ou não suportado cai para inglês; passe `Simplified Chinese` para revisões em chinês). Estrutura:

1. **Análise de achados**: ordenada por severidade, com referências `file:line`; no modo multi-modelo cada achado é anotado com `[Consensus N/M]` ou `[Single model]`.
2. **`## TODO Fix List`**: formato fixo parseável por máquina, uma linha por entrada: `- [ ] **[TODO-n] [Pn] \`file:line\`** — Resumo do problema; Requisito de correção: ...`
   - Graduação de severidade: `[P0]` bug crítico / segurança; `[P1]` risco de lógica / regressão de comportamento; `[P2]` desempenho / testes ausentes; `[P3]` estilo.
   - No sumário multi-modelo, entradas são mescladas, deduplicadas e renumeradas como `TODO-1..n` contínuos; anotações de consenso vão após a tag de severidade.
3. **Requires manual attention**: itens que precisam de revisão humana.
4. **(Apenas multi-modelo)** Blocos recolhidos no rodapé com a revisão original de cada modelo.

Veja os padrões de `prompt` em `action.yml` / no arquivo de workflow para detalhes completos.

## Validação local

```bash
# Verificação de sintaxe YAML
python3 -c "import yaml; yaml.safe_load(open('action.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/claude-auto-review.yml'))"

# actionlint (se instalado)
actionlint
```

## Licença

MIT
