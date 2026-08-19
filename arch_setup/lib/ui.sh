#!/bin/bash
# Terminal I/O. No side effects at source time.
# shellcheck shell=bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${BLUE}[*]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
die()     { error "$*"; exit 1; }

banner() {
    local phase=$1 total=$2 title=$3 line
    line=$(printf '=%.0s' {1..50})
    printf '\n%b%s%b\n' "${CYAN}${BOLD}" "$line" "$RESET"
    printf '%b  [%s/%s] %s%b\n' "${CYAN}${BOLD}" "$phase" "$total" "$title" "$RESET"
    printf '%b%s%b\n\n' "${CYAN}${BOLD}" "$line" "$RESET"
}

# _ask_read <varname> <prompt> [--silent] -- read one line, non-zero on EOF.
#
# EOF is a failure, not an empty answer. install.sh wraps these in "ask,
# validate, re-ask" loops, and a closed stdin used to make `ask` hand back the
# default (or "") forever, so the loop spun printing prompts nobody could
# answer. Returning non-zero lets the caller's `set -e` stop the run instead.
#
# The locals carry a __ prefix for the reason ask_password documents: `read`
# assigns in this function's scope, so a caller asking for its own variable
# named `prompt` would have the answer written to our local and lose it.
_ask_read() {
    local __var=$1 __prompt=$2 __silent=${3:-} __rc=0
    if [[ "$__silent" == "--silent" ]]; then
        read -rsp "$__prompt" "${__var?}" || __rc=$?
    else
        read -rp "$__prompt" "${__var?}" || __rc=$?
    fi
    # A failed read that still filled the variable is a last line with no
    # trailing newline -- an answer, not EOF. `read` assigns the partial input
    # before returning non-zero, and assigns "" when there was none at all.
    (( __rc == 0 )) || [[ -n "${!__var}" ]]
    # NOTE for anyone refactoring the branch above: dropping the -s from the
    # silent read echoes the root and LUKS passwords to the console, and no
    # behavioural test in this suite can catch it -- terminal echo is the
    # terminal's, so it does not appear in captured output, and `script -qec`
    # with piped stdin produces byte-identical output with and without -s
    # (measured). test/ui.bats pins it structurally instead.
}

# Prompts on stderr so the answer is the only thing on stdout and
# `x=$(ask ...)` captures cleanly.
ask() {
    local prompt=$1 default=${2:-} input
    if [[ -n "$default" ]]; then
        if ! _ask_read input "$(echo -e "${BOLD}${prompt}${RESET} [${default}]: ")"; then
            error "ask: end of input while reading '${prompt}'"
            return 1
        fi
        echo "${input:-$default}"
    else
        if ! _ask_read input "$(echo -e "${BOLD}${prompt}${RESET}: ")"; then
            error "ask: end of input while reading '${prompt}'"
            return 1
        fi
        echo "$input"
    fi
}

# WARNING: unlike `ask` and `ask_password`, this ANSWERS WITH ITS DEFAULT AT
# EOF rather than failing -- verified, and deliberate. Every alternative is
# worse: returning non-zero makes install.sh's `if ask_yes_no "Encrypt...?"`
# silently install *unencrypted* when it cannot ask, and `die` breaks the
# reboot prompt, where declining must not make a successful install exit
# non-zero. confirm_step defaults to yes, so it proceeds on a closed stdin too.
#
# So: NOTHING DESTRUCTIVE MAY SIT BEHIND THIS FUNCTION OR confirm_step. What
# actually protects install.sh is that `ask` fails at EOF whether or not it has
# a default, so a closed stdin dies at the first prompt of phase 2, long before
# anything is written; and the gate immediately in front of `plan_execute` is a
# bare `read` that fails closed. test/install.bats asserts both.
ask_yes_no() {
    local prompt=$1 default=${2:-y} input hint
    # A default that is not y/n can never satisfy the case below, so on EOF
    # (stdin closed, e.g. a non-interactive run) the loop would spin forever.
    case "$default" in
        y|n) ;;
        *) error "ask_yes_no: default must be 'y' or 'n', got '${default}'"; return 2 ;;
    esac
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    while true; do
        read -rp "$(echo -e "${BOLD}${prompt}${RESET} ${hint}: ")" input
        input="${input:-$default}"
        case "${input,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     warn "Please answer y or n." ;;
        esac
    done
}

# ask_choice <prompt> <option>... -> the chosen option, verbatim, on stdout.
#
# Returns the full option string rather than an index so the caller's case
# statement reads as the options do; an index means every call site carries a
# mapping that drifts the moment an option is inserted.
#
# Everything except the answer goes to stderr. install.sh calls this as
# `mode=$(ask_choice ...)`, so a single mistyped digit whose retry message
# reached stdout would end up in $mode, match no case arm, and abort phase 3 --
# and lib/ui.sh's warn has no >&2 of its own (only error does).
ask_choice() {
    if (( $# < 2 )); then
        error "ask_choice: want a prompt and at least one option"
        return 1
    fi
    local prompt=$1; shift
    local -a options=("$@")
    local i reply
    while true; do
        printf '%b\n' "${BLUE}[?]${RESET} ${prompt}" >&2
        for i in "${!options[@]}"; do
            printf '    %d) %s\n' "$(( i + 1 ))" "${options[$i]}" >&2
        done
        # A bare read, failing closed on EOF, for the same reason phase_disk's
        # confirmation gate uses one: this runs in front of the disk prompts,
        # and a piped-in stdin must not silently select option 1 -- which is
        # the whole-disk wipe.
        if ! read -rp "$(printf '%b' "${BLUE}[?]${RESET} choice [1-${#options[@]}]: ")" reply; then
            error "ask_choice: end of input while reading a choice"
            return 1
        fi
        # Three digits at most, and read in base 10. Bash arithmetic reads a
        # leading-zero numeral as octal, so "08" aborts the (( )) outright
        # ("value too great for base") instead of selecting anything; and an
        # unbounded digit run wraps at 64 bits, so 18446744073709551617
        # evaluates to 1 and would quietly pick the first option.
        if [[ "$reply" =~ ^[0-9]{1,3}$ ]] && (( 10#$reply >= 1 && 10#$reply <= ${#options[@]} )); then
            printf '%s\n' "${options[$(( 10#$reply - 1 ))]}"
            return 0
        fi
        warn "enter a number between 1 and ${#options[@]}" >&2
    done
}

# ask_password <output-var-name> [prompt]
#
# Locals carry an _ap_ prefix because `printf -v` assigns in this function's
# scope: a caller asking for its own variable named `prompt` or `pass1` would
# have the password written to our local and silently lose it on return.
ask_password() {
    local _ap_varname=$1 _ap_prompt=${2:-Password} _ap_pass1 _ap_pass2
    if [[ -z "$_ap_varname" ]]; then
        error "ask_password: no output variable name given"
        return 1
    fi
    case "$_ap_varname" in
        _ap_varname|_ap_prompt|_ap_pass1|_ap_pass2)
            error "ask_password: '${_ap_varname}' collides with an internal local"
            return 1 ;;
    esac
    while true; do
        # Same EOF rule as `ask`, and it matters more here: the retry loop has
        # no default to fall back on, so a closed stdin used to spin forever
        # re-prompting for a password (verified: `ask_password OUT </dev/null`
        # under `timeout 5` exited 124). install.sh calls this three times.
        if ! _ask_read _ap_pass1 "$(echo -e "${BOLD}${_ap_prompt}${RESET}: ")" --silent; then
            echo ""
            error "ask_password: end of input while reading '${_ap_prompt}'"
            return 1
        fi
        echo ""
        if ! _ask_read _ap_pass2 "$(echo -e "${BOLD}Confirm ${_ap_prompt}${RESET}: ")" --silent; then
            echo ""
            error "ask_password: end of input while reading '${_ap_prompt}'"
            return 1
        fi
        echo ""
        if [[ "$_ap_pass1" != "$_ap_pass2" ]]; then
            warn "Passwords do not match. Try again."
        elif [[ -z "$_ap_pass1" ]]; then
            warn "Password cannot be empty."
        else
            printf -v "$_ap_varname" '%s' "$_ap_pass1"
            return 0
        fi
    done
}

spinner() {
    local pid=$1 message=$2 spin="|/-\\" i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${BLUE}%s${RESET} %s" "${spin:i++%${#spin}:1}" "$message"
        sleep 0.1
    done
    printf "\r"
}

confirm_step() {
    printf '\n%bSummary:%b\n%s\n\n' "$BOLD" "$RESET" "$1"
    ask_yes_no "Proceed?" || die "Aborted by user."
}
