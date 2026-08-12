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

# Prompts on stderr so the answer is the only thing on stdout and
# `x=$(ask ...)` captures cleanly.
ask() {
    local prompt=$1 default=${2:-} input
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${BOLD}${prompt}${RESET} [${default}]: ")" input
        echo "${input:-$default}"
    else
        read -rp "$(echo -e "${BOLD}${prompt}${RESET}: ")" input
        echo "$input"
    fi
}

ask_yes_no() {
    local prompt=$1 default=${2:-y} input hint
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

ask_password() {
    local varname=$1 prompt=${2:-Password} pass1 pass2
    while true; do
        read -rsp "$(echo -e "${BOLD}${prompt}${RESET}: ")" pass1; echo ""
        read -rsp "$(echo -e "${BOLD}Confirm ${prompt}${RESET}: ")" pass2; echo ""
        if [[ "$pass1" != "$pass2" ]]; then
            warn "Passwords do not match. Try again."
        elif [[ -z "$pass1" ]]; then
            warn "Password cannot be empty."
        else
            printf -v "$varname" '%s' "$pass1"
            return 0
        fi
    done
}

ask_choice() {
    local prompt=$1; shift
    local options=("$@") i choice
    echo -e "${BOLD}${prompt}${RESET}" >&2
    for i in "${!options[@]}"; do
        echo "  $((i + 1))) ${options[$i]}" >&2
    done
    while true; do
        read -rp "$(echo -e "${BOLD}Choice [1-${#options[@]}]${RESET}: ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice - 1))]}"
            return 0
        fi
        warn "Invalid choice."
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
