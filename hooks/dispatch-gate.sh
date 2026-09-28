#!/usr/bin/env bash
# PreToolUse on the Agent tool: every subagent launch gets a model on purpose.
#
# What it does, in order:
#   1. builder / builder-high / builder-deep with an explicit model other than
#      DISPATCH_CODE_MODEL are rewritten to DISPATCH_CODE_MODEL (updatedInput).
#   2. An explicit model matching DISPATCH_ASK_MODELS (default: fable) becomes a
#      permission prompt, so the user approves every premium worker.
#   3. From the parent session: a dispatch that names no model and is not a
#      pinned agent is rewritten to DISPATCH_CODE_MODEL instead of inheriting
#      the parent's (possibly most expensive) model. A `fork` from an
#      orchestrator session is denied, because a fork runs on the parent model.
#      Inside a worker: a model-less dispatch only gets a warning.
#   4. A job that looks high-stakes (DISPATCH_STAKES_RE on the description and
#      the first 400 characters of the prompt) and would run on sonnet, haiku,
#      or an inherited model becomes a permission prompt. Read-only agent types
#      are exempt.
#   5. If the optional usage snapshot says RED, the launch message says so.
#   6. Every launch is logged to $DISPATCH_LOG_DIR/agent-dispatch.jsonl and
#      announced as a system message: model, effort, type, plan state, job.
#
# Routing rubric: skill choosing-subagent-models. Tests: tests/run.sh.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty')
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
model=$(printf '%s' "$input" | jq -r '.tool_input.model // empty')
stype_raw=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // "general-purpose"')
stype=$(bare_agent_type "$stype_raw")
desc=$(printf '%s' "$input" | jq -r '.tool_input.description // "agent task"')

plan="plan: no snapshot"
state="UNKNOWN"
SNAP="$DISPATCH_LOG_DIR/usage-latest.json"
if [ -f "$SNAP" ]; then
  plan=$(jq -r '"plan: 5h \(.session_pct // "?")% · wk \(.weekly_pct // "?")% [\(.state // "UNKNOWN")]"' "$SNAP" 2>/dev/null) || plan="plan: unreadable"
  state=$(jq -r '.state // "UNKNOWN"' "$SNAP" 2>/dev/null)
fi

sessmodel=""
[ -z "$agent_id" ] && sessmodel=$(session_model "$tp")
orch_session=0
[ -z "$agent_id" ] && is_orch_session "$sessmodel" && orch_session=1

# Pinned agents carry their own model and effort in frontmatter (agents/*.md).
pin_model=""; pin_eff=""
case "$stype" in
  scout)        pin_model=haiku;  pin_eff=low ;;
  researcher)   pin_model=sonnet; pin_eff=medium ;;
  builder)      pin_model=opus;   pin_eff=medium ;;
  builder-high) pin_model=opus;   pin_eff=high ;;
  builder-deep) pin_model=opus;   pin_eff=xhigh ;;
  reviewer)     pin_model=opus;   pin_eff=xhigh ;;
esac

decision=allow
reason=""
updated=""
context=""
forced_why=""
warn=""

case "$stype" in builder|builder-high|builder-deep) is_builder=1 ;; *) is_builder=0 ;; esac

if [ "$is_builder" = 1 ] && [ -n "$model" ] && [ "$model" != "$DISPATCH_CODE_MODEL" ]; then
  updated=$(printf '%s' "$input" | jq -c --arg m "$DISPATCH_CODE_MODEL" '.tool_input + {model:$m}')
  requested=$model
  model=$DISPATCH_CODE_MODEL
  forced_why="builders run on $DISPATCH_CODE_MODEL"
  context="Dispatch gate: ${stype} runs on ${DISPATCH_CODE_MODEL}; the requested model ${requested} was overridden. Use scout (haiku) or researcher (sonnet) for read-only work."
elif [ -n "$DISPATCH_ASK_MODELS" ] && [ -n "$model" ] && printf '%s' "$model" | grep -qiE "$DISPATCH_ASK_MODELS"; then
  decision=ask
  reason="PREMIUM WORKER requested (model: ${model}). This spends the most expensive usage bucket, so the user must approve this dispatch. To avoid the prompt, pass model: \"${DISPATCH_CODE_MODEL}\" or use a pinned agent."
elif [ -z "$agent_id" ]; then
  if [ "$stype" = fork ]; then
    if [ "$orch_session" = 1 ]; then
      decision=deny
      reason="DISPATCH GATE: a fork runs on the parent's model (${sessmodel}). Re-dispatch as subagent_type general-purpose with model: \"${DISPATCH_CODE_MODEL}\" and paste the context the worker needs into the brief."
    fi
  elif [ -z "$model" ] && [ -z "$pin_model" ]; then
    updated=$(printf '%s' "$input" | jq -c --arg m "$DISPATCH_CODE_MODEL" '.tool_input + {model:$m}')
    model=$DISPATCH_CODE_MODEL
    forced_why="no model given"
    context="Dispatch gate: the dispatch named no model, so it was routed to ${DISPATCH_CODE_MODEL} instead of inheriting ${sessmodel:-the session model}. Use scout (haiku) or researcher (sonnet) for read-only work, or pass model: explicitly."
  fi
else
  [ -z "$model" ] && [ -z "$pin_model" ] && [ "$stype" != fork ] && \
    warn=" | WARN: inherits the worker's model and effort; pass model: or use a pinned agent"
fi

eff_model="${model:-${pin_model:-inherit}}"
eff_effort="${pin_eff:-session}"
if [ "$state" = RED ]; then
  case "$eff_model" in
    haiku|sonnet) : ;;
    *) warn="$warn | plan RED: tell the user before more premium dispatches; queue non-urgent code work for the next window" ;;
  esac
fi

if [ "$decision" = allow ]; then
  prompt=$(printf '%s' "$input" | jq -r '.tool_input.prompt // empty' | head -c 400)
  case "$stype" in
    scout|researcher|reviewer|Explore|Plan) : ;;  # read-only agent types cannot edit files
    *)
      case "$eff_model" in
        sonnet|haiku|inherit)
          if printf '%s\n%s' "$desc" "$prompt" | grep -qiE "$DISPATCH_STAKES_RE"; then
            hit=$(printf '%s\n%s' "$desc" "$prompt" | grep -oiE "$DISPATCH_STAKES_RE" | head -1)
            decision=ask
            reason="STAKES DISPATCH on ${eff_model}: the job looks like security, auth, payments, deletion, migration, or outbound messaging (matched: ${hit}). Rule: minimum ${DISPATCH_CODE_MODEL} (skill choosing-subagent-models). Approve to run it on ${eff_model} anyway, or re-dispatch with model: \"${DISPATCH_CODE_MODEL}\"."
          fi
          ;;
      esac
      ;;
  esac
fi

jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$sid" \
  --arg model "$eff_model" --arg type "$stype" --arg eff "$eff_effort" \
  --arg desc "$desc" --arg state "$state" --arg decision "$decision" \
  --arg forced "$([ -n "$updated" ] && echo yes || echo no)" \
  --arg inside "$([ -n "$agent_id" ] && echo yes || echo no)" \
  --arg sess "${sessmodel:-unknown}" \
  '{ts:$ts, session:$sid, session_model:$sess, model:$model, type:$type, effort:$eff, desc:$desc, plan_state:$state, decision:$decision, forced_model:$forced, inside_worker:$inside}' \
  >> "$DISPATCH_LOG_DIR/agent-dispatch.jsonl" 2>/dev/null

case "$decision" in
  deny|ask)
    jq -cn --arg r "$reason" --arg d "$decision" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:$d, permissionDecisionReason:$r}}'
    ;;
  *)
    [ "$orch_session" = 1 ] && [ -n "$sid" ] && date +%s >> "$DISPATCH_STATE_DIR/workers.$sid" 2>/dev/null
    forced_note=""; [ -n "$updated" ] && forced_note=" (forced: ${forced_why})"
    msg="Subagent launch: model ${eff_model}${forced_note} | effort ${eff_effort} | type ${stype} | ${plan}${warn} | job: ${desc}"
    if [ -n "$updated" ]; then
      jq -cn --arg m "$msg" --arg c "$context" --argjson u "$updated" \
        '{systemMessage:$m, hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow",
          permissionDecisionReason:$m, updatedInput:$u, additionalContext:$c}}'
    else
      # No permissionDecision: the user's own permission rules still decide.
      jq -cn --arg m "$msg" '{systemMessage:$m}'
    fi
    ;;
esac
exit 0
