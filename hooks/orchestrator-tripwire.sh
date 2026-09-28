#!/usr/bin/env bash
# PostToolUse on Bash: the orchestrator tripwire. Catches what the gate could not.
#
# orchestrator-gate.sh touches $DISPATCH_STATE_DIR/orch-mark.<session> right before a
# parent Bash command runs in an orchestrator session. This hook runs right after
# and lists every code file under the working directory (and its other git
# worktrees) that changed during that command: a write through node -e, python,
# or a script that the gate's pattern check cannot see. It never blocks; the
# change already happened. It warns the model and logs to
# $DISPATCH_LOG_DIR/orch-violations.jsonl.
#
# Skipped: workers, non-orchestrator sessions, the off switches, commands made
# only of git and view commands, a working directory too broad to scan, and build
# outputs and lockfiles. While a worker dispatch is live (see dispatch-gate.sh),
# changes are logged quietly, because the worker may have made them.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty')
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -n "$agent_id" ] && exit 0
[ -z "$sid" ] && exit 0
[ -f "$DISPATCH_STATE_DIR/orch-off.$sid" ] && exit 0
[ -f "$HOME/.claude/orchestrator.off" ] && exit 0
mark="$DISPATCH_STATE_DIR/orch-mark.$sid"
[ -f "$mark" ] || exit 0
is_orch_session "$(session_model "$tp")" || exit 0

worker_active=0
workers="$DISPATCH_STATE_DIR/workers.$sid"
if [ -s "$workers" ] && [ $(( $(date +%s) - $(file_mtime "$workers") )) -lt 10800 ]; then
  worker_active=1
fi

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -z "$cwd" ] && exit 0
case "$cwd" in /|/tmp|"$HOME") exit 0 ;; esac   # too broad to scan

# Commands made only of git and view commands cannot be a parent code write
# (checkout and merge change mtimes legitimately).
clean=$(printf '%s' "$cmd" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")
only_view=1
while IFS= read -r seg; do
  seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//')
  [ -z "$seg" ] && continue
  hd=$(printf '%s' "$seg" | awk '{print $1}'); hd="${hd##*/}"
  case "$hd" in git|cd|echo|printf|true|cat|grep|rg|head|ls|tail|wc|pwd|which|stat|file|diff|jq) : ;; *) only_view=0; break ;; esac
done <<< "$(printf '%s' "$clean" | tr '\n' ';' | sed -E 's/\|\|/;/g; s/&&/;/g; s/\|/;/g' | tr ';' '\n')"
[ "$only_view" = 1 ] && exit 0

ignored() {
  case "$1" in
    "$HOME"/.claude/*|"$DISPATCH_LOG_DIR"/*|/tmp/claude-*|*/.claude/*) return 0 ;;
    */next-env.d.ts|*.tsbuildinfo|*/package-lock.json|*/pnpm-lock.yaml|*/yarn.lock|*/bun.lockb|*.generated.*) return 0 ;;
  esac
  return 1
}

# find -name clauses for every code extension (portable: no -regextype).
name_args=()
for e in $DISPATCH_CODE_EXT; do
  [ "${#name_args[@]}" -gt 0 ] && name_args+=(-o)
  name_args+=(-name "*.$e")
done

scan_roots=("$cwd")
while IFS= read -r wt; do
  [ -n "$wt" ] && [ -d "$wt" ] && [ "$wt" != "$cwd" ] || continue
  case "$wt" in /|/tmp|"$HOME") continue ;; esac
  scan_roots+=("$wt")
done < <(git -C "$cwd" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')

run_find() {
  if command -v timeout >/dev/null 2>&1; then timeout 5 find "$@"; else find "$@"; fi
}

changed=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  ignored "$f" && continue
  changed+="$f"$'\n'
done <<< "$(run_find "${scan_roots[@]}" -xdev \
  \( -type d \( -name node_modules -o -name .git -o -name .next -o -name dist -o -name build -o -name out -o -name coverage -o -name .turbo -o -name .cache -o -name .venv -o -name venv -o -name __pycache__ -o -name .worktrees -o -name target \) -prune \) \
  -o -type f -newer "$mark" \( "${name_args[@]}" \) -print 2>/dev/null | awk '!seen[$0]++' | head -20)"
[ -z "$changed" ] && exit 0

files=$(printf '%s' "$changed" | sed '/^$/d' | paste -sd ' ' -)
jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$sid" --arg cmd "${cmd:0:300}" --arg files "$files" \
  --argjson worker_active "$([ "$worker_active" = 1 ] && echo true || echo false)" \
  '{ts:$ts, session:$sid, command:$cmd, files:$files, worker_active:$worker_active}' \
  >> "$DISPATCH_LOG_DIR/orch-violations.jsonl" 2>/dev/null

[ "$worker_active" = 1 ] && exit 0

msg="ORCH TRIPWIRE: code files changed during your Bash command (${cmd:0:80}): $files. If you wrote them, that breaks the parent rule: revert them and brief a worker instead. If a concurrent worker or a build step wrote them, ignore this. Logged to $DISPATCH_LOG_DIR/orch-violations.jsonl."
jq -cn --arg m "$msg" '{systemMessage:$m, hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$m}}'
exit 0
