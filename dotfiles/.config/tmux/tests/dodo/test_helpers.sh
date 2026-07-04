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

printf '\n%s\n' "----"
if [[ "$fails" -gt 0 ]]; then printf '%d test(s) failed\n' "$fails"; exit 1; fi
printf 'all passed\n'
