# bsptab

i3-style tabbed window management for bspwm.

Multiple windows share one tile, with a tab bar at the top to switch between
them -- exactly like i3's tabbed layout, but running on bspwm.

## Dependencies

**None** beyond what a standard Arch + bspwm install already has:

- Python 3.10+ (standard library only, no pip packages)
- `libX11`, `libcairo`, `libpango`, `libpangocairo`, `libgobject-2.0` (all present on any X11 desktop)
- `bspc` (ships with bspwm)

The script uses `ctypes` to call the C libraries directly.

## Quick Start

1. The daemon starts automatically via `bspwmrc`. To start it manually:

```sh
bsptab daemon &
```

2. Focus a window and press `Super+t, h` to merge the neighbor to the left
   into a tab group (or `j`/`k`/`l` for the other directions).

3. Switch tabs with `Super+t, n` (next) and `Super+t, p` (previous).

4. Remove the active tab with `Super+t, r`.

## Commands

```
bsptab daemon          Start the daemon (runs in background, once per session)
bsptab create          Create a tab group from the focused window
bsptab add <dir>       Add the neighbor in <dir> to the focused tab group
bsptab remove          Detach the active tab back into its own window
bsptab next            Switch to the next tab
bsptab prev            Switch to the previous tab
bsptab focus <n>       Switch to tab number n (1-indexed)
bsptab close           Close the active tab's window (sends WM_DELETE_WINDOW)
bsptab list            Print all tab groups and their windows
```

`<dir>` is one of `west`, `south`, `north`, `east` -- matching bspwm's
directional vocabulary.

## Keybindings (sxhkd)

All bindings live behind the `Super+t` chord prefix:

| Keys               | Action                                     |
|--------------------|--------------------------------------------|
| `Super+t, h/j/k/l` | Add neighbor west/south/north/east to group |
| `Super+t, r`       | Remove active tab from group               |
| `Super+t, t`       | Create a tab group from the focused window  |
| `Super+t, n`       | Next tab                                   |
| `Super+t, p`       | Previous tab                               |
| `Super+t, 1-9`     | Jump to tab by number                      |
| `Super+t, q`       | Close the active tab's window              |

The sxhkd config lives in `~/.config/sxhkd/sxhkdrc`.

## Tab Bar

The tab bar is 26px tall, rendered with Cairo + Pango for crisp antialiased
text.  Colors follow the i3 default scheme:

| Element         | Color     |
|-----------------|-----------|
| Active tab bg   | `#285577` |
| Active tab fg   | `#ffffff` |
| Active border   | `#4c7899` |
| Inactive tab bg | `#222222` |
| Inactive tab fg | `#888888` |
| Urgent tab bg   | `#900000` |
| Bar background  | `#1d1f21` |

- **Left click** on a tab switches to it.
- **Middle click** on a tab closes that window.
- Tab titles update in real time when the window changes its `WM_NAME` /
  `_NET_WM_NAME`.
- Long titles are truncated with an ellipsis.

To change colors, tab height, or font, edit the `COLORS`, `TAB_HEIGHT`, and
`FONT_DESC` constants near the top of the script.

## How It Works

### Architecture

```
                   ┌────────────────────┐
                   │   bsptab daemon    │
                   │   (long-running)   │
                   └──┬──────────────┬──┘
                      │              │
              X11 event loop    Unix socket
              (select-based)    /run/user/$UID/bsptab.sock
                      │              │
                      ▼              ▼
              handle resize     CLI commands
              handle clicks     (bsptab add, next, ...)
              handle focus
              track titles
              detect closes
```

`bsptab` is a single Python file that acts as both the daemon and the CLI.
`bsptab daemon` starts the daemon; every other subcommand sends a JSON message
over the Unix socket and prints the response.

### Reparenting

When a tab group is created:

1. A **container window** (class `Bsptab`) is created and mapped.  bspwm
   manages it like any regular tiled window.
2. `bspc node <container> -s <target>` swaps the container into the target
   window's position in the tiling tree.
3. The target window is **reparented** into the container with
   `XReparentWindow`.  bspwm sees the target disappear (UnmapNotify) and drops
   its node.
4. The container now occupies the tile, with the original window drawn inside
   it below the tab bar.

Adding more windows repeats steps 3-4.  Removing a tab reverses the process:
the window is reparented back to root, bspwm picks it up as a new window, and
`bspc node -s` swaps it into the container's position if the group dissolves.

### Focus Handling

bspwm focuses the container window (it's the managed node).  The daemon
intercepts `FocusIn` events on the container and redirects X input focus to the
active client window with `XSetInputFocus`.  This means keyboard input goes to
the correct application, while bspwm's focus tracking (border color, etc.)
stays on the container.

### Auto-Dissolve

When a tab group has only one window left (after a remove or external close),
it automatically dissolves: the remaining window is reparented back to root and
placed where the container was.  No manual cleanup needed.

### Daemon Recovery

On startup the daemon scans root's children for windows with class `Bsptab`.
If it finds orphaned containers (e.g. from a previous daemon crash), it
re-registers them and their children.  This means restarting the daemon
(`pkill -f "bsptab daemon" && bsptab daemon &`) is safe.

## Files

| File | Role |
|------|------|
| `~/.scripts/bspwm/bsptab` | The script (daemon + CLI) |
| `~/.config/bspwm/bspwmrc` | Starts the daemon on login |
| `~/.config/sxhkd/sxhkdrc` | Keybindings |
| `/run/user/$UID/bsptab.sock` | IPC socket (created by daemon) |
| `~/.bsptab.log` | Daemon log |

## Troubleshooting

**Daemon not running**

```sh
# Check
pgrep -f "bsptab daemon"

# Restart
pkill -f "bsptab daemon"
bsptab daemon &
```

**"No window in direction"**

There is no bspwm-managed window in that direction relative to the focused
node.  Make sure both windows are on the same desktop.

**Window disappeared after create**

Check `~/.bsptab.log` for "externally unmapped" messages.  This usually means
a race condition with bspwm event processing.  The daemon will have dissolved
the group.  Try again -- the timing is tight on the first create but works
reliably once bspwm has processed the initial node swap.

**Tab bar not rendering / garbled**

Make sure `libcairo`, `libpango-1.0`, and `libpangocairo-1.0` are installed.
On Arch: `pacman -S cairo pango`.

**Stale socket**

If the daemon crashed without cleanup:

```sh
rm /run/user/$(id -u)/bsptab.sock
bsptab daemon &
```

## Internals (for contributors)

The codebase is structured into these classes:

| Class | Line | Purpose |
|-------|------|---------|
| `X11Lib` | 315 | Loads shared libraries, sets ctypes signatures |
| `XDisplay` | 523 | Wraps X11 display connection and common operations |
| `TabBar` | 742 | Cairo + Pango tab bar renderer |
| `TabGroup` | 873 | Data class holding a group's state |
| `TabManager` | 885 | Core logic: group lifecycle, event dispatch, IPC |

Key design decisions:

- **ctypes instead of python-xlib/xcffib** -- zero pip dependencies, the script
  runs on a fresh Arch install.
- **Single file** -- easy to deploy in a dotfiles repo, no packaging needed.
- **select() multiplexing** -- the event loop uses `select.select()` on both
  the X11 file descriptor and the Unix socket, avoiding threads entirely.
- **Expected unmap counter** -- reparenting and tab switching generate
  UnmapNotify events that must be distinguished from external window closes.
  A per-window counter tracks how many unmaps to ignore.
