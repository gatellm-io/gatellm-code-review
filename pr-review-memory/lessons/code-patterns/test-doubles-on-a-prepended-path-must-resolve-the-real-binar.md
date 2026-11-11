---
title: Test doubles on a prepended PATH must resolve the real binary, not hardcode a path
topic: code-patterns
paths: ["tests/dsh-engine.sh","scripts/engines/dsh/run.sh"]
tags: ["testing","shell","portability"]
sources: ["#8"]
created: 2026-11-11
---
When a test prepends a fake binary directory to PATH to simulate a tool failure, the fake usually needs to forward the calls it is *not* meant to fail. Hardcoding the real path (e.g. `exec /usr/bin/sed "$@"`) silently changes which code path the test exercises on systems where the tool lives elsewhere (busybox/Alpine at /bin/sed, NixOS in /nix/store, Homebrew on macOS). Worse, if the forwarded call also fails, the test may still pass while exercising a different branch than its comment claims.

**Concrete action:** resolve the real binary once at harness start, before any PATH override (`REAL_SED="$(command -v sed)"`), pass it to each case through the environment, and have the fake `exec "$REAL_SED" "$@"`. Then assert on wording unique to each branch — a generic prefix printed by multiple branches (e.g. "Could not redact credentials") proves nothing about which branch ran. Add an explicit up-front prerequisite check for every tool the harness itself invokes, so a missing tool fails with "FAIL: <tool> is required" instead of a puzzling assertion.

④ 出处：tests/dsh-engine.sh resolves REAL_SED before the sandbox loop, fake sed scripts exec "$REAL_SED", test-redact-fail asserts the per-file wording ('removed it from the uploaded diagnostics') and test-redact-nopattern asserts the scrubber-build wording ('failed to escape a scrubber pattern'), both in scripts/engines/dsh/run.sh.
