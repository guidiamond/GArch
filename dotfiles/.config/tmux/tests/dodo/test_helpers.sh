#!/usr/bin/env bash
# Self-contained assert harness for dodo-lib pure helpers. No bats needed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/dodo-lib.sh"

fails=0
assert_eq() { # $1=got $2=want $3=name
  if [[ "$1" != "$2" ]]; then
    printf 'FAIL: %s — got [%s] want [%s]\n' "$3" "$1" "$2"; fails=$((fails+1))
  else
    printf 'ok: %s\n' "$3"
  fi
}

# --- _claude_glyph <working> <live> ---
assert_eq "$(_claude_glyph no no)"   "💤" "claude: no session"
assert_eq "$(_claude_glyph no yes)"  "🔔" "claude: live idle = needs input"
assert_eq "$(_claude_glyph yes yes)" "⚙"  "claude: working"

# --- _state_glyph <state> ---
assert_eq "$(_state_glyph untracked)" "◽" "state glyph untracked"
assert_eq "$(_state_glyph tracked)"   "⬆" "state glyph tracked"
assert_eq "$(_state_glyph review)"    "👀" "state glyph review"
assert_eq "$(_state_glyph merged)"    "🟢" "state glyph merged"

# --- _ci_glyph <ci> ---
assert_eq "$(_ci_glyph passing)" "✅" "ci passing"
assert_eq "$(_ci_glyph failing)" "❌" "ci failing"
assert_eq "$(_ci_glyph running)" "🟡" "ci running"
assert_eq "$(_ci_glyph none)"    "─" "ci none"

# --- _classify_branch_state <merged> <has_remote> <pr_state> ---
assert_eq "$(_classify_branch_state no no none)"   "untracked" "classify untracked"
assert_eq "$(_classify_branch_state no yes none)"  "tracked"   "classify tracked"
assert_eq "$(_classify_branch_state no yes OPEN)"  "review"    "classify review"
assert_eq "$(_classify_branch_state yes yes OPEN)" "merged"    "classify merged wins"
assert_eq "$(_classify_branch_state no no MERGED)" "merged"    "classify pr merged"

# --- _ci_from_rollup <rollup-json> ---
assert_eq "$(_ci_from_rollup '[]')" "none" "ci rollup empty=none"
assert_eq "$(_ci_from_rollup '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]')" "passing" "ci rollup success"
assert_eq "$(_ci_from_rollup '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]')" "failing" "ci rollup one failure"
assert_eq "$(_ci_from_rollup '[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]')" "running" "ci rollup in progress"
assert_eq "$(_ci_from_rollup '[{"__typename":"StatusContext","state":"SUCCESS"}]')" "passing" "ci rollup status context success"
assert_eq "$(_ci_from_rollup '[{"__typename":"StatusContext","state":"PENDING"}]')" "running" "ci rollup status context pending"

# --- _cache_get <branch> <field> (against fixture) ---
GH_CACHE="$HERE/fixtures/gh-cache.json"
assert_eq "$(_cache_get eng-4308-create-abandoned-cart pr_state)" "OPEN" "cache_get pr_state"
assert_eq "$(_cache_get eng-4308-create-abandoned-cart ci)" "failing" "cache_get ci"
assert_eq "$(_cache_get eng-4308-create-abandoned-cart unresolved_threads)" "2" "cache_get threads"
assert_eq "$(_cache_get does-not-exist pr_state)" "" "cache_get missing branch = empty"

# --- _render_row <name> <claude_working> <claude_live> <state> <ci> <threads> ---
row=$(_render_row "eng-4308" yes yes review failing 2)
assert_eq "$row" "⚙ 👀 eng-4308  ❌ 💬2" "render active review failing w/ threads"
row=$(_render_row "foo" no no untracked none 0)
assert_eq "$row" "💤 ◽ foo  ─" "render dead untracked no threads"

# --- _name_from_row: name is token 3 ---
assert_eq "$(_name_from_row "⚙ 👀 eng-4308  ❌ 💬2")" "eng-4308" "name_from_row extracts name"

# --- regression: empty/unknown state glyph must be VISIBLE (non-space) so that
# positional name parsing (_name_from_row = token 3) stays correct for browse-all
# rows where the branch state is unknown. ---
assert_eq "$(_state_glyph "")"        "·" "state glyph empty = visible dot"
assert_eq "$(_state_glyph whatever)"  "·" "state glyph unknown = visible dot"
assert_eq "$(_name_from_row "$(_render_row browse-me no no "" none 0)")" "browse-me" "name_from_row survives empty state"

printf '\n%s\n' "----"
if [[ "$fails" -gt 0 ]]; then printf '%d test(s) failed\n' "$fails"; exit 1; fi
printf 'all passed\n'
