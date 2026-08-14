#!/bin/sh
# Push the ptbr layout into the ALREADY-RUNNING X server.
#
# Not part of login. The layout is normally applied per-device by
# /etc/X11/xorg.conf.d/00-keyboard.conf, which the X server reads only at
# startup -- so this is the escape hatch for the one case that config cannot
# cover: you changed the layout (or the config) and do not want to restart X
# yet. After a reboot or a lightdm restart you should never need this.
#
# Reads the installed system layout, so it reflects what install.sh deployed.

set -e

xkbcomp -w 0 - "${DISPLAY:-:0}" <<'KEYMAP'
xkb_keymap {
    xkb_keycodes { include "evdev+aliases(qwerty)" };
    xkb_types    { include "complete" };
    xkb_compat   { include "complete" };
    xkb_symbols  { include "pc+ptbr(basic)+inet(evdev)" };
    xkb_geometry { include "pc(pc105)" };
};
KEYMAP
