# claude-code-dispatch

Model routing and orchestration rules for Claude Code, enforced by hooks instead of hope.

Every time Claude Code launches a subagent, it picks a model and an effort level, even when nobody chose one: a subagent with no `model` inherits the parent session's model, which is often the most expensive one available. This package turns that into a deliberate decision:

- **Six pinned agents** (`scout`, `researcher`, `builder`, `builder-high`, `builder-deep`, `reviewer`). Each carries its own model and effort.
- **A routing skill** (`choosing-subagent-models`). A 5-factor score maps each task to a tier and an effort, with overrides for high-stakes work and an escalation ladder for retries.
- **An orchestration skill** (`orchestrating`), plus a work-order template, for the pattern where an expensive parent model plans and verifies while cheaper workers write the code.
- **Hooks that enforce both skills.** Details in the next section.
- **A replay benchmark** that scores any router (an LLM classifier, a keyword rule, a paid service) against your own dispatch history before you trust it.

> For AI agents: installation and verification steps written for you are in [INSTALL-FOR-AI.md](INSTALL-FOR-AI.md).

## What the hooks do

| Hook | Event | Effect |
|---|---|---|
| `dispatch-gate.sh` | PreToolUse `Agent` | Every launch prints `Subagent launch: model X \| effort Y \| type Z \| plan: 5h N% · wk M% [STATE] \| job: ...`. It also:<br>- rewrites a model-less dispatch from the parent to `DISPATCH_CODE_MODEL`<br>- keeps builders on the code tier<br>- asks before premium workers (`DISPATCH_ASK_MODELS`)<br>- asks before high-stakes jobs (auth, payments, deletion, sends) run on sonnet or haiku<br>- denies `fork` from an orchestrator session<br>- logs every launch to `agent-dispatch.jsonl` |
| `orchestrator-gate.sh` | PreToolUse `Edit\|Write\|MultiEdit\|NotebookEdit\|Bash` | Only in sessions whose model matches `DISPATCH_ORCH_MODELS` (default `fable`): denies code edits by the parent, so the parent must brief a worker. Plans (`*.md`), `~/.claude/**`, and the scratchpad stay writable. Workers are exempt. |
| `orchestrator-tripwire.sh` | PostToolUse `Bash` | Lists any code file a parent Bash command changed anyway (e.g. through `node -e` or a script) and logs it. It never blocks. |
| `direct-mode.sh` | UserPromptSubmit | "do it yourself", "don't use agents", or "go direct for this one" in your prompt turns the orchestrator gate off for that turn only. |
| `usage-snapshot.sh` | SessionStart (async) | Optional. Caches the plan-usage percentages that `/usage` shows, so the dispatch gate can print them and warn when the plan is RED. Makes one HTTPS call to Anthropic; the token is never logged. Opt out with `DISPATCH_USAGE_SNAPSHOT=0`. |

With default settings, if you never run a `fable` session, the orchestrator gate and tripwire do nothing. You get only the routing gate, the pinned agents, and the skills.

## Install

Requirements: Claude Code, `bash`, `jq`. The usage snapshot also needs `curl`.

Pick ONE method. Using both runs every hook twice.

### Option A: plugin (recommended)
Inside Claude Code:
```
/plugin marketplace add Kevsosmooth/claude-code-dispatch
/plugin install claude-code-dispatch@claude-code-dispatch
```
Restart Claude Code. The plugin namespaces the agents and skills: `claude-code-dispatch:builder`, `claude-code-dispatch:orchestrating`, and so on. The hooks accept both namespaced and plain names.

### Option B: install script
```bash
git clone https://github.com/Kevsosmooth/claude-code-dispatch.git
cd claude-code-dispatch
./tests/run.sh            # optional: self-test, runs in a throwaway HOME
./install.sh --dry-run    # see what would change
./install.sh              # copy files and merge hooks into ~/.claude/settings.json (backs it up first)
```
Restart Claude Code. The agents install as plain names (`builder`, `scout`, ...). Re-running is safe; it replaces its own entries. `./install.sh --uninstall` removes exactly what it added.

### Verify
1. `/hooks` lists the five hook scripts.
2. `/agents` lists the six agents.
3. Ask Claude to "use a scout to count the markdown files here". A `Subagent launch: model haiku | effort low | type scout ...` line appears.
4. The log gets a line: `tail -1 ~/.claude/dispatch-logs/agent-dispatch.jsonl`.

## Configure

All settings are optional environment variables. Set them in the `env` block of `~/.claude/settings.json`:

```json
{ "env": { "DISPATCH_CODE_MODEL": "opus", "DISPATCH_ORCH_MODELS": "" } }
```

| Variable | Default | Meaning |
|---|---|---|
| `DISPATCH_CODE_MODEL` | `opus` | Model forced onto builders and onto model-less dispatches from the parent |
| `DISPATCH_ASK_MODELS` | `fable` | Regex: explicit worker dispatches on these models need your approval (empty = never ask) |
| `DISPATCH_ORCH_MODELS` | `fable` | Regex: parent sessions on these models may not write code (empty = orchestrator gate off) |
| `DISPATCH_ORCH_ALLOW` | (none) | Colon-separated globs the orchestrator parent may still write, e.g. `*/generated/*:*.lock` |
| `DISPATCH_STAKES_RE` | auth, payment, delete, migration, sends... | Regex marking a dispatch as high stakes |
| `DISPATCH_CODE_EXT` | `ts tsx js py go rs ...` | Space-separated extensions the orchestrator gate treats as code |
| `DISPATCH_LOG_DIR` | `~/.claude/dispatch-logs` | Logs, state markers, usage snapshot |
| `DISPATCH_USAGE_SNAPSHOT` | `1` | `0` disables the usage call |

To turn off the orchestrator gate everywhere: `touch ~/.claude/orchestrator.off`.

## The routing rules in one screen

- **Code is written by one tier** (opus by default) through pinned builders:

  | Builder | Effort | Use for |
  |---|---|---|
  | `builder` | medium | the default |
  | `builder-high` | high | cross-file invariants |
  | `builder-deep` | xhigh | hard work and every escalation |

- **Read-only work goes cheaper:** `scout` (haiku @ low) for recon, `researcher` (sonnet @ medium) for web research.
- **Scoring:** rate blast radius, ambiguity, verification cost, context breadth, and novelty 0-2 each.

  | Total | Worker |
  |---|---|
  | 0-4 | `builder` |
  | 5-6 | `builder-high` |
  | 7+, or any Ambiguity or Novelty of 2 | `builder-deep` |

- **Overrides:** the user's named model wins. Stakes work (security, auth, payments, deletion, migrations, outbound sends) never goes below the code tier and gets a `reviewer` pass. A failed builder escalates to `builder-deep` with the failure attached; a second failure goes back to the human.
- **Raise effort before tier. Stakes never downshift,** even when usage is RED; the work waits for the reset.
- **Announce, don't ask:** every dispatch states job, tier, effort, and why. Only premium workers wait for a yes.

Full rules: [skills/choosing-subagent-models/SKILL.md](skills/choosing-subagent-models/SKILL.md) and [skills/orchestrating/SKILL.md](skills/orchestrating/SKILL.md).

## Benchmark a router against your history

Before adding an LLM router or a routing service, check whether it would have agreed with the picks you already make:

```bash
tools/replay-benchmark.py score --baseline                      # built-in keyword baseline
tools/replay-benchmark.py score --router "python3 my_router.py" # any command: JSON lines in, JSON lines out
tools/replay-benchmark.py export > rows.jsonl                   # scrubbed rows for an external batch classifier
tools/replay-benchmark.py score --predictions preds.jsonl
```

Always compare against the dumbest router, "always pick the code tier". On the author's 300 most recent dispatches:

| Router | Tier agreement |
|---|---|
| Always opus | 84% |
| An LLM batch classifier | 84% (99% on its 178 confident picks) |
| The keyword baseline | 89% |

Effort agreement was 39-51% for all three. The classifier added nothing over the rules. Your history will differ; that is the point of running it.

## Portability

- **Linux:** tested (`tests/run.sh`, 67 checks).
- **macOS:** written for BSD tools (`stat -f`, no `-regextype`, no `realpath -m`), but not yet tested there.
  - The usage snapshot reports UNKNOWN on macOS, because Claude Code keeps its token in the Keychain.
  - The routing still works.
- **Windows:** use WSL.

## Uninstall
- **Plugin:** `/plugin uninstall claude-code-dispatch@claude-code-dispatch`
- **Script:** `./install.sh --uninstall`

Logs in `~/.claude/dispatch-logs/` are left for you to delete.

## License
MIT
