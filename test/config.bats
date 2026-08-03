#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Config validation. Every rejection here exists because the alternative is a
# service updated with no working way back — which is the one outcome this
# tool exists to prevent.

load helper

setup() { setup_stub_env; }

@test "a config missing RESTORE is refused, naming what it is for" {
  write_config gw 'RESTORE=""'
  run "$REVERTII" update gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"RESTORE is required"* ]]
  [[ "$output" == *"reversible"* ]]
}

@test "a daemon without HEALTH is refused" {
  # Without a health check there is nothing to decide on, and the update would
  # be kept by default — the opposite of provisional.
  write_config gw 'HEALTH=""'
  run "$REVERTII" update gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"a daemon needs HEALTH"* ]]
}

@test "a job without UNIT is refused" {
  write_config backup 'KIND=job' 'HEALTH=""' 'UNIT=""'
  run "$REVERTII" update backup
  [ "$status" -eq 2 ]
  [[ "$output" == *"a job needs UNIT"* ]]
}

@test "an unknown KIND is refused rather than treated as a daemon" {
  write_config gw 'KIND=service'
  run "$REVERTII" update gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"KIND must be"* ]]
}

@test "a revert window shorter than the health check is refused" {
  # The timer would fire while the health check is still deciding, taking back
  # an update that was about to pass.
  write_config gw 'HEALTH_TIMEOUT=90' 'REVERT_AFTER=30'
  run "$REVERTII" update gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"must exceed HEALTH_TIMEOUT"* ]]
  [[ "$output" == *"mid-check"* ]]
}

@test "equal timeout and revert window are refused too" {
  write_config gw 'HEALTH_TIMEOUT=60' 'REVERT_AFTER=60'
  run "$REVERTII" update gw
  [ "$status" -eq 2 ]
}

@test "a non-numeric timeout is refused with the value quoted back" {
  write_config gw 'HEALTH_TIMEOUT=90s'
  run "$REVERTII" update gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"whole number of seconds"* ]]
  [[ "$output" == *"90s"* ]]
}

@test "a group-writable config is refused, because it is executed" {
  write_config gw
  chmod 660 "$REVERTII_CONFIG_DIR/gw.conf"
  run "$REVERTII" update gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"writable"* ]]
  [[ "$output" == *"chmod 600"* ]]
}

@test "an unprivileged run looks under XDG, not /etc" {
  # Root is not a requirement: rootless podman with systemd --user units needs
  # none of it, and that is the better place for an agent-triggerable command
  # to live. The paths and the systemd scope have to follow the same decision.
  unset REVERTII_CONFIG_DIR REVERTII_STATE_DIR
  XDG_CONFIG_HOME="$TEST_TMP/xdg-config" run "$REVERTII" update gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"$TEST_TMP/xdg-config/revertii/gw.conf"* ]]
  [[ "$output" != *"/etc/revertii"* ]]
}

@test "the systemd scope follows the same decision as the paths" {
  write_config gw
  run "$REVERTII" update gw
  [ "$status" -eq 0 ]
  # The test suite never runs as root, so every systemd call must be --user.
  grep -qE 'systemd-run --user' "$STUB_LOG"
  ! grep -qE 'systemctl --system' "$STUB_LOG"
}

@test "a missing config points at how to find the right name" {
  run "$REVERTII" update nosuch
  [ "$status" -eq 2 ]
  [[ "$output" == *"revertii list"* ]]
}

@test "update without a service name says so instead of guessing" {
  run "$REVERTII" update
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs a service name"* ]]
}

@test "an unknown option is rejected rather than ignored" {
  run "$REVERTII" update gw --force-everything
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "a non-numeric --timeout is refused with the value quoted back" {
  write_config gw
  run "$REVERTII" check gw --timeout abc
  [ "$status" -eq 2 ]
  [[ "$output" == *"whole number of seconds"* ]]
  [[ "$output" == *"abc"* ]]
}

@test "a config that calls systemctl without a scope is warned about when rootless" {
  # The failure this catches is silent and lands late: a hardcoded systemctl
  # reaches the system manager, so a rootless RESTORE puts the old version back
  # and then fails to restart — old state on disk, broken version still running.
  write_config gw 'UPDATE="systemctl restart app.service"'
  run "$REVERTII" update gw
  [[ "$output" == *"UPDATE calls systemctl without a scope"* ]]
  [[ "$output" == *"REVERTII_SYSTEMD_SCOPE"* ]]
}

@test "a config using the scope variable is not warned about, and gets the real scope" {
  cat > "$REVERTII_CONFIG_DIR/gw.conf" <<EOF
KIND=daemon
SNAPSHOT='echo v1.0.0'
UPDATE='systemctl \$REVERTII_SYSTEMD_SCOPE restart app.service'
RESTORE='echo \$REVERTII_SNAPSHOT'
HEALTH='true'
HEALTH_TIMEOUT=5
HEALTH_INTERVAL=1
REVERT_AFTER=60
EOF
  chmod 600 "$REVERTII_CONFIG_DIR/gw.conf"

  run "$REVERTII" update gw
  [ "$status" -eq 0 ]
  [[ "$output" != *"without a scope"* ]]
  # The point of the variable: it arrived expanded, as the scope this run uses.
  grep -q '^systemctl --user restart app.service$' "$STUB_LOG"
}

@test "a root-style config is not warned about for a reason that only applies rootless" {
  # --system is explicit, so it is a deliberate choice rather than an omission.
  write_config gw 'UPDATE="systemctl --system restart app.service"'
  run "$REVERTII" update gw
  [[ "$output" != *"without a scope"* ]]
}
