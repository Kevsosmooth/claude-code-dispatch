# Instructions for AI agents (Claude Code or any other assistant)

Read this file before installing, configuring, or explaining this repository. It is written so an agent can follow it without guessing.

## 1. What this repository is
It is a Claude Code add-on with four parts:

- **`agents/`**: six subagent definitions, each pinning `model` and `effort` in its frontmatter.
- **`skills/`**: two skills.
  - `choosing-subagent-models`: how to pick a model and effort for every delegation.
  - `orchestrating`: how a parent session plans and verifies while workers write code. Includes `work-order.md`, the brief template.
- **`hooks/`**: five bash hooks that enforce those rules at runtime. They are listed in `hooks/hooks.json`, which uses `${CLAUDE_PLUGIN_ROOT}`.
- **`tools/replay-benchmark.py`**: an offline scorer for alternative routers.

It changes how subagents are launched and, in orchestrator sessions, blocks the parent from editing code. Tell the user that before installing.

## 2. Preconditions (check them; do not assume)
```bash
command -v jq && command -v bash && command -v curl   # jq is required; curl only for the usage snapshot
claude --version                                      # Claude Code must be installed
ls ~/.claude/settings.json 2>/dev/null                # existing settings are preserved and backed up
```
If `jq` is missing, ask the user to install it (`brew install jq`, `apt install jq`). Do not work around it.

## 3. Choose ONE install method
Installing both ways makes every hook run twice. First check for an existing install:
```bash
grep -q '/dispatch/hooks/' ~/.claude/settings.json 2>/dev/null && echo "script install present"
ls ~/.claude/plugins 2>/dev/null | grep -i dispatch && echo "plugin install may be present"
```

### Method A: plugin (preferred)
Slash commands are typed by the user, not run by you through a shell. Ask the user to type these two lines into Claude Code:
```
/plugin marketplace add Kevsosmooth/claude-code-dispatch
/plugin install claude-code-dispatch@claude-code-dispatch
```
Plugin agents and skills are namespaced: `claude-code-dispatch:builder`, `claude-code-dispatch:choosing-subagent-models`. The hooks strip the prefix, so either form routes correctly.

### Method B: install script
This edits `~/.claude/settings.json`. Get the user's approval, then run:
```bash
git clone https://github.com/Kevsosmooth/claude-code-dispatch.git
cd claude-code-dispatch
./tests/run.sh             # must end with "failed: 0"
./install.sh --dry-run     # show the user the hook entries it will add
./install.sh               # writes a settings.json.bak.<timestamp> first
```

What `install.sh` does:
- Copies the hooks to `~/.claude/dispatch/hooks/`, the agents to `~/.claude/agents/`, and the skills to `~/.claude/skills/`.
- Appends hook entries to `settings.json`. It first removes any entries whose command contains `/dispatch/hooks/`, so re-running it is safe.
- Never overwrites a different existing agent or skill file unless given `--force`. It prints `SKIP` instead. Report any SKIP lines to the user rather than forcing.
- Honors `CLAUDE_CONFIG_DIR` if set.

## 4. Restart, then verify
Hooks, agents, and skills load at session start. Tell the user to restart Claude Code (or start a new session). Then verify each item, and report what you observed rather than assuming:

1. `/hooks` (the user runs it) shows five commands:
   - `usage-snapshot.sh` (SessionStart)
   - `direct-mode.sh` (UserPromptSubmit)
   - `dispatch-gate.sh` (PreToolUse `Agent`)
   - `orchestrator-gate.sh` (PreToolUse `Edit|Write|MultiEdit|NotebookEdit|Bash`)
   - `orchestrator-tripwire.sh` (PostToolUse `Bash`)
2. `/agents` shows `builder`, `builder-high`, `builder-deep`, `reviewer`, `scout`, `researcher`.
3. Dispatch a harmless scout, e.g. "count the markdown files in this directory". A system message like the following must appear:
   `Subagent launch: model haiku | effort low | type scout | plan: ... | job: ...`
4. Run `tail -1 ~/.claude/dispatch-logs/agent-dispatch.jsonl`; it prints that launch as JSON.
5. Run `cat ~/.claude/dispatch-logs/usage-latest.json`. `state` is GREEN, AMBER, RED, or UNKNOWN. UNKNOWN is normal on macOS and when the snapshot is disabled.

If step 3 shows no message, the hooks did not load. Check that the user restarted, that `jq` is on the PATH Claude Code sees, and that the scripts are executable (`chmod +x`).

## 5. How to behave once installed
- **Every delegation picks a model and an effort on purpose.** Follow `skills/choosing-subagent-models/SKILL.md`, and announce the job, tier, effort, and reason in the same message as the dispatch.
- **Hook responses are decisions, not errors to route around.**
  - `permissionDecision: "deny"`: do what the reason says. Usually that means writing a work order and dispatching a builder.
  - `permissionDecision: "ask"`: the user decides.
  - A rewritten `model`: accept it.

  Never rephrase, split, encode, or alias a command to get past a hook. That is hook evasion.
- **In an orchestrator session** (the session model matches `DISPATCH_ORCH_MODELS`, default `fable`), follow `skills/orchestrating/SKILL.md`:
  - The parent writes plans and work orders only.
  - Builders write code.
  - The parent verifies centrally.
  - The gate lifts for one turn only when the user's own prompt says "do it yourself", "don't use agents", or "go direct for this one". Never create the `orch-off` marker yourself unless the user said so this turn.
- **Workers** report WHAT CHANGED, PROOF (verbatim command output), and CONCERNS. Treat PROOF as evidence and re-run the checks yourself before telling the user the work is done.

## 6. Configuration
Every setting is an optional environment variable in the `env` block of `~/.claude/settings.json`. The table is in `README.md` under "Configure". The ones users change most:

| Variable | Effect |
|---|---|
| `DISPATCH_CODE_MODEL` | Which model writes code (default `opus`) |
| `DISPATCH_ORCH_MODELS` | Which parent models are gated (default `fable`; empty turns the orchestrator gate off) |
| `DISPATCH_ASK_MODELS` | Which worker models need approval (default `fable`) |
| `DISPATCH_USAGE_SNAPSHOT=0` | Stops the one HTTPS call to Anthropic's usage endpoint |

Edit `settings.json` only with the user's approval, and preserve every existing key.

## 7. Uninstall
- **Plugin:** the user types `/plugin uninstall claude-code-dispatch@claude-code-dispatch`.
- **Script:** from the clone, run `./install.sh --uninstall`. It removes only its own hook entries and any files identical to this repository's copies, and it reports anything it kept.

## 8. Privacy and safety facts (state these accurately if asked)
- **Local files only.** The hooks read hook input JSON and the tail of the session transcript (to learn the session model), and they write only under `~/.claude/dispatch-logs/`.
- **One network call, and only one.** `usage-snapshot.sh`:
  - reads the OAuth access token from `~/.claude/.credentials.json`
  - sends it in a header to `https://api.anthropic.com/api/oauth/usage` (the endpoint behind `/usage`; undocumented, so it may change)
  - stores percentages only

  The token is never printed, logged, or written.
- **What the log contains.** `agent-dispatch.jsonl` holds your subagent descriptions. It stays local. `tools/replay-benchmark.py export` scrubs emails, phone numbers, street addresses, possessive names, and key-like strings before rows go to any external classifier. Review the export anyway.
