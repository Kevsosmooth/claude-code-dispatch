#!/usr/bin/env bash
# Shared helpers and settings for the claude-code-dispatch hooks.
# Every setting is an environment variable with a default. Override it in the
# "env" block of ~/.claude/settings.json; hooks inherit that environment.

# Model forced onto builder agents and onto dispatches that name no model.
DISPATCH_CODE_MODEL=${DISPATCH_CODE_MODEL:-opus}
# Explicit dispatches to these models (extended regex) need the user's yes.
DISPATCH_ASK_MODELS=${DISPATCH_ASK_MODELS:-fable}
# Parent sessions on these models (extended regex) may not write code; they
# plan, dispatch workers, and verify. Set to an empty string to turn the
# orchestrator gate and tripwire off entirely.
DISPATCH_ORCH_MODELS=${DISPATCH_ORCH_MODELS-fable}
# Logs, state markers, and the optional usage snapshot live here.
DISPATCH_LOG_DIR=${DISPATCH_LOG_DIR:-$HOME/.claude/dispatch-logs}
# Words that mark a dispatch as high stakes (security, money, deletion, sends).
DISPATCH_STAKES_RE=${DISPATCH_STAKES_RE:-'\b(auth|oauth|jwt|api[ -]?token|access token|bearer|secret|password|credential|payment|stripe|billing|checkout|delet(e|ion)|drop table|truncate|migration|outbound|email blast|send(s|ing)? (email|sms|text)|sms|go-live|go live)\b'}
# File extensions the orchestrator gate treats as code.
DISPATCH_CODE_EXT=${DISPATCH_CODE_EXT:-'ts tsx js jsx mjs cjs py go rs java kt swift c h cpp cc cs rb php css scss sass less html htm astro vue svelte sql prisma graphql gql json jsonc yaml yml toml xml sh bash zsh ps1'}

DISPATCH_STATE_DIR="$DISPATCH_LOG_DIR/state"
mkdir -p "$DISPATCH_STATE_DIR" 2>/dev/null

# The extension list as one extended-regex alternation: (ts|tsx|...).
code_ext_re() { printf '(%s)' "$(printf '%s' "$DISPATCH_CODE_EXT" | tr -s ' ' '|')"; }

# Modification time in epoch seconds (GNU stat, then BSD/macOS stat).
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# The model the parent session is running on, read from the newest assistant
# record in the transcript. Empty when it cannot be determined.
session_model() {
  local tp="$1"
  [ -n "$tp" ] && [ -f "$tp" ] || return 0
  tail -c 2000000 "$tp" 2>/dev/null | grep '"type":"assistant"' \
    | grep -o '"model":"claude-[^"]*"' | tail -1 | cut -d'"' -f4
}

# True when the parent session model matches DISPATCH_ORCH_MODELS.
is_orch_session() {
  [ -n "$DISPATCH_ORCH_MODELS" ] || return 1
  printf '%s' "$1" | grep -qiE "$DISPATCH_ORCH_MODELS"
}

# Plugin agents arrive as "plugin-name:agent"; the gates match on "agent".
bare_agent_type() { printf '%s' "${1##*:}"; }
