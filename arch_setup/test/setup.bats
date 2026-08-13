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

# --- enable_services -------------------------------------------------------
#
# systemctl and sudo are both stubbed on PATH. sudo must be: the real one would
# ask for a password nobody can type and then genuinely enable units on the
# developer's machine.

# stub_systemd <units that exist> <units whose enable fails> [extra list-unit-files output lines]
stub_systemd() {
    local exists=$1 fails=$2 noise=${3:-0}
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/systemctl" <<EOF
#!/bin/sh
case "\$1" in
  list-unit-files)
      i=0
      while [ "\$i" -lt $noise ]; do echo "filler-\$i.service disabled"; i=\$((i + 1)); done
      for u in $exists; do
          [ "\$2" = "\${u}.service" ] && { echo "\$2 disabled preset"; exit 0; }
      done
      exit 0 ;;
  enable)
      echo "\$2" >> "$TMP/enabled"
      for u in $fails; do [ "\$2" = "\$u" ] && exit 1; done
      exit 0 ;;
esac
exit 0
EOF
    printf '#!/bin/sh\nexec "$@"\n' > "$TMP/bin/sudo"
    chmod +x "$TMP/bin/systemctl" "$TMP/bin/sudo"
}

@test "enable_services succeeds when every unit enables" {
    stub_systemd "alpha beta" "__none__"
    PATH="$TMP/bin:$PATH" run enable_services alpha beta
    [ "$status" -eq 0 ]
    [[ "$output" == *"enabled alpha"* ]]
    [[ "$output" == *"enabled beta"* ]]
}

# The defect this replaced: the function returned the LAST iteration's status,
# so `enable_services NetworkManager lightdm docker bluetooth cups` could fail
# to enable NetworkManager -- no network on the next boot -- and still hand
# provision.sh a 0 because cups happened to be fine.
@test "enable_services fails on the first unit even when the last one succeeds" {
    stub_systemd "alpha beta gamma" "alpha"
    PATH="$TMP/bin:$PATH" run enable_services alpha beta gamma
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to enable alpha"* ]]
    [[ "$output" == *"1 of 3"* ]]
    # ...and it did not stop at the failure.
    [[ "$output" == *"enabled gamma"* ]]
}

@test "enable_services counts every failure, not just one" {
    stub_systemd "alpha beta gamma" "alpha gamma"
    PATH="$TMP/bin:$PATH" run enable_services alpha beta gamma
    [ "$status" -ne 0 ]
    [[ "$output" == *"2 of 3"* ]]
}

# Not a failure, deliberately: provision.sh asks for docker, bluetooth and cups
# on every run, and a machine provisioned with --skip-packages, or one whose
# operator declined the optional group, legitimately has none of them. A red
# summary on a run where nothing went wrong trains people to ignore it.
@test "enable_services skips a unit that is not installed without failing" {
    stub_systemd "alpha" "__none__"
    PATH="$TMP/bin:$PATH" run enable_services alpha cups
    [ "$status" -eq 0 ]
    [[ "$output" == *"cups.service not found"* ]]
    [[ "$output" == *"enabled alpha"* ]]
    # and it never tried
    assert_absent '^cups$' "$TMP/enabled"
}

# `systemctl list-unit-files ... | grep -q .` reports 141 for a unit that DOES
# exist once the output outgrows the pipe buffer: grep -q closes the pipe on
# its first hit, systemctl takes SIGPIPE, and provision.sh's `set -o pipefail`
# surfaces it. The same trap test/install.bats documents for keymap_listed, at
# the same threshold. Capturing the output has no pipe and no threshold.
@test "enable_services does not depend on systemctl's output fitting in a pipe" {
    stub_systemd "alpha" "__none__" 20000
    run bash -c "set -euo pipefail
                 source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
                 source '${BATS_TEST_DIRNAME}/../lib/system.sh'
                 source '${BATS_TEST_DIRNAME}/../lib/setup.sh'
                 export PATH=\"${TMP}/bin:\$PATH\"
                 enable_services alpha
                 echo RC[\$?]"
    [ "$status" -eq 0 ]
    [[ "$output" == *"enabled alpha"* ]]
    [[ "$output" == *"RC[0]"* ]]
}
