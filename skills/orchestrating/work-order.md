# Work order: <short title>

You are executing a work order from the orchestrator. Follow it exactly. If it is wrong, impossible, or fights the codebase, stop and report why instead of improvising. Do not spawn subagents; this order is sized for one worker.

## Worker settings
- Builder: `builder` (opus @ medium), `builder-high` (opus @ high), or `builder-deep` (opus @ xhigh)
- Deciding factor: <why this effort, in one line>

## Goal
One paragraph, in user terms: what exists when this is done.
Done when:
- [ ] <observable outcome 1>
- [ ] <observable outcome 2>

## Why / context
What the feature is for and where it sits. Include everything the orchestrator already learned, so the worker does not rediscover it:
- key facts
- decisions already made
- dead ends already ruled out

## Files
- Touch: `path`: what changes
- Create: `path`: what it is
- DO NOT touch: `path`: why

## Patterns to copy
- `path:line`: do it like this (naming, error handling, data access, component shape)
- Reuse, never re-implement: `path` -> `symbol`

## Steps
1. <numbered, each one verifiable>
2. ...

## Hard constraints
- The project rules that apply here, from CLAUDE.md, AGENTS.md, or the design doc.
- Root-cause fixes only: no suppressed errors, no loosened types, no commented-out code, no stray TODOs.
- Never read, print, copy, or modify `.env`, credential, key, token, cookie, or secret files.

## Techniques and gotchas
- The non-obvious part: library quirks, the race to avoid, the flaky test and why, the API shape, the migration order.

## Verification: run these and paste the output verbatim
- `<typecheck command>`
- `<test command> <pattern>`
- For UI:
  - Screenshot every surface you added or changed, in every state it has, at width 390 AND 1280, then look at each image before reporting.
  - Name the shared component you copied.

## Report back (always, in this order)
1. WHAT CHANGED: each file, plus one line on what and why.
2. PROOF: verbatim verification output (the pass/fail counts line, the build result). "Should work" is a failure to verify.
3. CONCERNS: anything the orchestrator should double-check, or "None".
