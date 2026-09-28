#!/usr/bin/env bash
# Manual installer for claude-code-dispatch (the alternative to the plugin install).
#
#   ./install.sh              install or update (idempotent)
#   ./install.sh --dry-run    show what would change, change nothing
#   ./install.sh --force      overwrite agent/skill files that already exist and differ
#   ./install.sh --uninstall  remove the hooks from settings.json and delete installed files
#
# Installs to:
#   ~/.claude/dispatch/hooks/        the hook scripts
#   ~/.claude/agents/<name>.md       six pinned agents
#   ~/.claude/skills/<name>/         two skills
#   ~/.claude/settings.json          hook entries merged in (backup written first)
#
# Requires: bash, jq. Restart Claude Code afterwards; hooks and agents load at session start.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$CLAUDE_DIR/dispatch"
SETTINGS="$CLAUDE_DIR/settings.json"
MARK="/dispatch/hooks/"   # every hook command we add contains this; used to find our entries
AGENTS=(builder builder-high builder-deep reviewer scout researcher)
SKILLS=(choosing-subagent-models orchestrating)

DRY=0; FORCE=0; UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --force) FORCE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq / apt install jq)" >&2; exit 1; }

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY" = 1 ]; then say "  [dry-run] $*"; else "$@"; fi; }

# Remove every hook entry whose command contains $MARK, then drop empty events.
strip_ours() {
  jq --arg m "$MARK" '
    if .hooks then
      .hooks |= (with_entries(
        .value |= map(select(([.hooks[]?.command // ""] | any(contains($m))) | not))
      ) | with_entries(select(.value | length > 0)))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end'
}

write_settings() {
  local new="$1"
  if [ "$DRY" = 1 ]; then
    say "  [dry-run] would write $SETTINGS:"
    printf '%s\n' "$new" | jq '.hooks // {}' | sed 's/^/    /'
    return
  fi
  if [ -f "$SETTINGS" ]; then
    local bak
    bak="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS" "$bak"
    say "  backup: $bak"
  fi
  local tmp
  tmp=$(mktemp "$CLAUDE_DIR/settings.json.XXXXXX")
  printf '%s\n' "$new" > "$tmp"
  mv "$tmp" "$SETTINGS"
}

current_settings() {
  if [ -f "$SETTINGS" ]; then
    jq -e . "$SETTINGS" >/dev/null 2>&1 || { echo "$SETTINGS is not valid JSON; fix it first" >&2; exit 1; }
    cat "$SETTINGS"
  else
    echo '{}'
  fi
}

if [ "$UNINSTALL" = 1 ]; then
  say "Uninstalling claude-code-dispatch from $CLAUDE_DIR"
  if [ -f "$SETTINGS" ]; then
    write_settings "$(current_settings | strip_ours)"
    say "  removed hook entries from settings.json"
  fi
  run rm -rf "$DEST"
  for n in "${AGENTS[@]}"; do
    f="$CLAUDE_DIR/agents/$n.md"
    if [ -f "$f" ] && cmp -s "$f" "$SRC/agents/$n.md"; then run rm -f "$f"; say "  removed agent $n"
    elif [ -f "$f" ]; then say "  kept agents/$n.md (it differs from this repo's copy; delete it yourself if it is ours)"; fi
  done
  for s in "${SKILLS[@]}"; do
    d="$CLAUDE_DIR/skills/$s"
    if [ -d "$d" ] && diff -rq "$d" "$SRC/skills/$s" >/dev/null 2>&1; then run rm -rf "$d"; say "  removed skill $s"
    elif [ -d "$d" ]; then say "  kept skills/$s (it differs from this repo's copy)"; fi
  done
  say "Done. Logs are left in ${DISPATCH_LOG_DIR:-$CLAUDE_DIR/dispatch-logs}. Restart Claude Code."
  exit 0
fi

say "Installing claude-code-dispatch into $CLAUDE_DIR"

# 1. Hooks (always refreshed: they are ours).
run mkdir -p "$DEST/hooks/lib"
for f in "$SRC"/hooks/*.sh "$SRC"/hooks/lib/*.sh; do
  rel="${f#"$SRC"/}"
  run cp "$f" "$DEST/$rel"
  run chmod +x "$DEST/$rel"
done
say "  hooks -> $DEST/hooks"

# 2. Agents and skills (never clobber a different file without --force).
run mkdir -p "$CLAUDE_DIR/agents" "$CLAUDE_DIR/skills"
for n in "${AGENTS[@]}"; do
  f="$CLAUDE_DIR/agents/$n.md"
  if [ -f "$f" ] && ! cmp -s "$f" "$SRC/agents/$n.md" && [ "$FORCE" = 0 ]; then
    say "  SKIP agents/$n.md: a different file exists (re-run with --force to overwrite)"
    continue
  fi
  run cp "$SRC/agents/$n.md" "$f"
done
say "  agents -> $CLAUDE_DIR/agents (${AGENTS[*]})"
for s in "${SKILLS[@]}"; do
  d="$CLAUDE_DIR/skills/$s"
  if [ -d "$d" ] && ! diff -rq "$d" "$SRC/skills/$s" >/dev/null 2>&1 && [ "$FORCE" = 0 ]; then
    say "  SKIP skills/$s: a different copy exists (re-run with --force to overwrite)"
    continue
  fi
  run mkdir -p "$d"
  run cp -R "$SRC/skills/$s/." "$d/"
done
say "  skills -> $CLAUDE_DIR/skills (${SKILLS[*]})"

# 3. settings.json: drop any previous entries of ours, then append the plugin's
#    hooks.json with ${CLAUDE_PLUGIN_ROOT} replaced by the install directory.
ours=$(sed "s#\${CLAUDE_PLUGIN_ROOT}#$DEST#g" "$SRC/hooks/hooks.json" | jq '.hooks')
new=$(current_settings | strip_ours | jq --argjson ours "$ours" '
  .hooks = (reduce ($ours | to_entries[]) as $e (.hooks // {};
    .[$e.key] = ((.[$e.key] // []) + $e.value)))')
write_settings "$new"
say "  hooks merged into $SETTINGS"

say ""
say "Installed. Restart Claude Code, then verify:"
say "  1. /hooks lists dispatch-gate.sh, orchestrator-gate.sh, orchestrator-tripwire.sh, direct-mode.sh, usage-snapshot.sh"
say "  2. /agents lists builder, builder-high, builder-deep, reviewer, scout, researcher"
say "  3. Dispatch any subagent: a 'Subagent launch: model ...' message appears"
say "Self-test without Claude Code: $SRC/tests/run.sh"
