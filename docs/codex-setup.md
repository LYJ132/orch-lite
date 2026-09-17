# Codex Desktop Setup Guide (orch-lite)

This guide covers two Codex-specific steps beyond the basic plugin install:

1. **Enabling multi-agent v2** (required for orch-lite orchestration to spawn sub-agents).
2. **Trusting the bundled hooks** (otherwise Codex marks them `untrusted` and refuses to run them).

All paths below use `~/.codex/` (on Windows: `%USERPROFILE%\.codex\`). Config changes only take effect after restarting Codex Desktop or opening a new CLI session — hook snapshots are loaded at session start.

Verified on a recent Codex Desktop (MSIX) / codex CLI build. Exact behavior may differ on other builds.

---

## 1. Enable multi-agent v2

multi-agent v2 is controlled by **two switches**, both of which must be set:

### Switch 1: backend feature flag

Add to `~/.codex/config.toml`:

```toml
[features]
multi_agent_v2 = true
```

The standard way is `codex features enable multi_agent_v2` (run it in your own terminal). If it fails, editing the file directly is equivalent.

### Switch 2: model catalog entry

The flag only applies to models whose catalog entry declares `"multi_agent_version": "v2"`. Built-in OpenAI models marked v2 include `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-6-astra`, and `gpt-daybreak-blue/red-latest`. If you use a custom/relay model, edit your catalog JSON in `~/.codex/model-catalogs/` and add to the model entry:

```json
"multi_agent_version": "v2",
"multi_agent_reasoning_effort": "xhigh"
```

`multi_agent_version` is the required field; `multi_agent_reasoning_effort` is optional (controls sub-agent reasoning effort; `xhigh` matches the built-in v2 models, use `low`/`medium` if too slow).

### Verify

```bash
codex features list
```

You should see `multi_agent_v2  stable  true` (it is `false` by default; the v1 `multi_agent` flag is on by default and is not sufficient).

Then restart Codex Desktop and smoke-test: ask the main session to spawn a sub-agent — it should run independently and return its result.

### Optional tuning

`multi_agent_v2` also accepts a structured table with 16 fields (concurrency limits, wait timeouts, etc.):

```toml
[features.multi_agent_v2]
max_concurrent_threads_per_session = 8
# min_wait_timeout_ms / max_wait_timeout_ms / default_wait_timeout_ms
# tool_namespace, wait_agent_enabled, ...
```

Defaults are fine in almost all cases.

### Rollback

```bash
codex features disable multi_agent_v2
```

Then remove the two lines added to the model catalog JSON and restart Codex Desktop.

---

## 2. Trust the bundled hooks

### Why hooks show as "untrusted"

Codex persists hook trust decisions in `~/.codex/config.toml` under `hooks.state`, keyed by hook identity and guarded by a `trusted_hash` — a SHA-256 of the hook command it first recorded. When a plugin ships new hooks, Codex sees no matching trust record, marks them `untrusted`, and **silently refuses to execute them**. Trusting via `/hooks` (CLI) or manual config adds the trusted_hash entries.

### What you should end up with

The orch-lite plugin ships two hooks that Codex discovers automatically from the plugin's `hooks/hooks.json` (no file copying is needed — only trust configuration is):

| Hook | Purpose |
|---|---|
| `sessionStart` | Runs `session-init.py`: injects the orch-lite routing instructions and state summary at session start |
| `preToolUse` | Matches `spawn_agent\|Agent\|Task`, runs `dispatch-validate.py` to validate sub-agent dispatch packages |

After correct setup, `~/.codex/config.toml` contains (hashes below are for plugin 1.2.0; if your version differs, re-trust via `/hooks` instead of copying these):

```toml
[hooks.state."orch-lite@orch-lite:hooks/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:978e3ec0000beda699376b74e2c71c7292ebfbb26716dbdb0f3c1ccea13d822a"

[hooks.state."orch-lite@orch-lite:hooks/hooks.json:session_start:0:0"]
trusted_hash = "sha256:633ce887845a96bf39783d20c0a6dc8ba4e99b25bec8d2352f081d327e1241aa"
```

### Manual steps (idempotent)

1. **Back up** `~/.codex/config.toml` (e.g. copy it to `config.toml.bak-orch-lite`).
2. Check whether the two `hooks.state` entries above already exist.
3. If not, append them idempotently (either re-run `/hooks` and trust each hook, or add the entries manually).
4. **Restart** Codex Desktop or open a new CLI session.

### Verify

```bash
# Linux/macOS
grep orch-lite ~/.codex/config.toml
```

```powershell
# Windows PowerShell
Get-Content "$env:USERPROFILE\.codex\config.toml" | Select-String "orch-lite"
```

The Desktop UI does not always display trusted plugin hooks, so the more reliable check is behavioral: open a **new session** and confirm the orch-lite injection appears at the start. `sessionStart` fires at session start; `preToolUse` only fires when a sub-agent is actually dispatched.

### Notes

- `hooks.state` is Codex's persistent trust state, not ordinary project configuration.
- If the plugin version changes, hook content/hashes may change and Codex may show the state as `modified` — re-review and re-trust.
- **Rollback**: restore from the `config.toml.bak-*` backup you made in step 1.

---

## Further reading

- [SubagentStart hook design notes](codex-subagent-start.md) — the third bundled hook, with its full internal design document.
