# Maintenance (maintainer-facing — not runtime-injected)

> This file is NOT injected into sessions: SKILL.md is the AI's runtime document; the hooks/deployment content below is for humans maintaining the skill.

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
4. **`~/.zcode/skills/orch-lite/` is the primary editing target** — it is the copy wired to the registered hooks. After each change-set, propagate to `~/.agents/skills/orch-lite/`, `/home/linyujian/PROGRAMS/.agents/skills/orch-lite/`, and the plugin source `/home/linyujian/PROGRAMS/orch-lite/plugins/orch-lite/` (its `SKILL.md` lives at `skills/orch-lite/SKILL.md` inside the plugin), preserving exec bits and LF. Verify a propagation with `python3 scripts/multi-agent doctor` (default target `~/.agents/skills/orch-lite`; `--compare-dir DIR` points it at another install): check (4) compares HEAD's tracked sources (`.gitignore`, `hooks/`, `references/`, `scripts/`, `tests/`, plus `SKILL.md` at whichever location HEAD tracks) by blob hash against that copy and prints one `drift: <path> …` line per differing / one-side-missing file — nothing means the two installs agree (or the copy is absent). **Dual layout (Phase 1):** `SKILL.md` may sit at the repo root (flat install) or at `skills/orch-lite/SKILL.md` (plugin layout); doctor matches the `SKILL.md` role across layouts, so a flat copy vs a plugin HEAD compares normally instead of reporting every path missing — the repo itself is plugin layout since Phase 1, while the `~/.agents` copies stay flat.
5. **Hooks are snapshotted at session start** — config/permission fixes only take effect in a NEW session; already-open sessions keep running the old (possibly dead) snapshot.
