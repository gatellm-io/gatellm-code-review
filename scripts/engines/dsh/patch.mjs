#!/usr/bin/env node
// Generate the dsh configuration overlay for one review run.
//
// dsh has no --model flag in headless mode. The model and the gateway are
// deployment configuration, so they are injected as a patch layer passed with
// `dsh --patch <file>`, the launcher's documented mechanism for a static
// layer written by the deployer (it takes precedence over the profile layer).
//
// `$DSH_HOME/settings.yaml` is deliberately NOT used: dsh 0.2 only imports that
// legacy file *after* the first boot has settled, so a fresh DSH_HOME (one per
// run, to keep matrix legs isolated) would never see it in the run that
// matters.
//
// Each entry's `config` is a full-line replacement, not a deep merge, so only
// fields the owning plugin actually declares are emitted. Permissions are not
// patched at all: DSH_PERMISSION_MODE=danger-full-access is exported by
// run.sh and rewrites both the sandbox mode and the approval policy without
// needing a copy of the preset table.
//
// That replacement semantics was verified against @deepseek-ai/dsh 0.2.2-rc.1,
// the version in DEFAULT_VERSION. tests/dsh-engine.sh pins that version and the
// emitted entry shape, so bumping the default is a deliberate change that has
// to be re-validated rather than a silent one.
//
// The document is JSON, which is valid YAML: no hand-built YAML quoting, so a
// model id or URL containing `:` or `#` cannot corrupt it. The API key is
// referenced by environment-variable name only, never written here.

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

const PROVIDER_ID = 'gatellm-review';
const API_KEY_ENV = 'GATELLM_REVIEW_API_KEY';

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

function positiveInt(value) {
  if (typeof value !== 'string' || !/^[1-9][0-9]*$/.test(value.trim())) {
    return undefined;
  }
  return Number.parseInt(value.trim(), 10);
}

// dsh appends `/v1/messages` to baseURL. A caller who copied an
// OpenAI-style endpoint ending in `/v1` would otherwise get `/v1/v1/messages`,
// so drop exactly one *trailing* `/v1` segment after removing trailing slashes:
// the resulting request URL is identical either way. A `/v1` that is followed
// by a path segment (`.../v1/foo`) is part of the base path and is left alone.
function normalizeBaseURL(raw) {
  const trimmed = (raw || '').trim();
  if (!trimmed) {
    return 'https://api.anthropic.com';
  }
  const withoutSlash = trimmed.replace(/\/+$/, '');
  return withoutSlash.replace(/\/v1$/, '');
}

const target = (process.env.DSH_PATCH_FILE || '').trim();
if (!target) {
  fail('DSH_PATCH_FILE is required');
}

const rawModel = (process.env.MODEL || '').trim();
if (!rawModel) {
  fail('MODEL is required');
}
// `[1m]` is a Claude Code convention marking the 1M-token variant. Claude Code
// strips it itself; dsh would forward it verbatim to the gateway. This is
// unconditional: a caller whose gateway exposes a literal model id ending in
// `[1m]` must configure that id without the suffix (see README, dsh specifics).
const model = rawModel.replace(/\[1m\]$/i, '');

const baseURL = normalizeBaseURL(process.env.ANTHROPIC_BASE_URL);
const contextWindow = positiveInt(process.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS || '');
const maxTokens = positiveInt(process.env.CLAUDE_CODE_MAX_OUTPUT_TOKENS || '');

const modelEntry = { id: model };
if (contextWindow !== undefined) {
  modelEntry.contextWindow = contextWindow;
}
if (maxTokens !== undefined) {
  modelEntry.maxTokens = maxTokens;
}

const patch = [
  {
    id: 'agent-default-model',
    name: '@deepseek-ai/dsh-agent-default-model',
    config: { provider: PROVIDER_ID, model },
  },
  {
    id: 'llm-pi-ai',
    name: '@deepseek-ai/dsh-llm-pi-ai',
    config: {
      providers: {
        [PROVIDER_ID]: {
          displayName: 'gatellm-code-review gateway',
          apiKeyEnv: API_KEY_ENV,
          api: 'anthropic-messages',
          baseURL,
          models: [modelEntry],
        },
      },
    },
  },
];

mkdirSync(dirname(target), { recursive: true });
writeFileSync(target, `${JSON.stringify(patch, null, 2)}\n`, { mode: 0o600 });

console.log(
  `Wrote ${target}: provider=${PROVIDER_ID} model=${model} api=anthropic-messages ` +
    `baseURL=${baseURL} contextWindow=${contextWindow ?? 'unset'} maxTokens=${maxTokens ?? 'unset'}`,
);
if (model !== rawModel) {
  console.log(`Stripped the [1m] context-window suffix from the model name: ${rawModel} -> ${model}`);
}
