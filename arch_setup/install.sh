#!/bin/bash
# ============================================================
# Arch Linux Interactive Installer
# ============================================================
# Usage:
#   curl -sLO https://raw.githubusercontent.com/guidiamond/.dotfiles/master/arch_setup/install.sh
#   chmod +x install.sh && ./install.sh
# ============================================================

set -euo pipefail

# ===================== CONFIGURATION ========================

DOTFILES_REPO="https://github.com/guidiamond/.dotfiles.git"
DEFAULT_HOSTNAME="archlinux"
DEFAULT_USERNAME="arch"
DEFAULT_KEYMAP="us"
DEFAULT_LOCALE="en_US.UTF-8"
DEFAULT_TIMEZONE="America/Sao_Paulo"
MAX_SWAP_GB=8

# Base packages for pacstrap
BASE_PACKAGES=(
    base linux linux-firmware base-devel
    networkmanager grub vim sudo git stow zsh
)
UEFI_PACKAGES=(efibootmgr dosfstools)

# Packages to install via yay post-install (from yay_deps.txt)
YAY_PACKAGES=(
    alacritty
    arandr
    aws-cli-v2
    brave-bin
    bspwm
    chromium
    ctags
    cups-pdf
    devour-git
    discord
    dmenu
    docker
    docker-compose
    dosfstools
    dragon-drop-git
    droidcam
    electron
    etcher-bin
    fd
    feh
    ferdium-bin
    flameshot
    fzf
    gcc
    gettext
    gimp
    git
    github-cli
    gnome-keyring
    gparted
    grep
    gzip
    htop
    insomnia
    isync
    kitty
    lazygit
    lightdm
    lightdm-webkit2-greeter
    lsd
    lshw
    lsof
    msmtp
    mtools
    mutt-wizard-git
    neomutt
    neovim-git
    ttf-nerd-fonts-symbols
    network-manager-applet
    networkmanager-openvpn
    notion-app
    ntfs-3g
    nvm
    obs-studio
    okular
    openconnect
    openvpn
    os-prober
    pass
    pavucontrol
    perl-file-mimeinfo
    picom
    playerctl
    polybar
    postman-bin
    pulseaudio-alsa
    python-pip
    python-virtualenv
    qt5ct
    ranger
    ripgrep
    rofi
    rofi-calc
    rsync
    scrot
    sed
    siji-git
    simplescreenrecorder
    spotify
    stow
    sxhkd
    svn
    terraform
    tmux
    ttf-bitstream-vera
    ttf-fira-code
    ttf-font-awesome
    ttf-icomoon-feather
    ttf-unifont
    unzip
    urlview
    v4l2loopback-dkms
    vim
    visual-studio-code-bin
    vlc
    watchman-bin
    which
    whois
    xclip
    xdotool
    xorg-server
    xorg-server-common
    xorg-xinit
    xorg-xinput
    xorg-xrandr
    xorg-xsetroot
    xorg-setxkbmap
    xorg-xauth
    xorg-xev
    xorg-xkill
    xorg-xprop
    xorg-xwininfo
    xorg-xhost
    xournalpp
    zip
    zsh
    zsh-theme-powerlevel10k-git
    1password
    datagrip
)

# Packages known to be broken/renamed — skip these
SKIP_PACKAGES=(teams nerd-fonts-complete mongodb-bin mongodb-tools-bin robo3t-bin ueberzug xmobar xmonad xmonad-contrib)

# GPU driver package sets
GPU_NVIDIA=(nvidia nvidia-utils nvidia-settings)
GPU_AMD=(xf86-video-amdgpu mesa vulkan-radeon)
GPU_INTEL=(xf86-video-intel mesa vulkan-intel)

# Services to enable
SERVICES=(NetworkManager lightdm docker bluetooth cups)

# ===================== RUNTIME STATE ========================

BOOT_MODE=""         # uefi or bios
TARGET_DISK=""
PART_EFI=""
PART_SWAP=""
PART_ROOT=""
PART_HOME=""
PART_TMP=""
FORMAT_EFI=false
FORMAT_SWAP=false
FORMAT_ROOT=false
FORMAT_HOME=false
FORMAT_TMP=false
SEPARATE_HOME=false
SEPARATE_TMP=false
DUAL_BOOT=false
SWAP_SIZE_GB=""
KEYMAP=""
LOCALE=""
TIMEZONE=""
HOSTNAME_VAR=""
USERNAME_VAR=""
USER_PASSWORD=""
ROOT_PASSWORD=""
GPU_CHOICE=""
TOTAL_PHASES=6

# ===================== UI LIBRARY ===========================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

banner() {
    local phase=$1 total=$2 title=$3
    local line
    line=$(printf '═%.0s' {1..50})
    echo ""
    echo -e "${CYAN}${BOLD}${line}${RESET}"
    echo -e "${CYAN}${BOLD}  [$phase/$total] $title${RESET}"
    echo -e "${CYAN}${BOLD}${line}${RESET}"
    echo ""
}

info()    { echo -e "${BLUE}[*]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }

ask() {
    local prompt=$1 default=${2:-}
    local input
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${BOLD}$prompt${RESET} [$default]: ")" input
        echo "${input:-$default}"
    else
        read -rp "$(echo -e "${BOLD}$prompt${RESET}: ")" input
        echo "$input"
    fi
}

ask_yes_no() {
    local prompt=$1 default=${2:-y}
    local input
    local hint
    if [[ "$default" == "y" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi
    while true; do
        read -rp "$(echo -e "${BOLD}$prompt${RESET} $hint: ")" input
        input="${input:-$default}"
        case "${input,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) warn "Please answer y or n." ;;
        esac
    done
}

ask_password() {
    local varname=$1 prompt=${2:-"Password"}
    local pass1 pass2
    while true; do
        read -rsp "$(echo -e "${BOLD}$prompt${RESET}: ")" pass1
        echo ""
        read -rsp "$(echo -e "${BOLD}Confirm $prompt${RESET}: ")" pass2
        echo ""
        if [[ "$pass1" == "$pass2" ]]; then
            if [[ -z "$pass1" ]]; then
                warn "Password cannot be empty."
                continue
            fi
            eval "$varname=\"\$pass1\""
            return 0
        else
            warn "Passwords do not match. Try again."
        fi
    done
}

ask_choice() {
    local prompt=$1
    shift
    local options=("$@")
    local i

    echo -e "${BOLD}$prompt${RESET}"
    for i in "${!options[@]}"; do
        echo "  $((i + 1))) ${options[$i]}"
    done

    local choice
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
    local pid=$1 message=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        local c="${spin:i++%${#spin}:1}"
        printf "\r${BLUE}%s${RESET} %s" "$c" "$message"
        sleep 0.1
    done
    printf "\r"
}

confirm_step() {
    local description=$1
    echo ""
    echo -e "${BOLD}Summary:${RESET}"
    echo "$description"
    echo ""
    if ! ask_yes_no "Proceed?"; then
        error "Aborted by user."
        exit 1
    fi
}

# ===================== VALIDATORS ===========================

validate_hostname() {
    local name=$1
    if [[ ${#name} -lt 1 || ${#name} -gt 63 ]]; then
        return 1
    fi
    if [[ ! "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        return 1
    fi
    return 0
}

validate_username() {
    local name=$1
    if [[ ! "$name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        return 1
    fi
    return 0
}

validate_disk() {
    local disk=$1
    if [[ ! -b "$disk" ]]; then
        return 1
    fi
    return 0
}

is_uefi() {
    [[ -d /sys/firmware/efi ]]
}

check_internet() {
    ping -c 1 -W 3 archlinux.org &>/dev/null
}

check_live_iso() {
    [[ -d /run/archiso ]]
}

# ===================== DISK FUNCTIONS =======================

list_disks() {
    lsblk -dpno NAME,SIZE,MODEL | grep -v -E 'loop|sr[0-9]|rom|airoot'
}

list_partitions() {
    echo ""
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT -p | grep -v -E 'loop|sr[0-9]|rom'
    echo ""
}

get_swap_size() {
    local ram_kb ram_gb swap_gb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ram_gb=$(( (ram_kb + 1048575) / 1048576 ))

    if (( ram_gb <= 2 )); then
        swap_gb=$((ram_gb * 2))
    elif (( ram_gb <= 8 )); then
        swap_gb=$ram_gb
    else
        swap_gb=$(( ram_gb / 2 ))
    fi

    if (( swap_gb > MAX_SWAP_GB )); then
        swap_gb=$MAX_SWAP_GB
    fi
    if (( swap_gb < 1 )); then
        swap_gb=1
    fi
    echo "$swap_gb"
}

get_partition_suffix() {
    local disk=$1
    # NVMe drives use p1, p2, etc.; SATA drives use 1, 2, etc.
    if [[ "$disk" =~ nvme|mmcblk|loop ]]; then
        echo "p"
    else
        echo ""
    fi
}

# --- Plan-based auto partitioning (supports multiple disks) ---
#
# The partition plan is an array of "disk|role|type_code|label|size" entries.
# Roles: efi, bios_boot, swap, root, home, tmp
# Size: "512M", "4G", "rest", etc. "rest" = use remaining space (sgdisk 0:0).
#
# The plan is built by phase_disk_auto, displayed for confirmation, then
# executed by execute_partition_plan which groups entries by disk.

PART_PLAN=()

add_plan_entry() {
    PART_PLAN+=("$1|$2|$3|$4|$5")
}

pick_disk() {
    local label=$1 default=${2:-}
    local disk
    while true; do
        disk=$(ask "$label" "$default")
        if validate_disk "$disk"; then
            echo "$disk"
            return 0
        fi
        warn "'$disk' is not a valid block device."
    done
}

# Show the plan grouped by disk
display_partition_plan() {
    # Collect unique disks in order
    local seen_disks=()
    local entry disk role type_code label size
    for entry in "${PART_PLAN[@]}"; do
        IFS='|' read -r disk role type_code label size <<< "$entry"
        local found=false
        local d
        for d in "${seen_disks[@]}"; do
            if [[ "$d" == "$disk" ]]; then found=true; break; fi
        done
        if [[ "$found" == false ]]; then
            seen_disks+=("$disk")
        fi
    done

    for disk in "${seen_disks[@]}"; do
        local disk_size
        disk_size=$(lsblk -dnpo SIZE "$disk" 2>/dev/null | xargs)
        echo ""
        warn "$disk ($disk_size) — WILL BE WIPED"
        local suffix n
        suffix=$(get_partition_suffix "$disk")
        n=0
        for entry in "${PART_PLAN[@]}"; do
            local e_disk e_role e_type e_label e_size
            IFS='|' read -r e_disk e_role e_type e_label e_size <<< "$entry"
            [[ "$e_disk" != "$disk" ]] && continue
            n=$((n + 1))
            local display_size="$e_size"
            [[ "$e_size" == "rest" ]] && display_size="rest"
            printf "    %s%-3s  %-6s  %s\n" "${disk}${suffix}" "${n}" "$display_size" "$e_label"
        done
    done
}

# Execute the plan: wipe each disk and create its partitions
execute_partition_plan() {
    # Collect unique disks in order
    local seen_disks=()
    local entry disk
    for entry in "${PART_PLAN[@]}"; do
        IFS='|' read -r disk _ _ _ _ <<< "$entry"
        local found=false
        local d
        for d in "${seen_disks[@]}"; do
            if [[ "$d" == "$disk" ]]; then found=true; break; fi
        done
        if [[ "$found" == false ]]; then
            seen_disks+=("$disk")
        fi
    done

    for disk in "${seen_disks[@]}"; do
        info "Partitioning $disk..."
        sgdisk --zap-all "$disk"

        local suffix n
        suffix=$(get_partition_suffix "$disk")
        n=0

        for entry in "${PART_PLAN[@]}"; do
            local e_disk e_role e_type e_label e_size
            IFS='|' read -r e_disk e_role e_type e_label e_size <<< "$entry"
            [[ "$e_disk" != "$disk" ]] && continue

            n=$((n + 1))
            local size_flag
            if [[ "$e_size" == "rest" ]]; then
                size_flag="0"
            else
                size_flag="+${e_size}"
            fi

            sgdisk -n "${n}:0:${size_flag}" -t "${n}:${e_type}" -c "${n}:${e_label}" "$disk"

            local partdev="${disk}${suffix}${n}"
            case "$e_role" in
                efi)       PART_EFI="$partdev";  FORMAT_EFI=true ;;
                swap)      PART_SWAP="$partdev"; FORMAT_SWAP=true ;;
                root)      PART_ROOT="$partdev"; FORMAT_ROOT=true ;;
                home)      PART_HOME="$partdev"; FORMAT_HOME=true; SEPARATE_HOME=true ;;
                tmp)       PART_TMP="$partdev";  FORMAT_TMP=true;  SEPARATE_TMP=true ;;
                bios_boot) ;; # not mounted, GRUB embeds directly
            esac
        done

        partprobe "$disk"
        sleep 1
        success "Partitioned $disk"
    done
}

# --- Partition selection helper (for manual mode) ---

pick_partition() {
    local label=$1 allow_skip=${2:-false}
    local part

    while true; do
        if [[ "$allow_skip" == true ]]; then
            part=$(ask "$label (e.g. /dev/sda1, or 'skip')")
        else
            part=$(ask "$label (e.g. /dev/sda1)")
        fi

        if [[ "$allow_skip" == true && "$part" == "skip" ]]; then
            echo ""
            return 0
        fi

        if [[ -b "$part" ]]; then
            echo "$part"
            return 0
        fi
        warn "'$part' is not a valid block device."
    done
}

ask_format() {
    local part=$1 label=$2
    local fstype
    fstype=$(lsblk -no FSTYPE "$part" 2>/dev/null || true)

    if [[ -n "$fstype" ]]; then
        info "$part currently has filesystem: $fstype"
        if ask_yes_no "Format $part? (WARNING: destroys existing data)" "n"; then
            return 0
        fi
        return 1
    else
        info "$part has no filesystem"
        if ask_yes_no "Format $part?" "y"; then
            return 0
        fi
        return 1
    fi
}

# --- Format & mount ---

format_partitions() {
    if [[ "$FORMAT_EFI" == true && -n "$PART_EFI" ]]; then
        info "Formatting EFI partition ($PART_EFI) as FAT32..."
        mkfs.fat -F32 "$PART_EFI"
    fi

    if [[ "$FORMAT_SWAP" == true && -n "$PART_SWAP" ]]; then
        info "Formatting swap ($PART_SWAP)..."
        mkswap "$PART_SWAP"
    fi

    if [[ "$FORMAT_ROOT" == true ]]; then
        info "Formatting root ($PART_ROOT) as ext4..."
        mkfs.ext4 -F "$PART_ROOT"
    fi

    if [[ "$FORMAT_HOME" == true && -n "$PART_HOME" ]]; then
        info "Formatting home ($PART_HOME) as ext4..."
        mkfs.ext4 -F "$PART_HOME"
    fi

    if [[ "$FORMAT_TMP" == true && -n "$PART_TMP" ]]; then
        info "Formatting tmp ($PART_TMP) as ext4..."
        mkfs.ext4 -F "$PART_TMP"
    fi
}

mount_partitions() {
    info "Mounting partitions..."
    mount "$PART_ROOT" /mnt

    if [[ -n "$PART_HOME" ]]; then
        mkdir -p /mnt/home
        mount "$PART_HOME" /mnt/home
    fi

    if [[ -n "$PART_TMP" ]]; then
        mkdir -p /mnt/tmp
        mount "$PART_TMP" /mnt/tmp
    fi

    if [[ -n "$PART_EFI" ]]; then
        mkdir -p /mnt/boot/efi
        mount "$PART_EFI" /mnt/boot/efi
    fi

    if [[ -n "$PART_SWAP" ]]; then
        swapon "$PART_SWAP"
    fi
}

# ===================== CLEANUP / ERROR HANDLING =============

cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        echo ""
        error "Installation failed (exit code: $exit_code)"
        error "You can check the state and try to recover manually."
    fi
    # Attempt cleanup
    swapoff -a 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true
}

trap cleanup EXIT

err_handler() {
    local lineno=$1 cmd=$2
    error "Command failed at line $lineno: $cmd"
}

trap 'err_handler ${LINENO} "$BASH_COMMAND"' ERR

# ===================== PHASE 0: PRE-FLIGHT ==================

phase_preflight() {
    banner 1 "$TOTAL_PHASES" "Pre-flight Checks"

    echo -e "${CYAN}${BOLD}"
    cat << 'LOGO'
     _             _       _     _
    / \   _ __ ___| |__   | |   (_)_ __  _   ___  __
   / _ \ | '__/ __| '_ \  | |   | | '_ \| | | \ \/ /
  / ___ \| | | (__| | | | | |___| | | | | |_| |>  <
 /_/   \_\_|  \___|_| |_| |_____|_|_| |_|\__,_/_/\_\

      Interactive Installer
LOGO
    echo -e "${RESET}"

    # Check live ISO
    if check_live_iso; then
        success "Running from Arch live ISO"
    else
        warn "Not running from an Arch live ISO. Proceed with caution!"
        if ! ask_yes_no "Continue anyway?" "n"; then
            exit 1
        fi
    fi

    # Detect boot mode
    if is_uefi; then
        BOOT_MODE="uefi"
        success "UEFI mode detected"
    else
        BOOT_MODE="bios"
        success "BIOS/Legacy mode detected"
    fi

    # Check internet
    info "Checking internet connection..."
    if check_internet; then
        success "Internet connection OK"
    else
        warn "No internet connection detected."
        info "If using Wi-Fi, you can connect with: iwctl station wlan0 connect <SSID>"
        if ! ask_yes_no "Retry after connecting?" "y"; then
            error "Internet is required. Exiting."
            exit 1
        fi
        if ! check_internet; then
            error "Still no internet. Exiting."
            exit 1
        fi
        success "Internet connection OK"
    fi

    # Sync time
    info "Enabling NTP time sync..."
    timedatectl set-ntp true

    # Refresh keyring
    info "Refreshing pacman keyring..."
    pacman -Sy --noconfirm archlinux-keyring &>/dev/null &
    spinner $! "Updating keyring..."
    success "Keyring updated"

    confirm_step "  Boot mode: $BOOT_MODE
  Internet:  connected
  Time sync: enabled"
}

# ===================== PHASE 1: LOCALE & KEYBOARD ===========

phase_locale() {
    banner 2 "$TOTAL_PHASES" "Locale & Keyboard"

    # Keyboard layout
    KEYMAP=$(ask "Keyboard layout" "$DEFAULT_KEYMAP")
    loadkeys "$KEYMAP" 2>/dev/null || warn "Could not load keymap '$KEYMAP', continuing with default"

    # Locale
    LOCALE=$(ask "System locale" "$DEFAULT_LOCALE")

    # Timezone
    info "Setting timezone..."
    local tz
    tz=$(ask "Timezone (e.g. America/Sao_Paulo, Europe/London)" "$DEFAULT_TIMEZONE")
    if [[ ! -f "/usr/share/zoneinfo/$tz" ]]; then
        warn "Timezone '$tz' not found. Available regions:"
        ls /usr/share/zoneinfo/ | grep -v -E '^(posix|right|+VERSION|leap)' | column
        tz=$(ask "Timezone" "$DEFAULT_TIMEZONE")
    fi
    TIMEZONE="$tz"

    confirm_step "  Keymap:   $KEYMAP
  Locale:   $LOCALE
  Timezone: $TIMEZONE"
}

# ===================== PHASE 2: DISK SETUP ==================

phase_disk_auto() {
    info "Available disks:"
    echo ""
    list_disks
    echo ""

    # --- Collect disk assignments for each role ---

    local disk_root disk_home disk_swap disk_tmp
    local want_home=false want_tmp=false want_swap=true

    # Root (required)
    disk_root=$(pick_disk "Disk for root (/)")
    # GRUB target = root disk (for BIOS mode)
    TARGET_DISK="$disk_root"

    # Home
    if ask_yes_no "Separate /home partition?" "n"; then
        want_home=true
        disk_home=$(pick_disk "Disk for home (/home)" "$disk_root")
    fi

    # Tmp
    if ask_yes_no "Separate /tmp partition?" "n"; then
        want_tmp=true
        disk_tmp=$(pick_disk "Disk for tmp (/tmp)" "$disk_root")
    fi

    # Swap
    if ask_yes_no "Create swap partition?" "y"; then
        want_swap=true
        disk_swap=$(pick_disk "Disk for swap" "$disk_root")
        local auto_swap
        auto_swap=$(get_swap_size)
        SWAP_SIZE_GB=$(ask "Swap size in GB" "$auto_swap")
    else
        want_swap=false
    fi

    # --- Build the partition plan ---
    PART_PLAN=()

    # For each disk, we need to know what roles it hosts and whether it's the
    # last role on that disk (last one gets "rest of disk").
    # We also need EFI/BIOS boot on the root disk.

    # Helper: count how many data roles (root/home/tmp) go on a given disk
    # so we know when to ask for explicit sizes vs "rest".
    local -A disk_data_count=()
    disk_data_count["$disk_root"]=$(( ${disk_data_count["$disk_root"]:-0} + 1 ))
    [[ "$want_home" == true ]] && disk_data_count["$disk_home"]=$(( ${disk_data_count["$disk_home"]:-0} + 1 ))
    [[ "$want_tmp" == true ]]  && disk_data_count["$disk_tmp"]=$(( ${disk_data_count["$disk_tmp"]:-0} + 1 ))

    # Track how many data roles we've added per disk (to know when we hit the last)
    local -A disk_data_added=()

    # Boot partition on root disk
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        add_plan_entry "$disk_root" "efi" "ef00" "EFI System" "512M"
    else
        add_plan_entry "$disk_root" "bios_boot" "ef02" "BIOS Boot" "1M"
    fi

    # Swap
    if [[ "$want_swap" == true ]]; then
        add_plan_entry "$disk_swap" "swap" "8200" "Swap" "${SWAP_SIZE_GB}G"
    fi

    # Root
    disk_data_added["$disk_root"]=$(( ${disk_data_added["$disk_root"]:-0} + 1 ))
    if (( disk_data_added["$disk_root"] >= disk_data_count["$disk_root"] )); then
        add_plan_entry "$disk_root" "root" "8300" "Root" "rest"
    else
        local root_size
        root_size=$(ask "Root (/) partition size" "50G")
        add_plan_entry "$disk_root" "root" "8300" "Root" "$root_size"
    fi

    # Home
    if [[ "$want_home" == true ]]; then
        disk_data_added["$disk_home"]=$(( ${disk_data_added["$disk_home"]:-0} + 1 ))
        if (( disk_data_added["$disk_home"] >= disk_data_count["$disk_home"] )); then
            add_plan_entry "$disk_home" "home" "8300" "Home" "rest"
        else
            local home_size
            home_size=$(ask "Home (/home) partition size" "100G")
            add_plan_entry "$disk_home" "home" "8300" "Home" "$home_size"
        fi
    fi

    # Tmp
    if [[ "$want_tmp" == true ]]; then
        disk_data_added["$disk_tmp"]=$(( ${disk_data_added["$disk_tmp"]:-0} + 1 ))
        if (( disk_data_added["$disk_tmp"] >= disk_data_count["$disk_tmp"] )); then
            add_plan_entry "$disk_tmp" "tmp" "8300" "Tmp" "rest"
        else
            local tmp_size
            tmp_size=$(ask "Tmp (/tmp) partition size" "10G")
            add_plan_entry "$disk_tmp" "tmp" "8300" "Tmp" "$tmp_size"
        fi
    fi

    # --- Display and confirm ---
    echo ""
    info "Partition plan:"
    display_partition_plan
    echo ""

    local confirm
    read -rp "$(echo -e "${RED}${BOLD}Type YES to confirm (all listed disks will be wiped)${RESET}: ")" confirm
    if [[ "$confirm" != "YES" ]]; then
        error "Aborted."
        exit 1
    fi

    # --- Execute ---
    execute_partition_plan
}

phase_disk_manual() {
    info "Current disk/partition layout:"
    list_partitions

    # Dual boot?
    if ask_yes_no "Is this a dual boot setup (e.g. with Windows)?" "n"; then
        DUAL_BOOT=true
        info "Dual boot mode: will enable os-prober and preserve existing bootloaders."
    fi

    # --- EFI partition (UEFI only) ---
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        echo ""
        info "--- EFI Partition (/boot/efi) ---"
        if [[ "$DUAL_BOOT" == true ]]; then
            info "For dual boot, you should reuse the existing EFI partition."
        fi
        PART_EFI=$(pick_partition "EFI partition")
        if ask_format "$PART_EFI" "EFI"; then
            FORMAT_EFI=true
            if [[ "$DUAL_BOOT" == true ]]; then
                warn "Formatting the EFI partition will remove other bootloaders!"
                if ! ask_yes_no "Are you sure?" "n"; then
                    FORMAT_EFI=false
                fi
            fi
        fi
    fi

    # --- Swap ---
    echo ""
    info "--- Swap Partition ---"
    local auto_swap
    auto_swap=$(get_swap_size)
    info "Recommended swap size: ${auto_swap}G"
    PART_SWAP=$(pick_partition "Swap partition" true)
    if [[ -n "$PART_SWAP" ]]; then
        if ask_format "$PART_SWAP" "swap"; then
            FORMAT_SWAP=true
        fi
    else
        info "Skipping swap."
    fi

    # --- Root ---
    echo ""
    info "--- Root Partition (/) ---"
    PART_ROOT=$(pick_partition "Root partition")
    if ask_format "$PART_ROOT" "root"; then
        FORMAT_ROOT=true
    fi

    # --- Home ---
    echo ""
    info "--- Home Partition (/home) ---"
    if ask_yes_no "Use a separate /home partition?" "n"; then
        SEPARATE_HOME=true
        PART_HOME=$(pick_partition "Home partition")
        if ask_format "$PART_HOME" "home"; then
            FORMAT_HOME=true
        fi
    fi

    # --- Tmp ---
    echo ""
    info "--- Tmp Partition (/tmp) ---"
    if ask_yes_no "Use a separate /tmp partition?" "n"; then
        SEPARATE_TMP=true
        PART_TMP=$(pick_partition "Tmp partition")
        if ask_format "$PART_TMP" "tmp"; then
            FORMAT_TMP=true
        fi
    fi

    # For GRUB install target (needed for BIOS grub-install --target=i386-pc /dev/sdX)
    if [[ "$BOOT_MODE" == "bios" ]]; then
        echo ""
        info "--- GRUB Target Disk ---"
        info "GRUB will be installed to the MBR/boot sector of a disk."
        while true; do
            TARGET_DISK=$(ask "Disk for GRUB (e.g. /dev/sda)" "$(echo "$PART_ROOT" | sed 's/[0-9]*$//' | sed 's/p$//')")
            if validate_disk "$TARGET_DISK"; then
                break
            fi
            warn "Invalid disk."
        done
    fi
}

phase_disk() {
    banner 3 "$TOTAL_PHASES" "Disk Setup"

    local mode
    mode=$(ask_choice "Partitioning mode:" \
        "Auto  - wipe entire disk, create all partitions" \
        "Manual - assign existing partitions (dual boot, multi-disk)")

    case "$mode" in
        Auto*)   phase_disk_auto ;;
        Manual*) phase_disk_manual ;;
    esac

    # Show summary
    echo ""
    info "Partition assignment:"
    [[ -n "$PART_EFI" ]]  && echo "  EFI:  $PART_EFI (format: $FORMAT_EFI)"
    [[ -n "$PART_SWAP" ]] && echo "  Swap: $PART_SWAP (format: $FORMAT_SWAP)"
    echo "  Root: $PART_ROOT (format: $FORMAT_ROOT)"
    [[ -n "$PART_HOME" ]] && echo "  Home: $PART_HOME (format: $FORMAT_HOME)"
    [[ -n "$PART_TMP" ]]  && echo "  Tmp:  $PART_TMP (format: $FORMAT_TMP)"
    [[ "$DUAL_BOOT" == true ]] && echo "  Dual boot: yes (os-prober enabled)"
    echo ""

    confirm_step "Proceed with formatting and mounting?"

    # Format
    format_partitions

    # Mount
    mount_partitions

    # Verify
    echo ""
    info "Mounted layout:"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT -p | grep -E '/mnt|MOUNTPOINT'
    echo ""
    success "Disk setup complete"
}

# ===================== PHASE 3: BASE INSTALL ================

phase_base_install() {
    banner 4 "$TOTAL_PHASES" "Base System Install"

    # Optional reflector
    if ask_yes_no "Optimize mirrors with reflector?" "y"; then
        info "Finding fastest mirrors..."
        if command -v reflector &>/dev/null; then
            reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist &
            spinner $! "Ranking mirrors..."
            success "Mirrors optimized"
        else
            pacman -Sy --noconfirm reflector &>/dev/null
            reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist &
            spinner $! "Ranking mirrors..."
            success "Mirrors optimized"
        fi
    fi

    # Pacstrap
    local packages=("${BASE_PACKAGES[@]}")
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        packages+=("${UEFI_PACKAGES[@]}")
    fi

    info "Installing base system..."
    echo "  Packages: ${packages[*]}"
    echo ""
    pacstrap -K /mnt "${packages[@]}"
    success "Base system installed"

    # Generate fstab
    info "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
    echo ""
    info "Generated /mnt/etc/fstab:"
    cat /mnt/etc/fstab
    echo ""

    confirm_step "  Base system installed at /mnt
  fstab generated"
}

# ===================== PHASE 4: CHROOT CONFIG ===============

phase_chroot_config() {
    banner 5 "$TOTAL_PHASES" "System Configuration"

    # Collect all user input before chroot
    while true; do
        HOSTNAME_VAR=$(ask "Hostname" "$DEFAULT_HOSTNAME")
        if validate_hostname "$HOSTNAME_VAR"; then
            break
        fi
        warn "Invalid hostname. Use 1-63 alphanumeric characters and hyphens."
    done

    while true; do
        USERNAME_VAR=$(ask "Username" "$DEFAULT_USERNAME")
        if validate_username "$USERNAME_VAR"; then
            break
        fi
        warn "Invalid username. Must start with lowercase letter, use [a-z0-9_-]."
    done

    ask_password ROOT_PASSWORD "Root password"
    ask_password USER_PASSWORD "Password for $USERNAME_VAR"

    # GPU choice
    echo ""
    GPU_CHOICE=$(ask_choice "GPU driver:" "nvidia" "amd" "intel" "none")

    # Build GPU package list
    local gpu_packages=""
    case "$GPU_CHOICE" in
        nvidia) gpu_packages="${GPU_NVIDIA[*]}" ;;
        amd)    gpu_packages="${GPU_AMD[*]}" ;;
        intel)  gpu_packages="${GPU_INTEL[*]}" ;;
        none)   gpu_packages="" ;;
    esac

    # Build skip list
    local skip_list="${SKIP_PACKAGES[*]}"

    # Build yay package list (filter out skipped packages)
    local yay_pkg_list=""
    for pkg in "${YAY_PACKAGES[@]}"; do
        local skip=false
        for s in "${SKIP_PACKAGES[@]}"; do
            if [[ "$pkg" == "$s" ]]; then
                skip=true
                break
            fi
        done
        if ! $skip; then
            yay_pkg_list+="$pkg "
        fi
    done

    # Build services list
    local services_list="${SERVICES[*]}"

    confirm_step "  Hostname:  $HOSTNAME_VAR
  Username:  $USERNAME_VAR
  GPU:       $GPU_CHOICE
  Services:  $services_list"

    info "Entering chroot to configure the system..."

    # Encode passwords in base64 to avoid quoting issues in heredoc
    local user_pass_b64 root_pass_b64
    user_pass_b64=$(echo -n "$USER_PASSWORD" | base64)
    root_pass_b64=$(echo -n "$ROOT_PASSWORD" | base64)

    # Generate the chroot script (quoted heredoc — no expansion, all literal)
    cat > /mnt/root/chroot_setup.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail

# Variables are passed via environment or sourced from the config file
# generated below. This script is self-contained once config is written.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${BLUE}[*]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }

# Source injected config
source /root/chroot_config.sh

# Decode passwords
USER_PASSWORD=$(echo -n "$USER_PASS_B64" | base64 -d)
ROOT_PASSWORD=$(echo -n "$ROOT_PASS_B64" | base64 -d)

# ---- 1. System Configuration ----
info "Setting timezone..."
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

info "Setting locale..."
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

info "Setting hostname..."
echo "${HOSTNAME_VAR}" > /etc/hostname
cat > /etc/hosts << HOSTS_EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME_VAR}.localdomain ${HOSTNAME_VAR}
HOSTS_EOF

# ---- 2. Users ----
info "Setting root password..."
echo "root:${ROOT_PASSWORD}" | chpasswd

info "Creating user ${USERNAME_VAR}..."
groupadd -f docker
useradd -m -G wheel,docker,video,audio -s /bin/zsh "${USERNAME_VAR}"
echo "${USERNAME_VAR}:${USER_PASSWORD}" | chpasswd

info "Configuring sudo..."
sed -i 's/^# *%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ---- 3. GRUB ----
info "Installing GRUB..."
if [[ "${BOOT_MODE}" == "uefi" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
else
    grub-install --target=i386-pc "${TARGET_DISK}"
fi

# Dual boot: enable os-prober so GRUB detects other operating systems
if [[ "${DUAL_BOOT}" == "true" ]]; then
    info "Enabling os-prober for dual boot..."
    pacman -S --needed --noconfirm os-prober
    if grep -q '^#GRUB_DISABLE_OS_PROBER=false' /etc/default/grub; then
        sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
    elif ! grep -q 'GRUB_DISABLE_OS_PROBER=false' /etc/default/grub; then
        echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
    fi
fi

grub-mkconfig -o /boot/grub/grub.cfg
success "GRUB installed"

# ---- 4. GPU Drivers ----
if [[ -n "${GPU_PACKAGES}" ]]; then
    info "Installing GPU drivers: ${GPU_PACKAGES}..."
    # shellcheck disable=SC2086
    pacman -S --needed --noconfirm ${GPU_PACKAGES} || warn "Some GPU packages may have failed"
    success "GPU drivers installed"
fi

# ---- 5. Enable base services ----
info "Enabling NetworkManager..."
systemctl enable NetworkManager

# ---- 6. Install yay ----
info "Installing yay..."
sudo -u "${USERNAME_VAR}" bash -c '
    set -euo pipefail
    cd /tmp
    git clone https://aur.archlinux.org/yay-bin.git
    cd yay-bin
    makepkg -si --noconfirm
    cd /tmp
    rm -rf yay-bin
'
success "yay installed"

# ---- 7. Install packages via yay ----
info "Installing packages via yay (this will take a while)..."
# shellcheck disable=SC2206
local_packages=(${YAY_PACKAGES})
total=${#local_packages[@]}
current=0
failed_packages=()

for pkg in "${local_packages[@]}"; do
    current=$((current + 1))
    printf "\r  [%d/%d] Installing %s...                    " "$current" "$total" "$pkg"
    if ! sudo -u "${USERNAME_VAR}" yay -S --needed --noconfirm "$pkg" &>/dev/null; then
        failed_packages+=("$pkg")
    fi
done
echo ""

if [[ ${#failed_packages[@]} -gt 0 ]]; then
    warn "Failed to install: ${failed_packages[*]}"
else
    success "All packages installed"
fi

# ---- 8. Clone and stow dotfiles ----
info "Cloning dotfiles..."
sudo -u "${USERNAME_VAR}" bash -c "
    set -euo pipefail
    cd /home/${USERNAME_VAR}
    git clone '${DOTFILES_REPO}' .dotfiles
    cd .dotfiles
    stow dotfiles || true
"
success "Dotfiles installed"

# ---- 9. LightDM Xsession config ----
info "Configuring LightDM Xsession..."
if [[ -f "/home/${USERNAME_VAR}/.dotfiles/arch_setup/etc/lightdm/Xsession" ]]; then
    mkdir -p /etc/lightdm
    cp "/home/${USERNAME_VAR}/.dotfiles/arch_setup/etc/lightdm/Xsession" /etc/lightdm/Xsession
    chmod +x /etc/lightdm/Xsession
    success "LightDM Xsession configured"
else
    warn "Xsession file not found in dotfiles, skipping"
fi

# ---- 10. Enable services ----
info "Enabling services..."
# shellcheck disable=SC2086
for svc in ${SERVICES}; do
    if systemctl enable "${svc}" 2>/dev/null; then
        success "Enabled ${svc}"
    else
        warn "Could not enable ${svc}"
    fi
done

# ---- 11. Create user directories ----
info "Creating user directories..."
sudo -u "${USERNAME_VAR}" mkdir -p \
    "/home/${USERNAME_VAR}/.cache/zsh" \
    "/home/${USERNAME_VAR}/Pictures/Backgrounds" \
    "/home/${USERNAME_VAR}/Documents" \
    "/home/${USERNAME_VAR}/Downloads"
sudo -u "${USERNAME_VAR}" touch "/home/${USERNAME_VAR}/.cache/zsh/history"

# ---- 12. Cleanup ----
info "Cleaning up..."
rm -f /root/chroot_setup.sh /root/chroot_config.sh

success "Chroot configuration complete!"
CHROOT_EOF

    # Write config file with injected variables (separate from the script)
    cat > /mnt/root/chroot_config.sh << CONFIG_EOF
HOSTNAME_VAR="${HOSTNAME_VAR}"
USERNAME_VAR="${USERNAME_VAR}"
USER_PASS_B64="${user_pass_b64}"
ROOT_PASS_B64="${root_pass_b64}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
KEYMAP="${KEYMAP}"
BOOT_MODE="${BOOT_MODE}"
TARGET_DISK="${TARGET_DISK}"
DUAL_BOOT="${DUAL_BOOT}"
GPU_PACKAGES="${gpu_packages}"
YAY_PACKAGES="${yay_pkg_list}"
DOTFILES_REPO="${DOTFILES_REPO}"
SERVICES="${services_list}"
CONFIG_EOF

    chmod +x /mnt/root/chroot_setup.sh
    arch-chroot /mnt /root/chroot_setup.sh

    success "System configuration complete"
}

# ===================== ORCHESTRATOR =========================

main() {
    # Check we're running as root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root."
        exit 1
    fi

    phase_preflight       # Phase 1
    phase_locale          # Phase 2
    phase_disk            # Phase 3
    phase_base_install    # Phase 4
    phase_chroot_config   # Phase 5

    # Remove EXIT trap for clean finish
    trap - EXIT

    # Final cleanup
    swapoff -a 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true

    banner "$TOTAL_PHASES" "$TOTAL_PHASES" "Installation Complete"
    success "Arch Linux has been installed successfully!"
    echo ""
    info "Remove the installation media and reboot."
    echo ""
    if ask_yes_no "Reboot now?" "y"; then
        reboot
    fi
}

main "$@"
