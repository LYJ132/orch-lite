# Maintenance (maintainer-facing — not runtime-injected)

> This file is NOT injected into sessions: SKILL.md is the AI's runtime document; the hooks/deployment content below is for humans maintaining the skill.

---

## Install

Two supported installation paths (self-hosted marketplace; pick exactly one):

1. **GitHub marketplace (recommended):** in ZCode's plugin Discover UI, press `+` and add the repository `LYJ132/orch-lite`. The marketplace manifest lives at `.claude-plugin/marketplace.json` (plugin source = repo root, skills at `./skills/`).
2. **Local directory (development):** clone the repo and point the plugin loader at the local checkout directory (e.g. `/home/linyujian/.zcode/plugins-src/orch-lite`).

**No double install.** Installing the plugin makes it the single install — a pre-existing flat copy (e.g. `~/.agents/skills/orch-lite`) must be retired and its absolute-path hook entries removed from `~/.zcode/cli/config.json` (`SessionStart` + `PreToolUse`), otherwise the same hooks and skills register twice. The plugin manifest already registers both hooks via `hooks/hooks.json` using `${CLAUDE_PLUGIN_ROOT}`.

---

## Hooks

| Hook | Event | Purpose |
|---|---|---|
| `session-init.py` | `SessionStart` | idempotent `init` + inject `index list` + probe `doctor` (Health) + inject the "Request Routing" and "Dispatch Package (MUST template)" sections verbatim from SKILL.md |
| `dispatch-validate.py` | `PreToolUse` on `Agent\|Task` | enforces N15 by validating the fenced-JSON dispatch block (4 required fields; `feature_id` branch-safe) via the ZCode exit-code contract: pass → silent exit 0, deny → reason on stderr + exit 2, internal error → fail-open exit 0 (never JSON on stdout) |

Both idempotent, degrade gracefully, never block.

---

## Development & Maintenance

Process documents (changelog, open questions P1–P8, design decisions) live **outside the skill** in `PROGRAMS/docs/lo-meta/` — not read at runtime.

### Deployment rules (each was a real silent failure)

1. **Copy/sync preserves exec bits and LF.** A `-rw-r--r--` script or a CRLF shebang (`env: 'python3\r'`) kills every hook with no visible error. Self-check after any sync: `ls -l hooks/ scripts/` (all must show `x`) and `grep -r $'\r' hooks/ scripts/` (must be empty).
2. **`~/.zcode/cli/config.json` hook paths are absolute** — renaming the skill directory requires updating them.
3. **Marketplace installers strip exec bits (observed 2026-09-13: cache 644 vs source 755)** — hook commands MUST invoke via `bash <path>`, never bare path.
4. **The plugin install is the only install.** The flat copies (`~/.agents/skills/orch-lite/`, retired 2026-09-13 via tar snapshot `~/.agents/skills/orch-lite-flat-backup-20260913.tar.gz` + `mv` to `orch-lite-flat-retired`) and `~/.zcode/skills/orch-lite/` are no longer live targets — the plugin (repo checkout / marketplace cache) is the single source of truth; edit here and reinstall/refresh the plugin to propagate. `doctor`'s default `--compare-dir` (`~/.agents/skills/orch-lite`) now points at an absent path and degrades to a lenient all-clear on check (4) by design; pass `--compare-dir` explicitly to compare against a live copy. **Dual layout (Phase 1):** `SKILL.md` may sit at the repo root (flat install) or at `skills/orch-lite/SKILL.md` (plugin layout); doctor matches the `SKILL.md` role across layouts, so a flat copy vs a plugin HEAD compares normally instead of reporting every path missing — the repo itself is plugin layout since Phase 1.
5. **Hooks are snapshotted at session start** — config/permission fixes only take effect in a NEW session; already-open sessions keep running the old (possibly dead) snapshot.
