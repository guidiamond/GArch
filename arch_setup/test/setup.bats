#!/usr/bin/env bats
#
# lib/setup.sh -- the sudo-requiring, stage-2-only half of what used to be
# lib/system.sh. Split out of test/system.bats along with the code.
#
# Almost nothing here can be exercised for real: every function runs sudo
# against /etc, systemd or the bootloader. What is testable is the branch each
# one takes *before* it reaches sudo, plus enable_services' aggregation, which
# is pure control flow over a stubbed systemctl.

load helpers

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/system.sh"
    source "${BATS_TEST_DIRNAME}/../lib/setup.sh"
    TMP="$BATS_TEST_TMPDIR"
}

# --- subsystem setup -------------------------------------------------------

# Machine-independent: assert on whichever branch this host lands in, so the
# test does not silently depend on the developer's own login shell.
@test "setup_shell --check-only reports without changing anything" {
    run setup_shell --check-only
    [ "$status" -eq 0 ]
    if [ "$(getent passwd "$USER" | cut -d: -f7)" = "/usr/bin/zsh" ]; then
        [[ "$output" == *"already"* ]]
    else
        [[ "$output" == *"would chsh"* ]]
    fi
}

@test "setup_shell fails when the target user cannot be determined" {
    USER="" SUDO_USER="" run setup_shell --check-only
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot determine the target user"* ]]
}
