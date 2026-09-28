#!/usr/bin/env bash
# Self-test for the hooks and the installer. Runs in a throwaway HOME, needs no
# network and no Claude Code. Usage: tests/run.sh   (exit 0 = all passed)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/hooks"
T=$(mktemp -d "${TMPDIR:-/tmp}/dispatch-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

export HOME="$T/home"
export DISPATCH_LOG_DIR="$T/logs"
unset DISPATCH_CODE_MODEL DISPATCH_ASK_MODELS DISPATCH_ORCH_MODELS DISPATCH_ORCH_ALLOW DISPATCH_STAKES_RE DISPATCH_CODE_EXT CLAUDE_CONFIG_DIR
mkdir -p "$HOME/.claude" "$DISPATCH_LOG_DIR"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     output: %s\n' "$1" "${2:-}"; }

# Fake transcripts: the hooks read the session model from the newest assistant record.
FABLE="$T/fable.jsonl"; OPUS="$T/opus.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' '{"type":"assistant","message":{"model":"claude-fable-5-1","content":[]}}' > "$FABLE"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}' > "$OPUS"

PROJ="$T/proj"; mkdir -p "$PROJ/src"; echo 'export const a = 1' > "$PROJ/src/existing.ts"

# ev <transcript> <extra-json> -> hook input JSON
ev() { jq -cn --arg tp "$1" --arg cwd "$PROJ" --argjson x "$2" '{session_id:"s1", transcript_path:$tp, cwd:$cwd} + $x'; }
# expect <name> <hook> <input> <jq-filter that must be true>   (empty output is tested as {})
expect() {
  local out; out=$(printf '%s' "$3" | bash "$H/$2" 2>&1)
  if printf '%s' "${out:-{\}}" | jq -e "$4" >/dev/null 2>&1; then ok "$1"; else bad "$1" "$out"; fi
}
agent() { ev "$1" "{\"tool_name\":\"Agent\",\"tool_input\":$2}"; }
edit()  { ev "$1" "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$2\",\"old_string\":\"a\",\"new_string\":\"b\"}}"; }
bash_() { ev "$1" "$(jq -cn --arg c "$2" '{tool_name:"Bash", tool_input:{command:$c}}')"; }

DENY='.hookSpecificOutput.permissionDecision == "deny"'
ASK='.hookSpecificOutput.permissionDecision == "ask"'
SILENT='. == {}'
NODECISION='(.hookSpecificOutput.permissionDecision // "none") == "none"'

echo "== dispatch-gate.sh"
expect "builder with sonnet is rewritten to opus" dispatch-gate.sh \
  "$(agent "$OPUS" '{"subagent_type":"builder","model":"sonnet","description":"add button","prompt":"x"}')" \
  '.hookSpecificOutput.updatedInput.model == "opus" and .hookSpecificOutput.permissionDecision == "allow"'
expect "plugin-namespaced builder is rewritten too" dispatch-gate.sh \
  "$(agent "$OPUS" '{"subagent_type":"claude-code-dispatch:builder","model":"haiku","description":"add button","prompt":"x"}')" \
  '.hookSpecificOutput.updatedInput.model == "opus"'
expect "model-less general-purpose from the parent goes to opus" dispatch-gate.sh \
  "$(agent "$FABLE" '{"subagent_type":"general-purpose","description":"summarize logs","prompt":"x"}')" \
  '.hookSpecificOutput.updatedInput.model == "opus" and (.systemMessage | test("forced"))'
expect "pinned scout is left alone" dispatch-gate.sh \
  "$(agent "$FABLE" '{"subagent_type":"scout","description":"count routes","prompt":"x"}')" \
  "$NODECISION"' and (.systemMessage | test("model haiku"))'
expect "explicit fable worker asks" dispatch-gate.sh \
  "$(agent "$OPUS" '{"subagent_type":"general-purpose","model":"fable","description":"review plan","prompt":"x"}')" "$ASK"
expect "fork from an orchestrator session is denied" dispatch-gate.sh \
  "$(agent "$FABLE" '{"subagent_type":"fork","description":"try idea","prompt":"x"}')" "$DENY"
expect "fork from a normal session is allowed" dispatch-gate.sh \
  "$(agent "$OPUS" '{"subagent_type":"fork","description":"try idea","prompt":"x"}')" "$NODECISION"
expect "stakes job on sonnet asks" dispatch-gate.sh \
  "$(agent "$OPUS" '{"subagent_type":"general-purpose","model":"sonnet","description":"fix oauth refresh","prompt":"x"}')" "$ASK"
expect "stakes words in the prompt count too" dispatch-gate.sh \
  "$(agent "$OPUS" '{"subagent_type":"general-purpose","model":"haiku","description":"cleanup","prompt":"delete the stale rows"}')" "$ASK"
expect "read-only scout is exempt from stakes" dispatch-gate.sh \
  "$(agent "$OPUS" '{"subagent_type":"scout","description":"audit auth routes","prompt":"x"}')" "$NODECISION"
expect "inside a worker a model-less dispatch only warns" dispatch-gate.sh \
  "$(ev "$OPUS" '{"agent_id":"w1","tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"look","prompt":"x"}}')" \
  "$NODECISION"' and (.systemMessage | test("WARN"))'
echo '{"state":"RED","session_pct":91,"weekly_pct":50}' > "$DISPATCH_LOG_DIR/usage-latest.json"
expect "RED plan state warns on opus dispatches" dispatch-gate.sh \
  "$(agent "$OPUS" '{"subagent_type":"builder","description":"add button","prompt":"x"}')" '.systemMessage | test("plan RED")'
rm -f "$DISPATCH_LOG_DIR/usage-latest.json"
if [ "$(wc -l < "$DISPATCH_LOG_DIR/agent-dispatch.jsonl")" -ge 12 ] && jq -e . "$DISPATCH_LOG_DIR/agent-dispatch.jsonl" >/dev/null; then
  ok "every launch is logged as JSON lines"; else bad "every launch is logged as JSON lines"; fi
DISPATCH_CODE_MODEL=sonnet expect "DISPATCH_CODE_MODEL changes the forced model" dispatch-gate.sh \
  "$(agent "$OPUS" '{"subagent_type":"general-purpose","description":"x","prompt":"x"}')" '.hookSpecificOutput.updatedInput.model == "sonnet"'

echo "== orchestrator-gate.sh"
expect "fable parent: Edit of a .ts file is denied" orchestrator-gate.sh "$(edit "$FABLE" "$PROJ/src/a.ts")" "$DENY"
expect "fable parent: Edit of a .md plan is allowed" orchestrator-gate.sh "$(edit "$FABLE" "$PROJ/PLAN.md")" "$SILENT"
expect "fable parent: Edit under ~/.claude is allowed" orchestrator-gate.sh "$(edit "$FABLE" "$HOME/.claude/settings.json")" "$SILENT"
expect "opus parent: Edit of a .ts file is allowed" orchestrator-gate.sh "$(edit "$OPUS" "$PROJ/src/a.ts")" "$SILENT"
expect "worker in a fable session: Edit is allowed" orchestrator-gate.sh \
  "$(ev "$FABLE" "{\"agent_id\":\"w1\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PROJ/src/a.ts\",\"content\":\"x\"}}")" "$SILENT"
expect "redirect into a code file is denied" orchestrator-gate.sh "$(bash_ "$FABLE" 'echo hi > src/a.ts')" "$DENY"
expect "tee into a code file is denied" orchestrator-gate.sh "$(bash_ "$FABLE" 'printf x | tee src/b.py')" "$DENY"
expect "sed -i on an existing code file is denied" orchestrator-gate.sh "$(bash_ "$FABLE" 'sed -i s/a/b/ src/existing.ts')" "$DENY"
expect "sed -i naming a missing .ts file is allowed" orchestrator-gate.sh "$(bash_ "$FABLE" 'sed -i s/x.ts/y/ notes.txt')" "$SILENT"
expect "git apply is denied" orchestrator-gate.sh "$(bash_ "$FABLE" 'git apply fix.patch')" "$DENY"
expect "git apply --check is allowed" orchestrator-gate.sh "$(bash_ "$FABLE" 'git apply --check fix.patch')" "$SILENT"
expect "git checkout <rev> -- <code path> is denied" orchestrator-gate.sh "$(bash_ "$FABLE" 'git checkout main -- src/existing.ts')" "$DENY"
expect "git checkout <branch> is allowed" orchestrator-gate.sh "$(bash_ "$FABLE" 'git checkout main')" "$SILENT"
expect "git restore --source onto code is denied" orchestrator-gate.sh "$(bash_ "$FABLE" 'git restore --source=HEAD~1 src/existing.ts')" "$DENY"
expect "find -delete is denied" orchestrator-gate.sh "$(bash_ "$FABLE" "find . -name '*.log' -delete")" "$DENY"
expect "tests with 2>&1 are allowed" orchestrator-gate.sh "$(bash_ "$FABLE" 'npm test 2>&1 | tail -5')" "$SILENT"
expect "redirect into a .md file is allowed" orchestrator-gate.sh "$(bash_ "$FABLE" 'echo plan > PLAN.md')" "$SILENT"
[ -f "$DISPATCH_LOG_DIR/state/orch-mark.s1" ] && ok "an allowed Bash call leaves the tripwire mark" || bad "an allowed Bash call leaves the tripwire mark"
DISPATCH_ORCH_ALLOW="$PROJ/src/gen/*" expect "DISPATCH_ORCH_ALLOW whitelists a glob" orchestrator-gate.sh "$(edit "$FABLE" "$PROJ/src/gen/x.ts")" "$SILENT"
DISPATCH_ORCH_MODELS="" expect "DISPATCH_ORCH_MODELS='' turns the gate off" orchestrator-gate.sh "$(edit "$FABLE" "$PROJ/src/a.ts")" "$SILENT"
DISPATCH_ORCH_MODELS="opus" expect "DISPATCH_ORCH_MODELS=opus gates opus sessions" orchestrator-gate.sh "$(edit "$OPUS" "$PROJ/src/a.ts")" "$DENY"

echo "== direct-mode.sh"
expect "'do it yourself' opens direct mode" direct-mode.sh '{"session_id":"s1","prompt":"Just do it yourself, it is one line"}' '.systemMessage | test("Direct mode")'
expect "fable parent may edit code in direct mode" orchestrator-gate.sh "$(edit "$FABLE" "$PROJ/src/a.ts")" "$SILENT"
expect "the next prompt re-arms the gate" direct-mode.sh '{"session_id":"s1","prompt":"thanks"}' "$SILENT"
expect "gate is back after re-arm" orchestrator-gate.sh "$(edit "$FABLE" "$PROJ/src/a.ts")" "$DENY"
touch "$HOME/.claude/orchestrator.off"
expect "~/.claude/orchestrator.off turns the gate off" orchestrator-gate.sh "$(edit "$FABLE" "$PROJ/src/a.ts")" "$SILENT"
rm -f "$HOME/.claude/orchestrator.off"

echo "== orchestrator-tripwire.sh"
MARKF="$DISPATCH_LOG_DIR/state/orch-mark.s1"
rm -f "$DISPATCH_LOG_DIR/state/workers.s1"   # the dispatch tests above registered live workers
touch -t 202001010000 "$MARKF"; echo 'x' > "$PROJ/src/sneaky.ts"
expect "a code file changed by a parent command is reported" orchestrator-tripwire.sh \
  "$(bash_ "$FABLE" 'node -e "write it"')" '.systemMessage | test("sneaky.ts")'
expect "view-only commands are skipped" orchestrator-tripwire.sh "$(bash_ "$FABLE" 'git status && ls src')" "$SILENT"
expect "opus sessions are skipped" orchestrator-tripwire.sh "$(bash_ "$OPUS" 'node -e "x"')" "$SILENT"
date +%s > "$DISPATCH_LOG_DIR/state/workers.s1"
expect "stays quiet while a worker is active" orchestrator-tripwire.sh "$(bash_ "$FABLE" 'node -e "x"')" "$SILENT"
[ "$(wc -l < "$DISPATCH_LOG_DIR/orch-violations.jsonl")" -ge 2 ] && ok "violations are still logged" || bad "violations are still logged"

echo "== usage-snapshot.sh"
bash "$H/usage-snapshot.sh" </dev/null
jq -e '.state == "UNKNOWN" and .source == "none"' "$DISPATCH_LOG_DIR/usage-latest.json" >/dev/null \
  && ok "no credentials -> UNKNOWN snapshot, no network call" || bad "no credentials -> UNKNOWN snapshot" "$(cat "$DISPATCH_LOG_DIR/usage-latest.json")"
rm -f "$DISPATCH_LOG_DIR/usage-latest.json"
DISPATCH_USAGE_SNAPSHOT=0 bash "$H/usage-snapshot.sh" </dev/null
[ ! -f "$DISPATCH_LOG_DIR/usage-latest.json" ] && ok "DISPATCH_USAGE_SNAPSHOT=0 opts out" || bad "DISPATCH_USAGE_SNAPSHOT=0 opts out"

echo "== manifests and installer"
for f in hooks/hooks.json .claude-plugin/plugin.json .claude-plugin/marketplace.json; do
  jq -e . "$ROOT/$f" >/dev/null 2>&1 && ok "$f is valid JSON" || bad "$f is valid JSON"
done
for f in "$ROOT"/agents/*.md "$ROOT"/skills/*/SKILL.md; do
  head -1 "$f" | grep -q '^---$' && grep -q '^name: ' "$f" && grep -q '^description: ' "$f" \
    && ok "frontmatter: ${f#"$ROOT"/}" || bad "frontmatter: ${f#"$ROOT"/}"
done

export CLAUDE_CONFIG_DIR="$T/cc"; mkdir -p "$CLAUDE_CONFIG_DIR"
echo '{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/mine.sh"}]}]}}' > "$CLAUDE_CONFIG_DIR/settings.json"
bash "$ROOT/install.sh" --dry-run >/dev/null && [ ! -d "$CLAUDE_CONFIG_DIR/dispatch" ] && ok "install --dry-run changes nothing" || bad "install --dry-run changes nothing"
bash "$ROOT/install.sh" >/dev/null && bash "$ROOT/install.sh" >/dev/null
S="$CLAUDE_CONFIG_DIR/settings.json"
n=$(jq '[.hooks[][].hooks[].command | select(contains("/dispatch/hooks/"))] | length' "$S")
[ "$n" = 5 ] && ok "install twice -> exactly 5 hook entries (idempotent)" || bad "install twice -> 5 hook entries" "$n"
jq -e '.model == "opus" and ([.hooks.PreToolUse[].hooks[].command] | index("/usr/local/bin/mine.sh"))' "$S" >/dev/null \
  && ok "existing settings and hooks are preserved" || bad "existing settings and hooks are preserved" "$(cat "$S")"
[ -x "$CLAUDE_CONFIG_DIR/dispatch/hooks/dispatch-gate.sh" ] && [ -f "$CLAUDE_CONFIG_DIR/agents/builder.md" ] && [ -f "$CLAUDE_CONFIG_DIR/skills/orchestrating/work-order.md" ] \
  && ok "hooks, agents, and skills are copied" || bad "hooks, agents, and skills are copied"
cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Agent") | .hooks[0].command' "$S")
out=$(agent "$OPUS" '{"subagent_type":"general-purpose","description":"x","prompt":"x"}' | bash -c "$cmd")
printf '%s' "$out" | jq -e '.hookSpecificOutput.updatedInput.model == "opus"' >/dev/null && ok "installed hook command runs" || bad "installed hook command runs" "$out"
ls "$CLAUDE_CONFIG_DIR"/settings.json.bak.* >/dev/null 2>&1 && ok "settings.json backup written" || bad "settings.json backup written"
echo "changed" >> "$CLAUDE_CONFIG_DIR/agents/scout.md"
bash "$ROOT/install.sh" | grep -q 'SKIP agents/scout.md' && ok "a modified agent is not overwritten without --force" || bad "a modified agent is not overwritten without --force"
bash "$ROOT/install.sh" --uninstall >/dev/null
jq -e '[.hooks[][].hooks[].command | select(contains("/dispatch/hooks/"))] | length == 0' "$S" >/dev/null \
  && jq -e '.hooks.PreToolUse[0].hooks[0].command == "/usr/local/bin/mine.sh"' "$S" >/dev/null \
  && [ ! -d "$CLAUDE_CONFIG_DIR/dispatch" ] && [ ! -f "$CLAUDE_CONFIG_DIR/agents/builder.md" ] \
  && ok "uninstall removes only what it added" || bad "uninstall removes only what it added" "$(cat "$S")"
[ -f "$CLAUDE_CONFIG_DIR/agents/scout.md" ] && ok "uninstall keeps a user-modified agent" || bad "uninstall keeps a user-modified agent"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
