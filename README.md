<div align="center">

# dev-forge

**A self-hosted development toolchain: a JSON-configured hooks engine for Claude Code, scheduled patrol autopilots, and a bootstrap/doctor/rollback installer.**

[![ci](https://github.com/tadki/dev-forge/actions/workflows/ci.yml/badge.svg)](https://github.com/tadki/dev-forge/actions/workflows/ci.yml)
![license](https://img.shields.io/badge/license-MIT-blue)

</div>

---

## What is this

dev-forge is a standalone repository that hosts development tooling which used to
live inside individual project repositories. It currently provides:

- **Hooks engine** — a single JSON-configured rules engine wired into Claude Code's
  nine hook points. Rules are data (`rules-v2.json` + `rules.d/*.json`), business
  scripts are pluggable, and the engine is fail-open by design: any internal error
  passes the original payload through instead of blocking the host tool.
- **Autopilots** — scheduled patrol scripts (issue hygiene, repo checks, release
  watching) that emit structured JSON for an agent to act on.
- **Installer** — idempotent `bootstrap.sh` to wire the hooks into
  `~/.claude/settings.json`, `doctor.sh` for repeatable health checks, and
  `rollback.sh` to restore the previous registration.
- **Launch sentinels** — a systemd service template + env-injected start script
  for keeping daemons alive on a workstation.

Design principles:

- **Single source of truth** — register the hook entry by absolute path into this
  checkout; editing a file here takes effect immediately. No deployment copying,
  no symlinks.
- **Decoupled** — no machine- or project-specific paths in code; target
  repositories are provided via environment (`TARGET_REPO_ROOT`). Repo-scoped
  behavior lives in rule `when` conditions, not in the engine.
- **Data-driven** — adding or changing a rule is a JSON edit; adding a hook is
  dropping a script and a rule mount.

## Repository layout

| Directory | Purpose |
|---|---|
| `claude-hooks/` | The hooks runtime: `hook-wrapper.sh` → `dispatcher.sh` → `unified/` (engine + rules) → `scripts/` (business hooks + libs) |
| `bootstrap/` | `bootstrap.sh` / `doctor.sh` / `rollback.sh` / `registry-patch.js` + declarative registration manifest |
| `adapters/` | Small, single-purpose adapters for specific external systems (kept intentionally non-generic) |
| `autopilots/` | Patrol scripts + shared Python helpers; scan targets configured via `configs/` |
| `launch/` | `toolchain-start.sh` + `systemd/toolchain-start-all.service` |
| `toolchain/` | Toolchain daily static checker |
| `review-prompts/` | Prompt builders + templates for review patrols |
| `scripts/` | Repo working-branch reconciliation helper |
| `docs/` | Hooks implementation guide, usage rules, migration notes; `docs/archive/` for historical snapshots |
| `tests/` | Shell suites + rule validator |

## Quick start

```bash
# 1. Clone to a stable location
gh repo clone tadki/dev-forge ~/tools/dev-forge

# 2. One-time install: backs up the current hooks section,
#    renders the 9 hook-point registrations, verifies idempotency
bash bootstrap/bootstrap.sh

# 3. Health check (repeatable)
bash bootstrap/doctor.sh

# 4. Roll back if needed (restores the registration backup)
bash bootstrap/rollback.sh
```

For a workstation setup with systemd, also write the environment file:

```bash
bash bootstrap/bootstrap.sh --write-toolchain-env --target-repo-root /path/to/your/repo
cp launch/systemd/toolchain-start-all.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now toolchain-start-all
```

Cutover / rollback runbook: [`docs/dev-forge-cutover.md`](docs/dev-forge-cutover.md).

## How the hooks engine works

```
~/.claude/settings.json   ── 9 hook points (absolute path into this checkout)
        │
        ▼
claude-hooks/hook-wrapper.sh       audit log + forward
        ▼
claude-hooks/dispatcher.sh         route by alias (unknown alias → pass through)
        ▼
claude-hooks/unified/unified-hook.sh
        ▼
claude-hooks/unified/engine.js     evaluates rules-v2.json + rules.d/*.json
        │                          mounts scripts/*.sh via run_script
        ▼
hookSpecificOutput (deny / context / modify) → Claude Code
```

- Engine failures are fail-open: original stdin passes through with exit 0, plus
  an audit line in the fire log.
- One-shot suppression state lives in `unified/state/` (gitignored) and is
  scoped per issue/run so multi-agent sessions don't suppress each other.

## Tests

```bash
bash tests/run_all.sh                     # aggregate runner
node --test tests/validator.test.mjs      # rules validator
python3 -m pytest tests/autopilots/ -q    # autopilot suites
```

## Contributing

- Work on branches and open PRs against `main` (merge commits only; squash is
  disabled).
- Hooks rules live in two non-overlapping lanes: `rules-v2.json` (engine-level)
  and `rules.d/runscript-mounts.json` (script mounts). See
  [docs/hooks-implementation-guide.md](docs/hooks-implementation-guide.md).
- `adapters/` tools are bound to specific external systems on purpose and are
  exempt from generalization.

## License

MIT
