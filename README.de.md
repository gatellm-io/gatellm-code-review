# Claude Auto Review

**Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [Português](README.pt.md)

> Die englische Version ist die autoritative Quelle. Andere Sprachen sind Community-Übersetzungen und können hinterherhinken.

Eine wiederverwendbare GitHub Action, die automatisch Code-Reviews für Pull-Requests erstellt. Sie umschließt `anthropics/claude-code-action@v1` und fügt hinzu:

- **Multi-Modell-Parallel-Review + Zusammenfassung**: Wenn ≥2 Modelle konfiguriert sind, reviewed jedes Modell unabhängig; der summarize-Job fasst die Ergebnisse zusammen, dedupliziert sie, annotiert die Konfidenz (`[Consensus N/M]` / `[Single model]`) und nummeriert die TODO-Liste neu. Eine leere Konfiguration fällt auf den Einzelmodell-Modus zurück.
- Schwellenwert für geänderte Zeilen im PR (Standard 10000); wird automatisch übersprungen, wenn überschritten; unterstützt manuelle Neu-Ausführung zur erzwungenen Ausführung.
- Minimiert historische Claude-Kommentare vor jedem Lauf, um das PR-Rauschen gering zu halten.
- Automatische Erkennung der Claude CLI + Fallback-Installation (nutzt vorinstallierte CLI auf Self-Hosted-Runnern wieder).
- Qualitätsprüfung des Reviews (einmalige automatische Wiederholung, wenn der Kommentar zu kurz ist).
- Parametrisierbare Review-Sprache (`review_language`, Standard Englisch, fällt auf Englisch zurück) + maschinen-parsebarer `## TODO Fix List`-Block + Vorlage für den "Requires manual attention"-Abschnitt.

## Zwei Verwendungsmodi

### Modus 1: Composite Action (leichtgewichtige Einzelmodell-Szenarien)

Binden Sie die Action als einen Schritt in Ihren bestehenden PR-Workflow ein. Maximale Flexibilität. **Nur Einzelmodell-Review**; die Ausgabe wird direkt als PR-Kommentar gepostet.

```yaml
# .github/workflows/pr-review.yml (Caller-Repo)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    runs-on: [self-hosted, Linux, fargate-runner]   # oder ubuntu-latest
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
          # Alle anderen Eingaben haben Standardwerte; bei Bedarf überschreiben
```

### Modus 2: Reusable Workflow (empfohlen, unterstützt Multi-Modell)

Ruft den vollständigen `setup → review(matrix) → summarize`-Drei-Stufen-Workflow auf. **Unterstützt Multi-Modell-Parallel-Review und Zusammenfassung**; erspart Ihnen die manuelle Konfiguration von `permissions` / `concurrency` / `runs-on`.

```yaml
# .github/workflows/pr-review.yml (Caller-Repo)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    uses: gatellm-io/gatellm-code-review/.github/workflows/claude-auto-review.yml@v1
    secrets: inherit           # lässt CODE_REVIEW_API_KEY durch
    with:
      runs_on: "self-hosted, Linux, fargate-runner"
      # Einzelmodell: `models` leer lassen, um auf `model` zurückzufallen
      # Multi-Modell: kommaseparierte Modell-Liste übergeben
      # models: "deepseek-v4-pro,claude-sonnet-4,glm-4-plus"
      # summary_model: "claude-sonnet-4"
```

## Eingaben

### Composite-Action-Eingaben (`action.yml`)

| Name | Typ | Standard | Beschreibung |
|---|---|---|---|
| `anthropic_api_key` | string | `""` | Anthropic-API-Schlüssel (Caller muss explizit übergeben, z.B. `${{ secrets.CODE_REVIEW_API_KEY }}`) |
| `anthropic_base_url` | string | `""` | Basis-URL der Anthropic-API (Caller muss explizit übergeben, z.B. `${{ vars.CODE_REVIEW_BASE_URL }}`; wird verwendet, wenn über einen Gateway proxied wird) |
| `github_token` | string | `${{ github.token }}` | GitHub-Token; benötigt `pull-requests: write`, `issues: write`, `actions: read` |
| `model` | string | `""` | Name des Einzelmodells (Caller kann `${{ vars.CODE_REVIEW_MODEL }}` oder einen Literal übergeben; leer = Standardmodell der Claude-CLI verwenden) |
| `max_lines` | number | `10000` | Maximal geänderte Zeilen im PR; Review überspringen, wenn überschritten; `-1` bedeutet unbegrenzt |
| `user_request` | string | `""` | Inhalt der Benutzeranfrage, wenn durch `@claude`-Kommentar ausgelöst |
| `review_language` | string | `"English"` | Sprache der Review-Kommentare (z.B. `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`); leerer oder nicht unterstützter Wert fällt auf Englisch zurück |
| `prompt` | string | (siehe `action.yml`) | Benutzerdefinierter Review-Prompt (Sprachanforderung wird separat basierend auf `review_language` injiziert, nicht in den Standard-Prompt eingebacken) |

### Reusable-Workflow-Eingaben (`.github/workflows/claude-auto-review.yml`)

| Name | Typ | Standard | Beschreibung |
|---|---|---|---|
| `runs_on` | string | `"self-hosted, Linux, fargate-runner"` | Runner-Labels, kommasepariert oder ein einzelnes Label; auf setup/review/summarize-Jobs angewendet |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | Name des Einzelmodells (verwendet, wenn `models` leer ist) |
| `models` | string | `${{ vars.CODE_REVIEW_MODELS }}` | Kommaseparierte Modell-Liste (≥2 aktiviert den Multi-Modell-Parallel-Modus; max. 3, weitere werden abgeschnitten) |
| `summary_model` | string | `${{ vars.CODE_REVIEW_SUMMARY_MODEL }}` | Name des Zusammenfassungs-Modells (im Multi-Modell-Modus verwendet; leer übernimmt das erste aus `models`) |
| `max_lines` | number | `10000` | Maximal geänderte Zeilen im PR; Review überspringen, wenn überschritten; `-1` bedeutet unbegrenzt |
| `user_request` | string | `""` | Inhalt der Benutzeranfrage, wenn durch `@claude`-Kommentar ausgelöst |
| `review_language` | string | `"English"` | Sprache der Review-Kommentare (z.B. `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`); leerer oder nicht unterstützter Wert fällt auf Englisch zurück |
| `prompt` | string | (siehe Workflow-Datei) | Benutzerdefinierter Review-Prompt (Sprachanforderung wird separat basierend auf `review_language` injiziert, nicht in den Standard-Prompt eingebacken) |

## Secrets / Variablen, die der Caller konfigurieren muss

Das Caller-Repo benötigt Folgendes unter Settings → Secrets and variables → Actions:

| Typ | Name | Erforderlich | Zweck |
|---|---|---|---|
| Secret | `CODE_REVIEW_API_KEY` | ✅ | Anthropic-API-Schlüssel |
| Variable | `CODE_REVIEW_BASE_URL` | Optional | Wird verwendet, wenn über einen Gateway proxied wird; kann weggelassen werden, wenn die offizielle API direkt angesprochen wird |
| Variable | `CODE_REVIEW_MODEL` | Nein | Standard-Modellname im Einzelmodell-Modus |
| Variable | `CODE_REVIEW_MODELS` | Nein | Kommaseparierte Liste im Multi-Modell-Modus |
| Variable | `CODE_REVIEW_SUMMARY_MODEL` | Nein | Name des Zusammenfassungs-Modells im Multi-Modell-Modus |

> Um dieselben Zugangsdaten über alle Repos einer Organisation zu teilen, siehe [Organization-level secrets and variables](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization).

## Berechtigungsanforderungen

Die `permissions` des Caller-Jobs müssen umfassen:

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  actions: read
```

Die Composite-Action selbst setzt keine `permissions`; der Caller-Job steuert diese. Der Reusable-Workflow setzt `permissions` auf jedem seiner drei Jobs (`setup` benötigt nur `contents: read` + `pull-requests: read`; `review`/`summarize` benötigen den vollständigen Satz oben).

## Versionierung

- `v1`: rollierender Tag, zeigt auf das neueste 1.x-Release
- `v1.0.0` etc.: semantische Tags, die eine exakte Version fixieren
- `main`: Entwicklungs-Branch, nicht für den Produktiv-Einsatz empfohlen

Release-Ablauf:

```bash
git tag v1.1.0
git push origin v1.1.0
# Den rollierenden Tag verschieben
git tag -f v1 v1.1.0
git push origin v1 --force
```

## Hinweise zum Verhalten

### Modus-Auflösung (nur Reusable-Workflow)

Der setup-Job entscheidet den Modus basierend auf der geparsten `models`-Anzahl:

- `models` parst zu ≥2 → `mode=multi`: paralleles Matrix-Review; Ergebnisse werden nach `./claude-review-output.md` geschrieben und als Artifact paketiert; der `summarize`-Job lädt alle Artifacts herunter, fasst zusammen, dedupliziert, annotiert die Konfidenz und postet einen Zusammenfassungs-Kommentar.
- `models` parst zu ≤1 → `mode=single`: Einzelmodell-Review, postet direkt einen PR-Kommentar, mit Qualitätsprüfung und Wiederholung bei kurzem Ergebnis.

> Die Composite-Action ist immer im Einzelmodell-Modus, äquivalent zu `mode=single`.

### Schwellenwert für geänderte PR-Zeilen

- `max_lines > 0`: Review überspringen, wenn PR `additions + deletions` diesen Wert überschreitet; manuelle Neu-Ausführung umgeht die Schwellenwert-Prüfung.
- `max_lines == -1`: unbegrenzt.
- `max_lines == 0`: lehnt jeden PR ab.

### Kommentar-Minimierung

Vor jedem Review wird GraphQL `minimizeComment` aufgerufen, um historische Claude-Kommentare als `OUTDATED` einzuklappen. Wenn ein Review-Kommentar kürzer als 100 Zeichen ausfällt, wird er automatisch minimiert und einmalig wiederholt. Im Multi-Modell-Modus läuft diese Logik im `summarize`-Job.

### Claude-CLI-Installation

- Runner hat die Claude-CLI vorinstalliert (typischer Self-Hosted-Fall): wird direkt wiederverwendet.
- Runner hat sie nicht (typischer `ubuntu-latest`-Fall): `action.yml` versucht zuerst `npm install -g @anthropic-ai/claude-code`, fällt dann auf `curl -fsSL https://claude.ai/install.sh | bash` zurück (npm ist vom Claude.ai-Geo-Block nicht betroffen, empfohlen). Der Reusable-Workflow erkennt nur die PATH und installiert nicht (baut auf die Vorinstallation des Self-Hosted-Runners).

### Format der Review-Ausgabe

Die Sprache der Kommentare wird über `review_language` gesteuert (Standard Englisch; leerer oder nicht unterstützter Wert fällt auf Englisch zurück; `Simplified Chinese` für chinesische Reviews übergeben). Struktur:

1. **Ergebnisanalyse**: nach Schweregrad sortiert, mit `file:line`-Referenzen; im Multi-Modell-Modus wird jeder Befund mit `[Consensus N/M]` oder `[Single model]` annotiert.
2. **`## TODO Fix List`**: maschinen-parsebares festes Format, eine Zeile pro Eintrag: `- [ ] **[TODO-n] [Pn] \`file:line\`** — Problembeschreibung; Behebungsanforderung: ...`
   - Schweregrad-Einstufung: `[P0]` kritischer Bug / Sicherheit; `[P1]` Logik-Risiko / Verhaltens-Regression; `[P2]` Performance / fehlende Tests; `[P3]` Stil.
   - In der Multi-Modell-Zusammenfassung werden Einträge zusammengeführt, dedupliziert und als durchlaufende `TODO-1..n` neu nummeriert; Konsens-Annotationen stehen nach dem Schweregrad-Tag.
3. **Requires manual attention**: Punkte, die eine menschliche Prüfung benötigen.
4. **(Nur Multi-Modell)** Eingeklappte Blöcke am Ende mit dem ursprünglichen Review jedes Modells.

Einzelheiten zum Standard-`prompt` siehe `action.yml` / die Workflow-Datei.

## Lokale Validierung

```bash
# YAML-Syntax-Prüfung
python3 -c "import yaml; yaml.safe_load(open('action.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/claude-auto-review.yml'))"

# actionlint (falls installiert)
actionlint
```

## Lizenz

MIT
