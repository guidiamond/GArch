#!/bin/sh
# Install the ptbr layout system-wide and make X apply it per-device.
#
# Run with sudo. Idempotent -- safe to re-run after editing symbols/ptbr.
#
# Why system-wide instead of `xkbcomp` at login: pushing a keymap into the
# running server is a one-shot that any input-device re-enumeration silently
# reverts to plain `us` (a udev reload from a pacman transaction is enough).
# An InputClass is re-applied every time a device is added, so it survives.

set -e

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SRC="$REAL_HOME/.config/xkb"

# Fail before touching anything if the layout is broken. xkbcomp insists on
# creating its output file, so it gets a scratch path rather than /dev/null.
CHECK=$(mktemp -t ptbr-check.XXXXXX.xkm)
trap 'rm -f "$CHECK"' EXIT
xkbcomp -I"$SRC" -w 0 -o "$CHECK" - <<'KEYMAP'
xkb_keymap {
    xkb_keycodes { include "evdev+aliases(qwerty)" };
    xkb_types    { include "complete" };
    xkb_compat   { include "complete" };
    xkb_symbols  { include "pc+ptbr(basic)+inet(evdev)" };
    xkb_geometry { include "pc(pc105)" };
};
KEYMAP
echo "layout compiles"

install -Dm644 "$SRC/symbols/ptbr" /usr/share/X11/xkb/symbols/ptbr
echo "installed /usr/share/X11/xkb/symbols/ptbr"

install -d /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<'CONF'
# US layout + Portuguese accents on AltGr. Layout source lives in
# ~/.config/xkb/symbols/ptbr; re-run ~/.config/xkb/install.sh after editing it.
Section "InputClass"
    Identifier  "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout"  "ptbr"
    Option "XkbVariant" "basic"
    Option "XkbModel"   "pc105"
EndSection
CONF
echo "installed /etc/X11/xorg.conf.d/00-keyboard.conf"

# The login-time xkbcomp call is now redundant and actively misleading -- it
# would paper over a broken InputClass instead of letting it fail loudly.
BSPWMRC="$REAL_HOME/.config/bspwm/bspwmrc"
for f in "$BSPWMRC" "$REAL_HOME/.dotfiles/dotfiles/.config/bspwm/bspwmrc"; do
    [ -f "$f" ] || continue
    if grep -q 'apply-keymap.sh' "$f"; then
        sed -i '/^# Keyboard: US layout + Portuguese accents/,/^$/d; \#apply-keymap.sh#d' "$f"
        chown "$REAL_USER:$(id -gn "$REAL_USER")" "$f"
        echo "dropped apply-keymap.sh call from $f"
    fi
done
rm -f "$SRC/apply-keymap.sh"

# lightdm's /etc/X11/Xsession runs `setxkbmap $(cat ...)` for these files at
# every login, AFTER the X server has applied the InputClass above -- so any of
# them silently wins. A stale ~/.Xkbmap saying "-layout us -variant intl" is
# what put dead keys back on ' and stole AltGr+c. Refuse to pretend we are
# configured while one of these exists.
for stale in /etc/X11/Xkbmap "$REAL_HOME/.Xkbmap" /etc/X11/Xmodmap "$REAL_HOME/.Xmodmap"; do
    if [ -e "$stale" ]; then
        echo
        echo "WARNING: $stale exists and lightdm applies it at login," >&2
        echo "         overriding the layout installed above. Remove it." >&2
        echo "         contents: $(cat "$stale" 2>/dev/null)" >&2
    fi
done

# The InputClass above only takes effect at X server startup -- xorg.conf.d is
# parsed once, when the server starts. Do NOT `udevadm trigger` here hoping to
# test it: that re-adds every device using the config the server parsed at ITS
# startup, i.e. the old one, which drops the running session back to plain `us`.
#
# So apply to the running session the only way that works on a live server.
if [ -n "$DISPLAY" ] || [ -e /tmp/.X11-unix/X0 ]; then
    runuser -u "$REAL_USER" -- env DISPLAY="${DISPLAY:-:0}" "$SRC/reapply.sh" \
        && echo "applied to the running X session"
fi

echo
echo "Done. The per-device config takes effect at the next X start"
echo "(reboot, or: sudo systemctl restart lightdm)."
