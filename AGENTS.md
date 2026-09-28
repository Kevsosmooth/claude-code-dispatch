# AGENTS.md

This repository is a Claude Code add-on: pinned subagents, two routing skills, and hooks that enforce them.

- Installing, verifying, or explaining it: follow [INSTALL-FOR-AI.md](INSTALL-FOR-AI.md) step by step.
- Human overview and configuration: [README.md](README.md).
- Changing the hooks: keep them portable bash (GNU and BSD tools; no `-regextype`, `tac`, `realpath -m`, or `flock`); `jq` is the only dependency. Run `tests/run.sh` before and after; it must end with `failed: 0`. Add a test for every behavior you change.
- Never add a code path that prints, logs, or stores the OAuth token read by `hooks/usage-snapshot.sh`.
