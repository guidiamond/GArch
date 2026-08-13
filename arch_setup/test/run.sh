#!/bin/bash
# Run the whole arch_setup test suite: shellcheck over every script, then bats.
#
#   ./test/run.sh
#
# Like test/vm.sh this runs on the host and sources nothing from lib/, for the
# same reason: it is used precisely when lib/ is being changed, and a runner
# that breaks along with the code it checks reports nothing worth having.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

# The suite puts stub pacman and reflector binaries on PATH. A call that misses
# a stub falls through to the real one, and as root that is a real `pacman -Sy`
# or a reflector rewriting /etc/pacman.d/mirrorlist -- on this machine, not on
# a target. Unprivileged, both of those fail loudly instead, which is the whole
# reason the suite is safe to run at all.
if (( EUID == 0 )); then
    echo "[ERROR] refusing to run as root: the suite stubs pacman and reflector, and anything that misses a stub would hit this machine" >&2
    exit 1
fi

echo "== shellcheck =="
shellcheck -x install.sh provision.sh lib/*.sh test/helpers.bash test/vm.sh test/run.sh
echo "ok"

echo ""
echo "== bats =="
bats test/*.bats
