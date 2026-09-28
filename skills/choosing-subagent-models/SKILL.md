---
name: choosing-subagent-models
description: Use when delegating work to another agent (dispatching subagents via the Agent tool, writing Workflow scripts, launching background tasks) and a model tier (haiku/sonnet/opus/premium) or the worker's effort level must be picked; when a delegated task's output failed verification and a retry is needed; or when deciding whether current plan usage allows premium-tier work.
---

# Choosing Subagent Models

## Overview
Every delegation picks a model AND an effort level, even by omission. Omitting them inherits the parent session's settings, which can be the most expensive possible worker: a premium-model session at `/effort max` makes every ad-hoc subagent premium at max.

The loop: score the task, map it to tier and effort, check the usage governor, announce, dispatch, verify.

`model` is its own parameter on the Agent tool (`model: "haiku" | "sonnet" | "opus" | ...`). It is NOT `subagent_type`, which selects an agent definition such as scout, builder, or reviewer. Workflow `agent()` calls take `opts.model` and `opts.effort`. An explicit `model` parameter beats whatever an agent definition pins.

If this skill came from the `claude-code-dispatch` plugin, the agents are namespaced: `claude-code-dispatch:builder`, `claude-code-dispatch:scout`, and so on. If it was installed with `install.sh`, they are plain `builder`, `scout`, and so on. The hooks accept both.

## Standing rule: one tier writes the code
Every worker that edits code, config, tests, or HTML deliverables runs on the code tier (`DISPATCH_CODE_MODEL`, default `opus`) through a pinned builder:

| Worker | Pin | Use for |
|---|---|---|
| `builder` | opus @ medium | the default |
| `builder-high` | opus @ high | cross-file orders with real invariants |
| `builder-deep` | opus @ xhigh | hard orders and every escalation |

Cheaper tiers do read-only work only: `scout` (haiku @ low) for recon and `researcher` (sonnet @ medium) for web research. The premium tier, if you have one (`DISPATCH_ASK_MODELS`, default `fable`), plans, briefs, verifies, and ships; it is never a default worker.

The rubric below decides two things only: which read-only tier to use, and which effort (medium, high, or xhigh) the builder gets. Name the deciding factor when you announce the dispatch.

Why a single code tier: a cheaper model that writes code "well enough" costs a verification round, a repair round, and often an escalation anyway. Pricing the job once at the code tier is cheaper than paying for the failure path. Change `DISPATCH_CODE_MODEL` if your economics differ.

## Tiers (aliases track the latest release of each family)
| Tier | Rough cost weight | Notes |
|---|---|---|
| haiku | 1x | supports no effort levels; read-only work (`scout`) |
| sonnet | ~2x | low to max effort; read-only work (`researcher`) or an explicit user request |
| opus | ~4x | the default code-writing tier; low to max effort |
| premium (e.g. fable) | ~10x | scarce; orchestrate from it, delegate volume out of it |

Check current prices before relying on the weights; they drift with every release.

## The algorithm
**Overrides first. Skip scoring when one applies:**
1. **The user named a model.** Their word wins.
2. **High-stakes work.** Security, auth, payments, compliance, data deletion, production data migration, or outbound messaging (email or SMS sends, go-live flips of anything that sends) needs at least the code tier. The builder pins already satisfy this. A stakes job also gets `reviewer` before it ships.
   The dispatch gate catches an explicit sonnet or haiku dispatch whose description, or the first 400 characters of its prompt, matches `DISPATCH_STAKES_RE`, and turns it into a permission prompt. Read-only agents (scout, researcher, reviewer, Explore, Plan) are exempt.
3. **Retry after failed verification.** Escalate `builder` or `builder-high` to `builder-deep`, with the failure attached. A second failure goes back to the orchestrator and the user, not into another dispatch. Premium workers run only with the user's explicit approval. Never rerun the same agent at the same effort.

**Otherwise, score five factors, 0 to 2 each:**
| Factor | 0 | 1 | 2 |
|---|---|---|---|
| Blast radius | throwaway / read-only | repo code behind review | prod, money, user data, outbound comms |
| Ambiguity | fully specified steps | some judgment mid-task | unknown root cause / open design |
| Verification cost | grep/count/compile proves it | tests + reading the diff | judgment, security, prose: expensive to check |
| Context breadth | 3 files or fewer | one subsystem | cross-repo / architecture-wide |
| Novelty | existing pattern to copy | adaptation of a pattern | new pattern / LLM behavior / prompt design |

**Map the total to a worker:**

| Work | Score | Worker |
|---|---|---|
| Code | 0-4 | `builder` @ medium (the default) |
| Code | 5-6, with no Ambiguity or Novelty of 2 | `builder-high` @ high |
| Code | 7+, or any Ambiguity or Novelty of 2 | `builder-deep` @ xhigh |
| Read-only | 0-2 | `scout` (haiku) |
| Read-only | 3+ | `researcher` (sonnet), or an explicit sonnet general-purpose |

A premium worker is never a default. Two legitimate cases: a peer review of high-stakes work the orchestrator produced itself and cannot check, or a step past a failed `builder-deep`. Either way it runs only with the user's explicit approval, and the gate turns the dispatch into a permission prompt. Justify it out loud every time.

For hard but fully specified work, turn up effort, not tier: `builder-deep` at xhigh.

## Effort: the second dial (try +1 effort before +1 tier)
| Effort | Use for |
|---|---|
| low | mechanical work: scans, inventories, bulk pattern edits |
| medium | the worker default (`builder`) |
| high | cross-file orders with real invariants (`builder-high`); a good starting effort for the main session |
| xhigh | adversarial review, security reading, the hardest specified coding (`builder-deep`, `reviewer`); use it only where it measurably helps |
| max | rare: correctness far outweighs cost, and latency does not matter |

When output falls short, raise effort within the tier first. Switch tiers only when the gap is ambiguity or stakes.

Haiku ignores effort. Ad-hoc dispatches inherit the session's effort, so at `/effort max` an unpinned worker burns max thinking. Pinned agents avoid that.

## Usage governor: check before premium dispatches and any fan-out
When the optional usage snapshot is on (the SessionStart hook `usage-snapshot.sh`), the live plan percentages sit in `$DISPATCH_LOG_DIR/usage-latest.json` (default `~/.claude/dispatch-logs/`). The dispatch gate prints them on every launch, e.g. `plan: 5h 42% · wk 71% [AMBER]`.

| State | Trigger | Adjustment |
|---|---|---|
| GREEN | 5h below 60% and week below 70% | route purely by the algorithm |
| AMBER | 5h 60-84% or week 70-89% | batch fan-outs; defer nice-to-haves; do not downshift code work |
| RED | 5h 85% or more, or week 90% or more | tell the user; queue non-urgent code work for the next window; never silently move code to a cheaper tier |
| UNKNOWN | no snapshot, or it failed | route normally and mention it once |

**Stakes never downshift.** Security, auth, and payments stay at the code tier or above in every state. If the budget cannot carry the work, it waits for the reset.

## Pinned agents: the only per-worker effort control
Agent definitions carry both `model:` and `effort:` in their frontmatter. Prefer them for recurring roles, and dispatch by `subagent_type`.

| subagent_type | pinned | role |
|---|---|---|
| scout | haiku @ low | read-only recon: inventories, log scans, "where / what / how many" |
| researcher | sonnet @ medium | read-only web research, with sources |
| builder | opus @ medium | implements a fully specified work order, with proof; the default code writer |
| builder-high | opus @ high | cross-file orders with real invariants |
| builder-deep | opus @ xhigh | hard but specified work, and every escalation after a failed builder run |
| reviewer | opus @ xhigh | adversarial review before anything ships |

Recent Claude Code versions run the built-in `Explore` agent on the session model, not on haiku. For cost-controlled recon, use `scout` or pass `model:` explicitly.

Agent files added or edited on disk load at session start, so restart the session before dispatching a new definition.

## Rules
- **Announce, don't ask.** In the same message as the dispatch, state in one or two plain sentences the job, the tier and why, and the effort it will run at. The user sees which model is running and can veto by interrupting. The announcement is mandatory; waiting is not. These still wait for the user's explicit yes:
  - premium-tier dispatches
  - anything destructive or outward-facing
- **Choose the tier on purpose, every time.** Set `model`, name a pinned agent, or say why inheriting is right. Inheriting silently is not a decision, and the dispatch gate flags it.
- **Escalate with the failure attached.** `builder` goes to `builder-deep`; a second failure goes back to the user. Never loop the same agent at the same effort.
- **Mind the verification asymmetry.** Output that is cheap to verify tolerates a cheaper model. Output that is expensive to verify justifies the better model up front.
- **Fan-outs multiply cost.** A 20-agent sweep at the code tier is 20 times the mistake. Read-only fan-outs default to scout or researcher, with a code-tier synthesis step if needed. Batch code work into fewer, larger work orders.
- **Watch local resources, not agent count.** Parallel subagents are API-bound. Before launching agents that will start heavy local processes (builds, dev servers), check free memory and cap how many run at once.
- **Always verify afterward.** The orchestrator checks every returned result (runs the tests, reads the diff, compiles), even trivial haiku jobs. Never report unverified agent output as done.

## The orchestration loop
1. **Inspect first.** Read the actual files, logs, and code yourself. Don't outsource understanding.
2. **Write the work order.** Number the steps and include file paths, hard constraints, and what the agent must NOT touch. Template: the `orchestrating` skill's `work-order.md`.
3. **Route and dispatch.** Score, pick tier and effort, check the governor, then announce and dispatch.
4. **Demand proof in the brief.** The agent must run its verification and report the real output; its summary alone doesn't count.
5. **Verify and integrate yourself.** Review the changes and run the checks. Restarts and deploys happen in the orchestrator, never inside the agent.

## Session-level policy (a bigger lever than any subagent choice)
In typical usage, the main session burns more than all its subagents combined, because every turn re-sends the whole context.

- Keep the parent's context lean.
- Let long sessions compact instead of carrying a 1M window.
- Start the parent at `high` effort and raise it only for hard design or debugging.

## When NOT to apply
- The user explicitly named a model. Their word wins.
- A single quick lookup you can do yourself needs no agent at all.

## Common mistakes
| Mistake | Fix |
|---|---|
| Putting a model name in `subagent_type` | `subagent_type` picks the agent definition; `model` picks the tier |
| Delegating to outsource thinking | Answer from your own head first. Delegate for parallelism, context isolation, or a cheaper tier, never because asking feels safer |
| Sonnet or haiku for anything that edits code | Code runs on the code tier; scout and researcher are for read-only work |
| The same tier for everything "to be safe" | Score it; the rubric prices each task on its own |
| Haiku for an investigation with an unknown root cause | An unknown cause means Ambiguity 2, so `builder-deep` @ xhigh |
| Explore "because it's the cheap searcher" | Explore may inherit the session model; `scout` is the cheap one |
| An ad-hoc dispatch while the session runs premium or `/effort max` | Use a pinned agent or an explicit `model:`. The gate rewrites a model-less dispatch from the parent session to the code tier; inside a worker it only warns |
| `subagent_type: fork` from an orchestrator session | The gate denies it, because a fork runs on the parent's model. Re-dispatch as general-purpose with `model: "opus"` and paste the context into the brief |
| The orchestrator implementing the work itself | The orchestrator gate denies code edits from the parent. Write the work order (skill `orchestrating`) and dispatch a builder |
| Downshifting security work in AMBER or RED | Stakes never downshift; the work waits for the reset |
| Dispatching without telling the user | Announce job, tier, effort, and why in the dispatch message |
