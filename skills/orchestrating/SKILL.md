---
name: orchestrating
description: Use in an orchestrator session (a session whose model is listed in DISPATCH_ORCH_MODELS, default fable) for any task that changes code or config or ships something, and the moment the ORCHESTRATOR GATE denies an Edit, Write, or Bash write. The parent explores, plans, writes the work order, dispatches builders, scout, and reviewer, and verifies the result; workers write every line of code.
---

# Orchestrating: the parent plans, workers build

## Why this exists
The premium model is the scarce budget. A session that reads everything and types the code burns it; a session that plans, briefs, and checks stretches it. In orchestrator sessions, hooks enforce the split so it does not depend on discipline:

- **`orchestrator-gate.sh`** (PreToolUse on Edit, Write, MultiEdit, NotebookEdit, and Bash) denies every code edit from the parent, one-liners included.
  - Still allowed: `*.md` and `*.txt` plans, `~/.claude/**`, the session scratchpad, project `.claude/`, and any glob in `DISPATCH_ORCH_ALLOW`. Workers are exempt.
  - For Bash, the gate denies only evidence of a code-file write:
    - a redirect, or `cp`, `mv`, `tee`, `sed -i`, or `perl -i` aimed at a code file
    - `git apply`, `git am`, or `patch`
    - a history restore onto paths
    - `find` or `fd` with `-delete` or `-exec`

    Everything else runs.
- **`orchestrator-tripwire.sh`** (PostToolUse on Bash) lists any code file that changed during a parent Bash command, shows the list, and logs it to `orch-violations.jsonl`. If you see it and you caused it, revert and brief a worker.
- **`dispatch-gate.sh`** (PreToolUse on Agent) makes routing enforceable:
  - routes a model-less dispatch to the code tier
  - denies `fork`, because a fork runs on the parent's model
  - turns an explicit premium worker into a permission prompt

Your job is the part hooks cannot do: the brief. Thin briefs are the main reason workers return junk.

## The loop
1. **Understand.** Read the 2-5 files that matter yourself (Read is never gated). For anything broader, dispatch `scout` and read its summary. Pass workers paths, not pasted file contents; they will read the file anyway.
2. **Shape the work.**
   - If the ask is ambiguous, clarify with the user first.
   - For a multi-task build, write a plan, then dispatch one work order per task and verify each before the next.
   - For one well-defined change, write one work order.
3. **Write the work order.** Copy `work-order.md` (in this folder) and fill every section. The sections that decide success:
   - patterns to copy, with `path:line`
   - what NOT to touch
   - the exact verification commands
   - the proof format
4. **Dispatch the builder.** Code runs on the code tier (`DISPATCH_CODE_MODEL`, default opus). Name the deciding factor when you announce. Pick effort per the `choosing-subagent-models` skill.

   | Worker | When |
   |---|---|
   | `builder` (medium) | a specified order that follows an existing pattern |
   | `builder-high` (high) | cross-file orders with real invariants |
   | `builder-deep` (xhigh) | hard orders, and every escalation |
   | `reviewer` (xhigh) | before anything touching auth, security, payments, or data deletion ships |
   | `scout` (haiku) | recon |
5. **Parallelize.** Send independent orders in one message. Orders that touch the same files run one after another, or in separate worktrees (`isolation: "worktree"`).
6. **Verify centrally.** Run the tests, typecheck, and build yourself, and read `git diff`. The worker's PROOF section is evidence, not the verdict.

   UI work passes two gates before commit:
   - **Function gate.** Click through the real flow in a browser: requests fire, data lands, states transition.
   - **Design gate.**
     - Screenshot every new or changed surface in every state it has (dialogs open, conditional fields revealed, success and error panels) at phone width (~390px) and desktop (~1280px).
     - Check each shot against the project's design rules. Every action must be reachable at phone width.
     - A hand-rolled native control used where a shared styled component exists is a defect.
     - Read the copy: raw ids or internal jargon in user-facing text are defects.

   Passing one gate says nothing about the other.
7. **Repair with evidence; never loop blindly.** After one failed verification, escalate `builder` to `builder-deep` with the failure attached. After two failed rounds, stop and go back to the user.
8. **Integrate and ship from here.** Commits, merges, restarts, and deploys happen in the orchestrator, never inside a worker. Follow the project's deploy rules.

## Rules
- **Effort is the user's dial.** No hook or model can change `/effort`. When a task sits at the top of the difficulty scale (novel architecture, an unknown root cause across systems, security design), say in one line that it is worth `/effort xhigh`, then keep working at the current setting.
- **Say when to step effort down, and back up.**
  - Suggest `/effort medium` once the plan is approved, the work orders are written, and only dispatch and checks remain.
  - Never suggest it while a root cause is unknown, a design choice is undecided, or security, auth, payment, or data-deletion work is open.
  - Suggest going back up when a worker fails twice or the task changes shape.
- **The orchestrator writes** plans, specs, work orders, `~/.claude` config, and notes. It never writes code. A denied edit is a cue to brief a worker, not to reach for `sed`.
- **Workers write** code, tests, config, HTML deliverables, and migrations, and never fan out: one order, one worker, one verifiable outcome.
- **Batch small edits.** Split anything you could not verify in one sitting. Several tiny same-shape edits across files go into ONE work order for one worker, not one dispatch each, and never into your own hands.
- **Direct mode.** If the user says "don't use agents", "go direct for this one", or "do it yourself", `direct-mode.sh` disables the gate for that one turn and re-arms it on the next prompt. To turn the gate off for every session: `touch ~/.claude/orchestrator.off`.
- **Workflow scripts.** Every `agent()` call carries `model:` and `effort:`. An unrouted workflow agent runs on the session model.

## Quick dispatch shape
```
Agent(subagent_type: "builder", description: "<5 words>", prompt: <the filled work order>)
```
With the plugin install, the type is `claude-code-dispatch:builder`. Read the returned WHAT CHANGED, PROOF, and CONCERNS, then do step 6 yourself.
