# Claude Auto Review

**Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [Português](README.pt.md)

> La version anglaise est la source faisant autorité. Les autres langues sont des traductions communautaires et peuvent être en retard.

Une GitHub Action réutilisable qui génère automatiquement des revues de code pour les pull requests. Encapsule `anthropics/claude-code-action@v1` et ajoute :

- **Revue multi-modèles parallèle + synthèse** : lorsque ≥2 modèles sont configurés, chaque modèle révise indépendamment ; le job de synthèse fusionne et déduplique les découvertes, annote le niveau de confiance (`[Consensus N/M]` / `[Single model]`), et renumérote la liste TODO. Une configuration vide bascule en mode mono-modèle.
- Seuil de lignes modifiées de la PR (par défaut 10000) ; ignorer automatiquement lorsque dépassé ; prend en charge le re-run manuel pour forcer l'exécution.
- Minimise les commentaires historiques de Claude avant chaque exécution pour réduire le bruit sur la PR.
- Auto-détection + installation de repli du CLI Claude (réutilise le CLI préinstallé sur les runners self-hosted).
- Contrôle qualité de la revue (réessaie automatiquement une fois lorsque le commentaire est trop court).
- Langue de revue paramétrable (`review_language`, anglais par défaut, repli sur l'anglais) + bloc `## TODO Fix List` analysable machine + gabarit de section « Requires manual attention ».

## Deux modes d'utilisation

### Mode 1 : Action Composite (scénarios mono-modèle légers)

Intégrez l'action comme une étape de votre workflow PR existant. Flexibilité maximale. **Revue mono-modèle uniquement** ; le résultat est publié directement sous forme de commentaire sur la PR.

```yaml
# .github/workflows/pr-review.yml (dépôt appelant)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    runs-on: [self-hosted, Linux, fargate-runner]   # ou ubuntu-latest
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
          # Toutes les autres entrées ont des valeurs par défaut ; surchargez selon vos besoins
```

### Mode 2 : Workflow Réutilisable (recommandé, prend en charge le multi-modèle)

Appelle le workflow complet en trois étapes `setup → review(matrix) → summarize`. **Prend en charge la revue multi-modèles parallèle et la synthèse** ; vous évite de configurer vous-même `permissions` / `concurrency` / `runs-on`.

```yaml
# .github/workflows/pr-review.yml (dépôt appelant)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    uses: gatellm-io/gatellm-code-review/.github/workflows/claude-auto-review.yml@v1
    secrets: inherit           # permet à CODE_REVIEW_API_KEY de passer
    with:
      runs_on: "self-hosted, Linux, fargate-runner"
      # Mono-modèle : laissez `models` vide pour basculer vers `model`
      # Multi-modèle : passez une liste de modèles séparée par des virgules
      # models: "deepseek-v4-pro,claude-sonnet-4,glm-4-plus"
      # summary_model: "claude-sonnet-4"
```

## Entrées

### Entrées de l'Action Composite (`action.yml`)

| Nom | Type | Défaut | Description |
|---|---|---|---|
| `anthropic_api_key` | string | `""` | Clé API Anthropic (l'appelant doit la passer explicitement, par ex. `${{ secrets.CODE_REVIEW_API_KEY }}`) |
| `anthropic_base_url` | string | `""` | URL de base de l'API Anthropic (l'appelant doit la passer explicitement, par ex. `${{ vars.CODE_REVIEW_BASE_URL }}` ; utilisée en cas de passage via une passerelle) |
| `github_token` | string | `${{ github.token }}` | Jeton GitHub ; nécessite `pull-requests: write`, `issues: write`, `actions: read` |
| `model` | string | `""` | Nom du modèle unique (l'appelant peut passer `${{ vars.CODE_REVIEW_MODEL }}` ou un littéral ; vide = utiliser le modèle par défaut du CLI Claude) |
| `max_lines` | number | `10000` | Nombre maximum de lignes modifiées de la PR ; ignorer la revue si dépassé ; `-1` signifie illimité |
| `user_request` | string | `""` | Contenu de la demande utilisateur lorsqu'elle est déclenchée par un commentaire `@claude` |
| `review_language` | string | `"English"` | Langue du commentaire de revue (par ex. `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`) ; une valeur vide ou non prise en charge bascule vers l'anglais |
| `prompt` | string | (voir `action.yml`) | Invite de revue personnalisée (l'exigence de langue est injectée séparément en fonction de `review_language`, non intégrée dans l'invite par défaut) |

### Entrées du Workflow Réutilisable (`.github/workflows/claude-auto-review.yml`)

| Nom | Type | Défaut | Description |
|---|---|---|---|
| `runs_on` | string | `"self-hosted, Linux, fargate-runner"` | Étiquettes du runner, séparées par des virgules ou une seule étiquette ; appliquées aux jobs setup/review/summarize |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | Nom du modèle unique (utilisé lorsque `models` est vide) |
| `models` | string | `${{ vars.CODE_REVIEW_MODELS }}` | Liste de modèles séparés par des virgules (≥2 active le mode parallèle multi-modèles ; max 3, les excédents sont tronqués) |
| `summary_model` | string | `${{ vars.CODE_REVIEW_SUMMARY_MODEL }}` | Nom du modèle de synthèse (utilisé en mode multi-modèles ; vide prend le premier de `models`) |
| `max_lines` | number | `10000` | Nombre maximum de lignes modifiées de la PR ; ignorer la revue si dépassé ; `-1` signifie illimité |
| `user_request` | string | `""` | Contenu de la demande utilisateur lorsqu'elle est déclenchée par un commentaire `@claude` |
| `review_language` | string | `"English"` | Langue du commentaire de revue (par ex. `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`) ; une valeur vide ou non prise en charge bascule vers l'anglais |
| `prompt` | string | (voir le fichier de workflow) | Invite de revue personnalisée (l'exigence de langue est injectée séparément en fonction de `review_language`, non intégrée dans l'invite par défaut) |

## Secrets / vars que l'appelant doit configurer

Le dépôt appelant a besoin des éléments suivants dans Settings → Secrets and variables → Actions :

| Type | Nom | Requis | Objectif |
|---|---|---|---|
| Secret | `CODE_REVIEW_API_KEY` | ✅ | Clé API Anthropic |
| Variable | `CODE_REVIEW_BASE_URL` | Optionnel | Utilisé en cas de passage via une passerelle ; peut être omis en cas d'accès direct à l'API officielle |
| Variable | `CODE_REVIEW_MODEL` | Non | Nom du modèle par défaut en mode mono-modèle |
| Variable | `CODE_REVIEW_MODELS` | Non | Liste séparée par des virgules en mode multi-modèles |
| Variable | `CODE_REVIEW_SUMMARY_MODEL` | Non | Nom du modèle de synthèse en mode multi-modèles |

> Pour partager les mêmes identifiants entre tous les dépôts d'une organisation, envisagez les [Secrets et variables au niveau de l'organisation](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization).

## Exigences de permission

Le `permissions` du job appelant doit inclure :

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  actions: read
```

L'action composite elle-même ne définit pas `permissions` ; c'est le job appelant qui les contrôle. Le workflow réutilisable définit `permissions` sur chacun de ses trois jobs (`setup` n'a besoin que de `contents: read` + `pull-requests: read` ; `review`/`summarize` nécessitent l'ensemble complet ci-dessus).

## Versionnage

- `v1` : étiquette roulante, pointe vers la dernière version 1.x
- `v1.0.0` etc. : étiquettes sémantiques qui épinglent une version exacte
- `main` : branche de développement, non recommandée pour la production

Flux de release :

```bash
git tag v1.1.0
git push origin v1.1.0
# Déplacer l'étiquette roulante
git tag -f v1 v1.1.0
git push origin v1 --force
```

## Notes de comportement

### Résolution du mode (workflow réutilisable uniquement)

Le job setup décide du mode en fonction du nombre de `models` analysés :

- `models` analyse à ≥2 → `mode=multi` : revue parallèle matricielle ; les résultats sont écrits dans `./claude-review-output.md`, empaquetés en artefact ; le job `summarize` télécharge tous les artefacts, fusionne, déduplique, annote la confiance et publie un commentaire de synthèse.
- `models` analyse à ≤1 → `mode=single` : revue mono-modèle, publie directement un commentaire sur la PR, avec contrôle qualité et réessai en cas de résultat court.

> L'action composite est toujours en mode mono-modèle, équivalent à `mode=single`.

### Seuil de lignes modifiées de la PR

- `max_lines > 0` : ignorer la revue si `additions + deletions` de la PR dépasse cette valeur ; le re-run manuel ignore la vérification du seuil.
- `max_lines == -1` : illimité.
- `max_lines == 0` : rejette toute PR.

### Minimisation des commentaires

Avant chaque revue, appelle GraphQL `minimizeComment` pour replier les commentaires historiques de Claude comme `OUTDATED`. Si un commentaire de revue finit par faire moins de 100 caractères, il est automatiquement minimisé et réessayé une fois. En mode multi-modèles, cette logique s'exécute dans le job `summarize`.

### Installation du CLI Claude

- Le runner a le CLI Claude préinstallé (cas typique self-hosted) : réutilisé directement.
- Le runner ne l'a pas (cas typique `ubuntu-latest`) : `action.yml` essaie d'abord `npm install -g @anthropic-ai/claude-code`, puis bascule vers `curl -fsSL https://claude.ai/install.sh | bash` (npm n'est pas affecté par le blocage géographique de Claude.ai, recommandé). Le workflow réutilisable détecte uniquement le PATH et n'installe rien (s'appuie sur le pré-installé du runner self-hosted).

### Format de sortie de la revue

La langue du commentaire est contrôlée par `review_language` (anglais par défaut ; une valeur vide ou non prise en charge bascule vers l'anglais ; passez `Simplified Chinese` pour des revues en chinois). Structure :

1. **Analyse des découvertes** : ordonnée par sévérité, avec des références `file:line` ; en mode multi-modèles, chaque découverte est annotée avec `[Consensus N/M]` ou `[Single model]`.
2. **`## TODO Fix List`** : format fixe analysable machine, une ligne par entrée : `- [ ] **[TODO-n] [Pn] \`file:line\`** — Résumé du problème ; Exigence de correction : ...`
   - Gradation de sévérité : `[P0]` bug critique / sécurité ; `[P1]` risque logique / régression comportementale ; `[P2]` performance / tests manquants ; `[P3]` style.
   - Dans la synthèse multi-modèles, les entrées sont fusionnées, dédupliquées et renumérotées en `TODO-1..n` continu ; les annotations de consensus vont après l'étiquette de sévérité.
3. **Requires manual attention** : éléments qui nécessitent une revue humaine.
4. **(Multi-modèles uniquement)** Blocs repliés en bas avec la revue originale de chaque modèle.

Voir les valeurs par défaut de `prompt` dans `action.yml` / le fichier de workflow pour plus de détails.

## Validation locale

```bash
# Vérification de la syntaxe YAML
python3 -c "import yaml; yaml.safe_load(open('action.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/claude-auto-review.yml'))"

# actionlint (si installé)
actionlint
```

## Licence

MIT
