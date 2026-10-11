#!/bin/bash
# Shared transforms, host probes and host actions. Both stages source this.
# Requires lib/ui.sh. The two host actions at the bottom additionally require
# lib/disk.sh's run_cmd, which install.sh sources before this file; stage 2
# (provision.sh) sources neither disk.sh nor those two, and a call added there
# would find run_cmd undefined and exit 127.
#
# The sudo-requiring, stage-2-only setup_* family used to sit at the bottom of
# this file and now lives in lib/setup.sh, because it violates every rule the
# COUPLING block below states -- by design, and irreconcilably. Nothing may be
# added back here that runs sudo or reads ARCH_SETUP_DIR.
#
# COUPLING: everything in this file -- hooks_line,
# modules_line, gpu_packages, require_vars, grub_cmdline_add,
# locale_gen_uncomment, locale_listed, link_timezone, detect_ucode, detect_gpu,
# needs_grub_install, list_keymaps, net_check
# -- is a candidate for injection into the generated chroot
# script. Everything, that is, except the two host actions at the bottom, which
# the section header there explains are excluded. lib/chroot.sh's
# CHROOT_INJECTED currently takes seven of the candidates
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

# Which initramfs a HOOKS line builds: "systemd" when the systemd hook is
# present, "udev" otherwise.
#
# This distinction is load-bearing and was missed for the whole of this
# project's life, because every fixture assumed the udev-era default. A
# current Arch ISO ships
#   HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)
# and the two initramfs do not share a LUKS mechanism: sd-encrypt ignores
# cryptdevice=, encrypt ignores rd.luks.name=. Pairing them wrongly produces an
# image that prompts for no passphrase and leaves systemd waiting on
# /dev/mapper/cryptroot until it drops to an emergency shell that a locked root
# account cannot even log into. Observed end to end in the VM.
initramfs_flavor() {
    local line=$1 inner hooks=()
    inner=${line#*\(}; inner=${inner%\)*}
    read -ra hooks <<< "$inner"
    if printf '%s\n' "${hooks[@]}" | grep -qx systemd; then
        echo systemd
    else
        echo udev
    fi
}

# The LUKS hook that matches a flavour.
luks_hook() {
    case "$1" in
        systemd) echo sd-encrypt ;;
        udev)    echo encrypt ;;
        *)       error "luks_hook: unknown initramfs flavour: '$1'"; return 1 ;;
    esac
}

# The kernel parameter that matches a flavour. Refuses an unrecognised flavour
# rather than defaulting: a wrong guess here is an unbootable system, and the
# two spellings differ in separator as well as name -- rd.luks.name takes
# UUID=NAME with an '=', cryptdevice takes UUID=...:NAME with a ':'.
crypt_cmdline() {
    local flavor=$1 uuid=$2
    case "$flavor" in
        systemd) echo "rd.luks.name=${uuid}=cryptroot" ;;
        udev)    echo "cryptdevice=UUID=${uuid}:cryptroot" ;;
        *)       error "crypt_cmdline: unknown initramfs flavour: '$flavor'"; return 1 ;;
    esac
}

# hooks_line "HOOKS=(...)" <want_encrypt> -> new HOOKS line
hooks_line() {
    local line=$1 want_encrypt=$2 inner hooks=() out=() h flavor hook
    inner=${line#*\(}; inner=${inner%\)*}
    read -ra hooks <<< "$inner"

    printf '%s\n' "${hooks[@]}" | grep -qx filesystems \
        || { error "hooks_line: no 'filesystems' hook in: $line"; return 1; }

    flavor=$(initramfs_flavor "$line")
    hook=$(luks_hook "$flavor") || return 1

    for h in "${hooks[@]}"; do
        # Any LUKS hook already present is dropped here and the correct one
        # re-inserted below. Adding sd-encrypt while leaving encrypt in place
        # would still boot to the timeout, so this replaces rather than
        # appends -- and it is what makes the function idempotent and
        # self-healing on a config a previous version got wrong.
        [[ "$h" == encrypt || "$h" == sd-encrypt ]] && continue
        # the LUKS hook must come before filesystems, and only once
        if [[ "$h" == "filesystems" && "$want_encrypt" == true ]]; then
            out+=("$hook")
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

# grub_cmdline_remove <file> <key> -- drop every token whose key is <key>.
#
# Needed because switching initramfs flavour changes the *name* of the LUKS
# parameter, not just its value: grub_cmdline_add only replaces prior values of
# the key it is given, so adding rd.luks.name= leaves any cryptdevice= sitting
# beside it. The stale one is inert on the new initramfs, but it reads as
# intent to whoever debugs this next, and two contradictory LUKS parameters on
# one command line is precisely the confusion that cost this project an
# afternoon.
grub_cmdline_remove() {
    local file=$1 key=$2 current new=() tokens=() t

    grep -qE '^GRUB_CMDLINE_LINUX="[^"]*"[[:space:]]*$' "$file" \
        || { error "grub_cmdline_remove: ${file} has no double-quoted GRUB_CMDLINE_LINUX line"; return 1; }
    current=$(grep -oP '(?<=^GRUB_CMDLINE_LINUX=").*(?="$)' "$file" || echo "")
    read -ra tokens <<< "$current"
    for t in "${tokens[@]}"; do
        [[ "${t%%=*}" == "$key" ]] && continue
        new+=("$t")
    done
    sed -i "s|^GRUB_CMDLINE_LINUX=\".*\"$|GRUB_CMDLINE_LINUX=\"${new[*]}\"|" "$file"
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

# True (0) when GRUB still needs installing. Takes the ESP mountpoint, the
# bootloader id and whether the install is a --removable one, defaulting to
# /boot, GRUB and false.
#
# The id is a parameter because a second install on a shared ESP uses its own
# vendor directory. Hardcoding GRUB meant the check was satisfied by *any*
# GRUB on the ESP -- so a second install skipped grub-install entirely and then
# wrote a grub.cfg the first install's binary would load, quietly replacing its
# menu.
#
# This is only half the fix. Parameterising the id stops a *different* id from
# being mistaken for ours; it does nothing about our id already being taken by
# somebody else, which is what bootloader_id_free is for -- phase 3 must call
# that before phase 5 relies on this.
#
# The removable flag is the third parameter because --removable overrides
# --bootloader-id: upstream's util/grub-install.c sets the EFI distributor to
# "BOOT" when it is given, so the install writes \EFI\BOOT\BOOTX64.EFI and
# creates no vendor directory at all. Asking after EFI/<id>/grubx64.efi in
# that mode answers a question about a file the mode never writes -- it says
# "needs install" on every run, or worse matches an EFI/<id> that belongs to
# somebody else and skips the grub-install this install depends on.
#
# The two paths are deliberately not both checked in either mode. Outside
# removable mode the fallback binary is commonly another operating system's
# only bootloader, and reading it as ours skips grub-install for an install
# that then has none; inside removable mode the vendor directory cannot be
# ours. Only the literal "true" is removable, matching how lib/chroot.sh's
# preflight and its bootloader block read GRUB_REMOVABLE.
#
# In removable mode this is a weaker test than the vendor-directory one: the
# fallback path is a single well-known name and nothing on the ESP says who
# wrote it. It is safe here only because GRUB_REMOVABLE is true solely on the
# then-branch of an ask_yes_no over an `offer-*` verdict, and removable_policy
# returns `forbid` whenever a fallback binary already exists -- so a fallback
# binary seen from this function was written by this install.
needs_grub_install() {
    local esp=${1:-/boot} id=${2:-GRUB} removable=${3:-false}
    if [[ "$removable" == "true" ]]; then
        [[ -f "${esp}/EFI/BOOT/BOOTX64.EFI" ]] && return 1
        return 0
    fi
    [[ -f "${esp}/EFI/${id}/grubx64.efi" ]] && return 1
    return 0
}

# --- host actions (root, no sudo -- stage 1) --------------------------------
#
# These change the host rather than report on it: one syncs the pacman database
# and installs a package, the other overwrites /etc/pacman.d/mirrorlist. Split
# out of "host probes" above so that scanning the section tells you which it
# is. Distinct from "subsystem setup" below too: that runs in stage 2 through
# sudo, these run in stage 1 as root on the live ISO, where there is no sudo.
#
# Being the only writers here, they are also the only two functions in this
# file that call run_cmd and read DRY_RUN, so they are the two the COUPLING
# block above no longer lists as injectable: the generated chroot script
# defines neither name and runs under `set -u`. That gate is not optional. On
# the ISO these targets are tmpfs, but a rehearsal is run on an installed Arch
# host, where ungated they would re-sync that host's keyring and overwrite its
# /etc/pacman.d/mirrorlist -- a --dry-run that changes the machine it is
# rehearsing on.

# Refresh the package-signing keyring before anything is installed from a
# mirror. Fatal for the caller: this fails often enough to matter on an ISO a
# few months old, and pacstrap several phases later would then fail with
# signature errors that read like a corrupt mirror.
#
# pacman's output goes to a temp file and is printed only on failure. Sending
# it to /dev/null -- which is what this did before -- leaves the operator an
# exit code and nothing to read; letting it through buries the caller's phase
# banner under progress bars.
#
# Under --dry-run it returns 0 despite refreshing nothing, and that is not the
# fatality above going soft: what makes a failure fatal is the pacstrap several
# phases later, and a rehearsal performs none. Failing here would stop the
# rehearsal at the first phase it exists to exercise.
refresh_keyring() {
    # One array for both paths so the command printed under --dry-run cannot
    # drift from the one a real run issues.
    local -a cmd=(pacman -Sy --noconfirm archlinux-keyring)
    local log rc=0
    info "Refreshing the keyring..."
    if [[ "$DRY_RUN" == true ]]; then
        # Not `run_cmd "${cmd[@]}" >"$log"`: the redirection below is the real
        # path's, and applying it here would send run_cmd's own [dry-run] line
        # into a temp file that is printed only on a failure that cannot
        # happen, i.e. nowhere. No temp file is created on this path either.
        run_cmd "${cmd[@]}"
        return 0
    fi
    log=$(mktemp) || {
        error "refresh_keyring: cannot create a temp file for pacman's output"
        return 1
    }
    "${cmd[@]}" >"$log" 2>&1 || rc=$?
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
# Which is why the absent-reflector warning below still fires under --dry-run:
# it is a fact about the host, and the one case with no command to withhold.
rank_mirrors() {
    # As in refresh_keyring: one array, so --dry-run cannot print a command a
    # real run would not issue.
    local -a cmd=(reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist)
    if ! command -v reflector >/dev/null 2>&1; then
        warn "reflector is not installed; keeping the ISO's mirrorlist"
        return 0
    fi
    info "Ranking mirrors with reflector..."
    if [[ "$DRY_RUN" == true ]]; then
        # Again not `run_cmd ... >/dev/null 2>&1`, which would discard the
        # [dry-run] line the rehearsal exists to show. Still never fatal.
        run_cmd "${cmd[@]}"
        return 0
    fi
    if ! "${cmd[@]}" >/dev/null 2>&1; then
        warn "reflector failed; keeping the ISO's mirrorlist"
    fi
}

