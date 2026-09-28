#!/usr/bin/env bash
# PreToolUse on Edit|Write|MultiEdit|NotebookEdit|Bash: the orchestrator gate.
#
# When the parent session runs on a model in DISPATCH_ORCH_MODELS (default:
# fable), the parent does not write code. It explores, plans, writes work
# orders, dispatches builder / scout / reviewer workers, and verifies what comes
# back. Workers are exempt (their hook input carries agent_id). Sessions on any
# other model are untouched.
#
# Always allowed for the parent: ~/.claude/**, the dispatch log dir, the session
# scratchpad (/tmp/claude-*), *.md / *.txt (plans, specs, briefs), project
# .claude/ config, and any glob in DISPATCH_ORCH_ALLOW (colon-separated).
#
# Bash is judged on evidence of a code-file write only: a redirect, cp / mv /
# tee / sed -i / perl -i aimed at a code file, git apply / git am / patch,
# `git checkout <rev> -- <path>`, `git restore --source`, or find / fd with
# -delete / -exec. Everything else runs; orchestrator-tripwire.sh (PostToolUse)
# then lists any code file the command changed anyway.
#
# Off switches (only when the user explicitly says "do it yourself"):
#   the direct-mode hook sets one for the current turn, or
#   touch ~/.claude/orchestrator.off        # every session, until removed
# Playbook: skill orchestrating. Tests: tests/run.sh.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
CODE_EXT=$(code_ext_re)

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty')
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty')

[ -n "$agent_id" ] && exit 0
[ -z "$sid" ] && exit 0
[ -f "$DISPATCH_STATE_DIR/orch-off.$sid" ] && exit 0
[ -f "$HOME/.claude/orchestrator.off" ] && exit 0
is_orch_session "$(session_model "$tp")" || exit 0

allowed_path() {
  local p="$1" g
  [ -z "$p" ] && return 0
  case "$p" in
    "$HOME"/.claude/*|"$DISPATCH_LOG_DIR"/*|/tmp/claude-*) return 0 ;;
    *.md|*.MD|*.markdown|*.txt) return 0 ;;
    */.claude/*) return 0 ;;
  esac
  local IFS=:
  for g in ${DISPATCH_ORCH_ALLOW:-}; do
    # shellcheck disable=SC2254
    case "$p" in $g) return 0 ;; esac
  done
  return 1
}

deny() {
  local reason="ORCHESTRATOR GATE: the parent session plans, dispatches, and verifies; workers write the code, every line. Blocked: $1. Do not route around this with sed, heredocs, or tee. Write the work order (template: the orchestrating skill's work-order.md) and dispatch subagent_type builder (builder-high / builder-deep for harder orders), scout for recon, reviewer before shipping. Still allowed directly: ~/.claude/**, *.md plans and briefs, the session scratchpad. Only if the user explicitly said 'do it yourself' this turn: touch $DISPATCH_STATE_DIR/orch-off.$sid"
  jq -cn --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
  exit 0
}

case "$tool" in
  Edit|MultiEdit|Write)
    path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
    allowed_path "$path" || deny "$tool of $path"
    ;;
  NotebookEdit)
    path=$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // empty')
    allowed_path "$path" || deny "NotebookEdit of $path"
    ;;
  Bash)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
    [ -z "$cmd" ] && exit 0
    cwd=$(printf '%s' "$input" | jq -r '.cwd // "."')

    # Each target line is "<must_exist>:<path>". Redirects and copiers may create
    # the file (0); in-place editors only touch existing files (1), so a filename
    # inside a sed expression cannot trip the gate. `2>&1` is never a target.
    targets=$(printf '%s' "$cmd" | grep -oE '>>?[[:space:]]*[^[:space:]&|;>]+' | sed -E 's/^>>?[[:space:]]*/0:/')$'\n'
    if printf '%s' "$cmd" | grep -qE '(^|[;&|(][[:space:]]*|sudo[[:space:]]+)(tee|sponge|truncate|cp|mv|rm|rsync|install|dd)[[:space:]]'; then
      targets+=$(printf '%s' "$cmd" | grep -oE "[^[:space:]'\"=;|&<>()]+\.${CODE_EXT}\b" | sed 's/^/0:/')$'\n'
    elif printf '%s' "$cmd" | grep -qE '(^|[;&|(][[:space:]]*|sudo[[:space:]]+)(sed[[:space:]]+(-[a-zA-Z]*i|--in-place)|perl[[:space:]]+-[a-zA-Z]*i)'; then
      targets+=$(printf '%s' "$cmd" | grep -oE "[^[:space:]'\"=;|&<>()]+\.${CODE_EXT}\b" | sed 's/^/1:/')$'\n'
    fi

    # Patch appliers and history restores, one command segment at a time.
    case "$cmd" in
      *git*|*patch*)
        while IFS= read -r seg; do
          read -ra w <<< "$seg"
          i=0
          while [ "$i" -lt "${#w[@]}" ]; do
            case "${w[$i]}" in
              sudo|command|exec|nice|nohup|env) i=$((i + 1)) ;;
              timeout) i=$((i + 2)) ;;
              [A-Za-z_]*=*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done
          head="${w[$i]:-}"; head="${head##*/}"
          [ "$head" = patch ] && deny "patch applies a diff (command: ${cmd:0:80})"
          [ "$head" = git ] || continue
          i=$((i + 1)); base="$cwd"
          while [ "$i" -lt "${#w[@]}" ]; do
            case "${w[$i]}" in
              -C) d="${w[$((i + 1))]:-}"; case "$d" in /*) base="$d" ;; *) base="$base/$d" ;; esac; i=$((i + 2)) ;;
              -c|--git-dir|--work-tree|--namespace) i=$((i + 2)) ;;
              -*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done
          sub="${w[$i]:-}"
          args=("${w[@]:$((i + 1))}")
          paths=()
          case "$sub" in
            am) deny "git am applies patches (command: ${cmd:0:80})" ;;
            apply)
              ro=0
              for a in "${args[@]}"; do case "$a" in --check|--stat|--numstat|--summary) ro=1 ;; esac; done
              for a in "${args[@]}"; do [ "$a" = --apply ] && ro=0; done
              [ "$ro" = 1 ] || deny "git apply writes the files named in the diff (command: ${cmd:0:80})"
              ;;
            checkout)
              pre=(); post=(); dd=0
              for a in "${args[@]}"; do
                if [ "$dd" = 1 ]; then post+=("$a"); continue; fi
                case "$a" in --) dd=1 ;; -*) ;; *) pre+=("$a") ;; esac
              done
              if [ "$dd" = 1 ]; then
                [ "${#pre[@]}" -ge 1 ] && paths=("${post[@]}")
              elif [ "${#pre[@]}" -ge 2 ]; then
                paths=("${pre[@]:1}")
              fi
              ;;
            restore)
              has_source=0; skip=0
              for a in "${args[@]}"; do
                if [ "$skip" = 1 ]; then skip=0; continue; fi
                case "$a" in
                  --source|-s) has_source=1; skip=1 ;;
                  --source=*|-s?*) has_source=1 ;;
                  -*) ;;
                  *) paths+=("$a") ;;
                esac
              done
              [ "$has_source" = 1 ] || paths=()
              ;;
          esac
          for pth in "${paths[@]}"; do
            pth="${pth%\"}"; pth="${pth#\"}"; pth="${pth%\'}"; pth="${pth#\'}"
            case "$pth" in /*) ;; *) pth="$base/$pth" ;; esac
            targets+="0:$pth"$'\n'
          done
        done < <(printf '%s\n' "$cmd" | sed -E 's/[;&|()`]/\n/g')
        ;;
    esac

    while IFS= read -r line; do
      [ -z "$line" ] && continue
      must_exist="${line%%:*}"; t="${line#*:}"
      t="${t%\"}"; t="${t#\"}"; t="${t%\'}"; t="${t#\'}"
      printf '%s' "$t" | grep -qE "\.${CODE_EXT}$" || printf '%s' "$t" | grep -qE '(^|/)(Dockerfile|Makefile)$' || continue
      abs="$t"; case "$t" in /*) ;; *) abs="$cwd/$t" ;; esac
      allowed_path "$abs" && continue
      [ "$must_exist" = 1 ] && [ ! -e "$abs" ] && continue
      deny "Bash write to $t (command: ${cmd:0:80})"
    done <<< "$targets"

    if printf '%s' "$cmd" | grep -qE '(^|[;&|(`][[:space:]]*|\$\([[:space:]]*|sudo[[:space:]]+|timeout[[:space:]]+[0-9]+[[:space:]]+)(find|fd)[[:space:]]' \
       && printf '%s' "$cmd" | grep -qE '(^|[[:space:]])(-delete|-exec(dir)?|-ok(dir)?|-x|-X|--exec(-batch)?)([[:space:]]|$)'; then
      deny "find/fd with -delete/-exec (command: ${cmd:0:80})"
    fi

    # Mark the moment the command starts; the tripwire compares mtimes against it.
    touch "$DISPATCH_STATE_DIR/orch-mark.$sid" 2>/dev/null
    ;;
esac
exit 0
