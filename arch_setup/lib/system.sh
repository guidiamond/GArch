#!/bin/bash
# Shared transforms, host probes and host actions. Both stages source this.
# Requires lib/ui.sh.
#
# The sudo-requiring, stage-2-only setup_* family used to sit at the bottom of
# this file and now lives in lib/setup.sh, because it violates every rule the
# COUPLING block below states -- by design, and irreconcilably. Nothing may be
# added back here that runs sudo or reads ARCH_SETUP_DIR.
#
# COUPLING: everything in this file -- hooks_line,
# modules_line, gpu_packages, require_vars, grub_cmdline_add,
# locale_gen_uncomment, locale_listed, link_timezone, detect_ucode, detect_gpu,
# needs_grub_install, list_keymaps, net_check, refresh_keyring, rank_mirrors
# -- is a candidate for injection into the generated chroot
# script, and lib/chroot.sh's CHROOT_INJECTED currently takes seven of them
# verbatim via `declare -f`. Anything injected runs under `set -Eeuo pipefail`
# in a shell that defines only RED GREEN YELLOW BLUE RESET and
# info/warn/error/success. So: no CYAN, no BOLD, no ARCH_SETUP_DIR, no sudo,
# no reading a variable the caller has not passed in -- an undefined name is
# fatal there, not cosmetic. See the CONSTRAINT block at chroot.sh's injection
# site; test/chroot.bats enforces it against the generated file.
# shellcheck shell=bash

# Arch no longer ships the proprietary nvidia/nvidia-dkms packages -- only the
# open modules. Pre-Turing cards need an AUR nvidia-<branch>xx-dkms and are out
# of scope here.
GPU_NVIDIA=(nvidia-open-dkms nvidia-utils nvidia-settings)
GPU_AMD=(xf86-video-amdgpu mesa vulkan-radeon)
GPU_INTEL=(mesa vulkan-intel intel-media-driver)

# --- pure transforms (no I/O) ----------------------------------------------

# hooks_line "HOOKS=(...)" <want_encrypt> -> new HOOKS line
hooks_line() {
    local line=$1 want_encrypt=$2 inner hooks=() out=() h
    inner=${line#*\(}; inner=${inner%\)*}
    read -ra hooks <<< "$inner"

    printf '%s\n' "${hooks[@]}" | grep -qx filesystems \
        || { error "hooks_line: no 'filesystems' hook in: $line"; return 1; }

    for h in "${hooks[@]}"; do
        # encrypt must come before filesystems, and only once
        if [[ "$h" == "filesystems" && "$want_encrypt" == true ]]; then
            printf '%s\n' "${out[@]}" | grep -qx encrypt || out+=(encrypt)
        fi
        out+=("$h")
        # microcode must come after autodetect, and only once
        if [[ "$h" == "autodetect" ]]; then
            printf '%s\n' "${hooks[@]}" | grep -qx microcode || out+=(microcode)
        fi
    done
    echo "HOOKS=(${out[*]})"
}

# modules_line "MODULES=(...)" mod... -> new MODULES line
modules_line() {
    local line=$1; shift
    local inner mods=() m
    inner=${line#*\(}; inner=${inner%\)*}
    [[ -n "${inner// }" ]] && read -ra mods <<< "$inner"
    for m in "$@"; do
        printf '%s\n' "${mods[@]}" | grep -qx -- "$m" || mods+=("$m")
    done
    echo "MODULES=(${mods[*]})"
}

# gpu_packages <choice> -- the packages for a driver, empty for "none", and
# NON-ZERO for anything else.
#
# "none" and "not a driver I know" are different answers and must not share a
# return: this used to answer "" at status 0 for every unrecognised value, and
# setup_gpu reads an empty package list as "no GPU driver selected", so `nvidai`
# -- or `NVIDIA`, which is exactly what the prompt's own "Detected GPU: nvidia"
# line invites -- installed nothing, configured nothing, and landed in the
# summary as a green step.
gpu_packages() {
    case "$1" in
        nvidia) echo "${GPU_NVIDIA[*]}" ;;
        amd)    echo "${GPU_AMD[*]}" ;;
        intel)  echo "${GPU_INTEL[*]}" ;;
        none)   echo "" ;;
        *)      error "gpu_packages: unrecognised GPU driver '${1}' (want nvidia, amd, intel or none)"
                return 1 ;;
    esac
}

# require_vars NAME... -- every named variable must exist and be non-empty.
# Names them all at once so a caller running under `set -u` fails with one
# readable list before it mutates anything, rather than dying on a bare
# "unbound variable" partway through.
require_vars() {
    local name missing=()
    for name in "$@"; do
        # The `-` default is what makes this safe under `set -u`.
        [[ -n "${!name-}" ]] || missing+=("$name")
    done
    if (( ${#missing[@]} > 0 )); then
        error "missing or empty required config value(s): ${missing[*]}"
        return 1
    fi
}

# --- config files (readers and editors) ------------------------------------

# grub_cmdline_add <file> key=value  -- idempotent, replaces a changed value.
# Asserts before and verifies after: a silent no-op here means a kernel with no
# cryptdevice= and a system that will not boot, discovered only at reboot.
grub_cmdline_add() {
    local file=$1 kv=$2 key=${2%%=*} current new tokens=() t

    # sed would mangle these: & means "the whole match" in a replacement, | is
    # the delimiter, and a backslash starts an escape. A kernel command-line
    # token never legitimately contains them, so refuse rather than escape.
    if [[ "$kv" == *'&'* || "$kv" == *'|'* || "$kv" == *"\\"* ]]; then
        error "grub_cmdline_add: '${kv}' contains a sed metacharacter (& | \\)"
        return 1
    fi

    grep -qE '^GRUB_CMDLINE_LINUX="[^"]*"[[:space:]]*$' "$file" \
        || { error "grub_cmdline_add: ${file} has no double-quoted GRUB_CMDLINE_LINUX line"; return 1; }
    current=$(grep -oP '(?<=^GRUB_CMDLINE_LINUX=").*(?="$)' "$file" || echo "")
    read -ra tokens <<< "$current"
    new=()
    for t in "${tokens[@]}"; do
        [[ "${t%%=*}" == "$key" ]] && continue   # drop any prior value for this key
        new+=("$t")
    done
    new+=("$kv")
    sed -i "s|^GRUB_CMDLINE_LINUX=\".*\"$|GRUB_CMDLINE_LINUX=\"${new[*]}\"|" "$file"
    grep -qF -- "$kv" "$file" \
        || { error "grub_cmdline_add: failed to write '${kv}' to ${file}"; return 1; }
}

# locale_gen_uncomment <file> <locale> -- uncomment the locale.gen entry whose
# locale name is exactly <locale>.
#
# The first field is compared as a fixed string rather than interpolating
# <locale> into a regex: the value comes straight from an unvalidated prompt,
# and in a regex the '.' of 'en_US.UTF-8' is a wildcard -- it leaves
# '#en_USX.UTF-8' alone but does uncomment '#en_USxUTF-8'. Absence is an
# error, not a no-op: sed and locale-gen both exit 0 having done nothing,
# which leaves /etc/locale.conf naming a locale the system does not have.
locale_gen_uncomment() {
    local file=$1 locale=$2 tmp mode
    [[ -n "$locale" ]] || { error "locale_gen_uncomment: empty locale"; return 1; }
    [[ -f "$file" ]] || { error "locale_gen_uncomment: no such file: ${file}"; return 1; }

    tmp=$(mktemp "${file}.XXXXXX") \
        || { error "locale_gen_uncomment: cannot create a temp file next to ${file}"; return 1; }

    if ! awk -v loc="$locale" '
        !found {
            probe = $0
            sub(/^#[[:space:]]*/, "", probe)
            split(probe, f, /[[:space:]]+/)
            if (f[1] == loc) { print probe; found = 1; next }
        }
        { print }
        END { exit(found ? 0 : 1) }
    ' "$file" > "$tmp"; then
        rm -f "$tmp"
        error "locale_gen_uncomment: ${locale} is not listed in ${file}"
        return 1
    fi

    # Moved into place, not copied over: a `cat` dying midway would leave the
    # file truncated with the original already gone. mktemp makes 0600, so the
    # original mode is captured first and restored after -- a locale.gen only
    # root can read is a surprise nobody needs later.
    mode=$(stat -c '%a' "$file") \
        || { rm -f "$tmp"; error "locale_gen_uncomment: cannot stat ${file}"; return 1; }
    if ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        error "locale_gen_uncomment: failed to replace ${file}"
        return 1
    fi
    chmod "$mode" "$file" || { error "locale_gen_uncomment: failed to restore mode ${mode} on ${file}"; return 1; }
}

# locale_listed <locale.gen> <locale> -- 0 listed, 1 absent, 2 cannot answer.
#
# The read-only counterpart of locale_gen_uncomment above, and it lives beside
# it deliberately: it exists only to answer "would locale_gen_uncomment find
# this?" before anything is committed to, and the two must agree exactly. Split
# across files they drift, and the divergence surfaces inside the chroot on a
# wiped disk -- which is the failure this function was written to prevent.
#
# So the matching rule is copied from there verbatim: strip a leading comment
# marker, then compare the *first whitespace-separated field* as a fixed
# string. Not a regex, for the reason documented there -- the '.' in
# 'en_US.UTF-8' is a wildcard, and a regex match accepts 'en_USxUTF-8'.
#
# install.sh calls this against the live ISO's /etc/locale.gen, which comes
# from the same glibc package pacstrap installs into /mnt, so a locale that
# passes at the prompt is one locale_gen_uncomment will find in the chroot.
#
# Status 2 is "cannot answer" and is deliberately distinct from 1: a caller
# that cannot read the file must be able to accept the value unchecked rather
# than reject every locale its operator types.
locale_listed() {
    local file=$1 locale=$2
    [[ -n "$locale" ]] || return 1
    [[ -f "$file" ]] || return 2
    awk -v loc="$locale" '
        { probe = $0
          sub(/^#[[:space:]]*/, "", probe)
          split(probe, f, /[[:space:]]+/)
          if (f[1] == loc) { found = 1; exit }
        }
        END { exit(found ? 0 : 1) }
    ' "$file"
}

# link_timezone <zoneinfo-dir> <tz> <localtime-path>
#
# -f, not -e: /usr/share/zoneinfo/America is a directory, and "America" is the
# obvious half-typed form of the default "America/Sao_Paulo". Linking
# /etc/localtime at a directory leaves the clock on UTC and says nothing.
link_timezone() {
    local zoneinfo=$1 tz=$2 localtime=$3 src
    src="${zoneinfo}/${tz}"
    if [[ ! -f "$src" ]]; then
        error "link_timezone: no such timezone: ${src}"
        return 1
    fi
    # -n matters on the retry, not the first run: if /etc/localtime is already
    # a symlink to a *directory*, plain `ln -sf` dereferences it and creates
    # the new link inside that directory instead, fails, and every subsequent
    # attempt dies on the same line until someone removes /etc/localtime.
    if ! ln -sfn "$src" "$localtime"; then
        error "link_timezone: failed to link ${localtime} -> ${src}"
        return 1
    fi
}

# --- host probes -----------------------------------------------------------

detect_ucode() {
    if grep -qi 'GenuineIntel' /proc/cpuinfo; then echo "intel-ucode"; else echo "amd-ucode"; fi
}

# Every console keymap this host knows, one per line. Non-zero when it cannot
# say -- callers distinguish "no such keymap" from "cannot enumerate keymaps".
#
# localectl is the documented interface but talks to systemd-localed over dbus;
# the kbd tree it reads is the fallback for a console where that is not up.
list_keymaps() {
    local out
    out=$(localectl list-keymaps --no-pager 2>/dev/null) || out=""
    if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
        return 0
    fi
    out=$(find /usr/share/kbd/keymaps -type f -name '*.map*' -printf '%f\n' 2>/dev/null \
          | sed -e 's/\.map\(\.gz\)\?$//' | sort -u) || out=""
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

# ICMP is filtered on plenty of networks, and "no internet connection" on a host
# that can reach the mirrors perfectly well is a dead end for the operator. Fall
# back to the HTTPS the installer actually needs.
net_check() {
    ping -c1 -W3 archlinux.org >/dev/null 2>&1 && return 0
    command -v curl >/dev/null 2>&1 || return 1
    curl -sSf --max-time 10 -o /dev/null https://archlinux.org/
}

detect_gpu() {
    local vga
    vga=$(lspci -mm 2>/dev/null | grep -iE 'VGA|3D controller' || true)
    case "${vga,,}" in
        *nvidia*) echo nvidia ;;
        *"advanced micro devices"*|*amd*|*ati*) echo amd ;;
        *intel*) echo intel ;;
        *) echo none ;;
    esac
}

# True (0) when GRUB still needs installing. Takes the ESP mountpoint.
needs_grub_install() {
    local esp=${1:-/boot}
    [[ -f "${esp}/EFI/GRUB/grubx64.efi" ]] && return 1
    return 0
}

# --- host actions (root, no sudo -- stage 1) --------------------------------
#
# These change the host rather than report on it: one syncs the pacman database
# and installs a package, the other overwrites /etc/pacman.d/mirrorlist. Split
# out of "host probes" above so that scanning the section tells you which it
# is. Distinct from "subsystem setup" below too: that runs in stage 2 through
# sudo, these run in stage 1 as root on the live ISO, where there is no sudo.

# Refresh the package-signing keyring before anything is installed from a
# mirror. Fatal for the caller: this fails often enough to matter on an ISO a
# few months old, and pacstrap several phases later would then fail with
# signature errors that read like a corrupt mirror.
#
# pacman's output goes to a temp file and is printed only on failure. Sending
# it to /dev/null -- which is what this did before -- leaves the operator an
# exit code and nothing to read; letting it through buries the caller's phase
# banner under progress bars.
refresh_keyring() {
    local log rc=0
    info "Refreshing the keyring..."
    log=$(mktemp) || {
        error "refresh_keyring: cannot create a temp file for pacman's output"
        return 1
    }
    pacman -Sy --noconfirm archlinux-keyring >"$log" 2>&1 || rc=$?
    if (( rc != 0 )); then
        error "refreshing archlinux-keyring failed:"
        cat "$log" >&2
    fi
    rm -f "$log"
    return "$rc"
}

# Rank the mirrorlist by download rate. Never fatal, and deliberately so: the
# ISO ships a working mirrorlist, so a reflector that is missing or cannot
# reach the mirror-status API costs speed, not correctness.
#
# It does have to be *said*, though. Both of those used to be silent, and
# pacstrapping from an unranked mirrorlist looks exactly like a hung phase.
rank_mirrors() {
    if ! command -v reflector >/dev/null 2>&1; then
        warn "reflector is not installed; keeping the ISO's mirrorlist"
        return 0
    fi
    info "Ranking mirrors with reflector..."
    if ! reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist >/dev/null 2>&1; then
        warn "reflector failed; keeping the ISO's mirrorlist"
    fi
}

