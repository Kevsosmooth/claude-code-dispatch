#!/usr/bin/env bash
# Optional. Caches your Claude plan usage (the percentages /usage shows) so the
# dispatch gate can print them and warn when the plan is RED.
#
# How: reads the Claude Code OAuth access token from ~/.claude/.credentials.json
# (Linux and WSL; macOS keeps it in the Keychain, so this finds nothing there and
# writes state UNKNOWN), makes ONE HTTPS call to Anthropic's usage endpoint, and
# stores only percentages and reset times. The token is never printed, logged, or
# written anywhere.
#
# The endpoint (api.anthropic.com/api/oauth/usage) is the one the /usage screen
# uses. It is not a documented public API and may change; when it fails, the
# snapshot says UNKNOWN and every consumer routes normally.
#
# Output: $DISPATCH_LOG_DIR/usage-latest.json (overwritten each run).
# Opt out: DISPATCH_USAGE_SNAPSHOT=0 in the settings env block.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ "${DISPATCH_USAGE_SNAPSHOT:-1}" = 0 ] && exit 0

OUT="$DISPATCH_LOG_DIR/usage-latest.json"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CRED="$HOME/.claude/.credentials.json"
BODY=$(mktemp "$DISPATCH_STATE_DIR/usage.XXXXXX") || exit 0
trap 'rm -f "$BODY"' EXIT
note="no credentials file (normal on macOS)"

if [ -r "$CRED" ]; then
  TOK=$(jq -r '.claudeAiOauth.accessToken // empty' "$CRED" 2>/dev/null)
  if [ -n "$TOK" ]; then
    HTTP=$(curl -sS -m 15 -o "$BODY" -w '%{http_code}' \
      -H "Authorization: Bearer $TOK" \
      -H "anthropic-beta: oauth-2025-04-20" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    unset TOK
    [ "$HTTP" = 200 ] || { note="usage endpoint returned HTTP ${HTTP:-none}"; : > "$BODY"; }
  else
    note="no access token in credentials file"
  fi
fi

SNAP=""
if [ -s "$BODY" ]; then
  SNAP=$(jq -c --arg ts "$NOW" '
    def lim($k): ([.limits[]? | select(.kind==$k)] | first);
    (lim("session")) as $s | (lim("weekly_all")) as $w
    | ($s.percent // .five_hour.utilization // null) as $sp
    | ($w.percent // .seven_day.utilization // null) as $wp
    | {ts:$ts, source:"oauth", session_pct:$sp, weekly_pct:$wp,
       session_resets:($s.resets_at // .five_hour.resets_at // null),
       weekly_resets:($w.resets_at // .seven_day.resets_at // null),
       state:(if $sp == null then "UNKNOWN"
              elif ($sp >= 85) or (($wp // 0) >= 90) then "RED"
              elif ($sp >= 60) or (($wp // 0) >= 70) then "AMBER"
              else "GREEN" end)}' "$BODY" 2>/dev/null)
fi
[ -n "$SNAP" ] || SNAP=$(jq -cn --arg ts "$NOW" --arg note "$note" '{ts:$ts, source:"none", state:"UNKNOWN", note:$note}')
printf '%s\n' "$SNAP" > "$OUT"
exit 0
