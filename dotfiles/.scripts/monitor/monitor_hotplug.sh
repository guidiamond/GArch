#!/usr/bin/env bash

# monitor_hotplug.sh — Handles monitor connect/disconnect events.
# Rearranges bspwm workspaces and relaunches eww bar.
#
# Usage:
#   monitor_hotplug.sh          (auto-detect)
#   monitor_hotplug.sh connect  (force connect path)
#   monitor_hotplug.sh disconnect (force disconnect path)
#
# Constraint: supports exactly 2 monitors (eDP-1 + one external).

LOGFILE="/tmp/monitor_hotplug.log"
LOCKFILE="/tmp/monitor_hotplug.lock"

log() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$LOGFILE"
    echo "$*"
}

# Ensure we have a display — needed when called from udev
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-/home/$(whoami)/.Xauthority}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

EWW_DIR="$HOME/.config/eww"

# The laptop display — the one that's always there
INTERNAL_MONITOR="eDP-1"

# ── Helpers ──────────────────────────────────────────────────────────

get_connected_outputs() {
    xrandr | awk '/ connected/ {print $1}'
}

get_active_monitors() {
    xrandr --listactivemonitors | tail -n +2 | awk '{print $NF}'
}

get_external_monitor() {
    # Returns the first connected non-internal output, or empty string
    for output in $(get_connected_outputs); do
        if [[ "$output" != "$INTERNAL_MONITOR" ]]; then
            echo "$output"
            return
        fi
    done
}

wait_for_xrandr() {
    # Give X a moment to register the change
    sleep 1
}

# ── Disconnect: external monitor removed ─────────────────────────────
# Moves windows from each external workspace N to internal workspace N,
# then removes leftover desktops and relaunches eww.

handle_disconnect() {
    log "=== DISCONNECT detected ==="

    local ext_monitor="$1"

    # Check if bspwm still knows about this monitor
    if ! bspc query -M --names | grep -q "^${ext_monitor}$"; then
        log "Monitor $ext_monitor already gone from bspwm, cleaning up orphan desktops."
        xrandr --output "$ext_monitor" --off 2>/dev/null || true
        cleanup_orphan_desktops
        relaunch_eww
        return
    fi

    # Get list of desktops on the external monitor
    local ext_desktops
    ext_desktops=$(bspc query -D -m "$ext_monitor" --names 2>/dev/null || true)

    if [[ -z "$ext_desktops" ]]; then
        log "No desktops found on $ext_monitor, nothing to migrate."
    else
        for ws_name in $ext_desktops; do
            # Target: same workspace number on internal monitor
            local target="${INTERNAL_MONITOR}:^${ws_name}"

            # Ensure target desktop exists on internal monitor
            local internal_desktops
            internal_desktops=$(bspc query -D -m "$INTERNAL_MONITOR" --names 2>/dev/null || true)
            if ! echo "$internal_desktops" | grep -qx "$ws_name"; then
                bspc monitor "$INTERNAL_MONITOR" -a "$ws_name"
                log "Created desktop $ws_name on $INTERNAL_MONITOR"
            fi

            # Move all nodes from ext:ws_name to internal:ws_name
            local nodes
            nodes=$(bspc query -N -d "${ext_monitor}:^${ws_name}" 2>/dev/null || true)
            for node in $nodes; do
                bspc node "$node" --to-desktop "$target"
                log "Moved node $node from ${ext_monitor}:${ws_name} -> ${INTERNAL_MONITOR}:${ws_name}"
            done
        done
    fi

    # Turn off the external output via xrandr
    xrandr --output "$ext_monitor" --off
    log "Disabled $ext_monitor via xrandr"

    # Wait for X and bspwm to fully deregister the monitor
    sleep 1.5

    # Remove any orphan desktops that bspwm merged into the internal monitor
    cleanup_orphan_desktops

    relaunch_eww
    log "=== DISCONNECT complete ==="
}

# ── Connect: external monitor plugged in ─────────────────────────────
# Activates the output, creates workspaces 1-10, relaunches eww.

handle_connect() {
    local ext_monitor="$1"
    log "=== CONNECT detected: $ext_monitor ==="

    # Activate the external monitor via xrandr
    # Place it to the left of internal (matching your screenlayout)
    # Auto mode picks the preferred resolution
    xrandr --output "$ext_monitor" --auto --left-of "$INTERNAL_MONITOR" --output "$INTERNAL_MONITOR" --primary
    log "Activated $ext_monitor via xrandr (left-of $INTERNAL_MONITOR)"

    # Give bspwm time to register the new monitor
    sleep 0.5

    # Ensure bspwm knows about the monitor
    if ! bspc query -M --names | grep -q "^${ext_monitor}$"; then
        log "ERROR: bspwm did not register $ext_monitor after xrandr"
        return 1
    fi

    # Create workspaces 1-10 on the new monitor
    bspc monitor "$ext_monitor" -d 1 2 3 4 5 6 7 8 9 10
    log "Created workspaces 1-10 on $ext_monitor"

    # Make sure internal still has all its desktops
    bspc monitor "$INTERNAL_MONITOR" -d 1 2 3 4 5 6 7 8 9 10
    log "Ensured workspaces 1-10 on $INTERNAL_MONITOR"

    relaunch_eww
    log "=== CONNECT complete ==="
}

# ── Cleanup: remove orphan desktops after unplug ─────────────────────

cleanup_orphan_desktops() {
    # After a monitor is removed, bspwm may merge its desktops into the
    # remaining monitor, creating duplicates or extras beyond 10. Remove them.
    local all_desktops
    all_desktops=$(bspc query -D -m "$INTERNAL_MONITOR" --names 2>/dev/null || true)
    local count=0

    for d in $all_desktops; do
        count=$((count + 1))
        if [[ $count -gt 10 ]]; then
            # Move any nodes on this desktop to desktop 10 first
            local nodes
            nodes=$(bspc query -N -d "${INTERNAL_MONITOR}:${d}" 2>/dev/null || true)
            for node in $nodes; do
                bspc node "$node" --to-desktop "${INTERNAL_MONITOR}:^10"
                log "Moved orphan node $node to ${INTERNAL_MONITOR}:10"
            done
            bspc desktop "${INTERNAL_MONITOR}:${d}" --remove 2>/dev/null || true
            log "Removed orphan desktop ${d} from $INTERNAL_MONITOR"
        fi
    done

    # Ensure we still have exactly 1-10
    bspc monitor "$INTERNAL_MONITOR" -d 1 2 3 4 5 6 7 8 9 10
    log "Reset $INTERNAL_MONITOR desktops to 1-10"
}

# ── Relaunch eww ─────────────────────────────────────────────────────

relaunch_eww() {
    log "Relaunching eww bar..."
    if [[ -x "$EWW_DIR/launch_bar.sh" ]]; then
        "$EWW_DIR/launch_bar.sh"
        log "eww relaunch complete"
    else
        log "WARNING: $EWW_DIR/launch_bar.sh not found or not executable"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    wait_for_xrandr

    local action="${1:-auto}"
    local ext_monitor

    if [[ "$action" == "auto" ]]; then
        ext_monitor=$(get_external_monitor)
        local active_monitors
        active_monitors=$(get_active_monitors)
        local active_count
        active_count=$(echo "$active_monitors" | wc -l)

        if [[ -n "$ext_monitor" ]] && ! echo "$active_monitors" | grep -q "^${ext_monitor}$"; then
            # External is connected (xrandr sees it) but not active yet → connect
            handle_connect "$ext_monitor"
        elif [[ -z "$ext_monitor" ]] && [[ $active_count -le 1 ]]; then
            # No external connected but bspwm may still have orphan desktops → disconnect
            # Try to find the name of the monitor that was just removed
            local bspwm_monitors
            bspwm_monitors=$(bspc query -M --names 2>/dev/null || true)
            local disconnected=""
            for m in $bspwm_monitors; do
                if [[ "$m" != "$INTERNAL_MONITOR" ]]; then
                    disconnected="$m"
                    break
                fi
            done

            if [[ -n "$disconnected" ]]; then
                handle_disconnect "$disconnected"
            else
                log "No external monitor found, cleaning up just in case."
                cleanup_orphan_desktops
                relaunch_eww
            fi
        else
            log "No action needed. External: $ext_monitor, Active: $active_count monitors"
        fi

    elif [[ "$action" == "connect" ]]; then
        ext_monitor=$(get_external_monitor)
        if [[ -z "$ext_monitor" ]]; then
            log "ERROR: connect requested but no external monitor found"
            exit 1
        fi
        handle_connect "$ext_monitor"

    elif [[ "$action" == "disconnect" ]]; then
        # Find which monitor bspwm still tracks that isn't the internal one
        local bspwm_monitors
        bspwm_monitors=$(bspc query -M --names 2>/dev/null || true)
        for m in $bspwm_monitors; do
            if [[ "$m" != "$INTERNAL_MONITOR" ]]; then
                handle_disconnect "$m"
                exit 0
            fi
        done
        log "No external monitor in bspwm to disconnect"
        cleanup_orphan_desktops
        relaunch_eww

    else
        echo "Usage: $0 [auto|connect|disconnect]"
        exit 1
    fi
}

# ── Entry point with flock ───────────────────────────────────────────
# Prevent concurrent runs (udev can fire multiple events).
# The lock fd is scoped to this block — child processes (eww daemon, etc.)
# do NOT inherit it, so the lock is released when this script exits.

(
    flock -n 200 || { log "Already running, skipping."; exit 0; }
    main "$@"
) 200>"$LOCKFILE"
