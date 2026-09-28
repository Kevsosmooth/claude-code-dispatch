#!/usr/bin/env bash
# UserPromptSubmit: a plain-language override of the orchestrator gate for one turn.
# "don't use agents", "go direct for this one", or "do it yourself" in the user's
# prompt lets the parent write code until the next prompt, then the gate re-arms.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty')
[ -n "$sid" ] || exit 0

marker="$DISPATCH_STATE_DIR/orch-off.$sid"
rm -f "$marker"   # a direct override lasts only until the next user prompt

normalized=$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]' | sed "s/’/'/g")
if printf '%s' "$normalized" | grep -Eq "(^|[[:space:][:punct:]])(don't use (the )?agents|dont use (the )?agents|do not use (the )?agents|go direct for this one|do it yourself)([[:space:][:punct:]]|$)"; then
  touch "$marker"
  jq -cn '{systemMessage:"Direct mode for this turn: the parent may write code without workers. The orchestrator gate re-arms on the next prompt."}'
fi
exit 0
