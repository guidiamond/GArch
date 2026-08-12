#!/bin/bash
# One idempotent function per subsystem. Requires lib/ui.sh.
# shellcheck shell=bash

# Arch no longer ships the proprietary nvidia/nvidia-dkms packages -- only the
# open modules. Pre-Turing cards need an AUR nvidia-<branch>xx-dkms and are out
# of scope here.
GPU_NVIDIA=(nvidia-open-dkms nvidia-utils nvidia-settings)
GPU_AMD=(xf86-video-amdgpu mesa vulkan-radeon)
GPU_INTEL=(mesa vulkan-intel intel-media-driver)

# --- pure transforms -------------------------------------------------------

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

# grub_cmdline_add <file> key=value  -- idempotent, replaces a changed value
grub_cmdline_add() {
    local file=$1 kv=$2 key=${2%%=*} current new tokens=() t
    current=$(grep -oP '(?<=^GRUB_CMDLINE_LINUX=").*(?="$)' "$file" || echo "")
    read -ra tokens <<< "$current"
    new=()
    for t in "${tokens[@]}"; do
        [[ "${t%%=*}" == "$key" ]] && continue   # drop any prior value for this key
        new+=("$t")
    done
    new+=("$kv")
    sed -i "s|^GRUB_CMDLINE_LINUX=\".*\"$|GRUB_CMDLINE_LINUX=\"${new[*]}\"|" "$file"
}

detect_ucode() {
    if grep -qi 'GenuineIntel' /proc/cpuinfo; then echo "intel-ucode"; else echo "amd-ucode"; fi
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

gpu_packages() {
    case "$1" in
        nvidia) echo "${GPU_NVIDIA[*]}" ;;
        amd)    echo "${GPU_AMD[*]}" ;;
        intel)  echo "${GPU_INTEL[*]}" ;;
        *)      echo "" ;;
    esac
}
