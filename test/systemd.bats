#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Against real systemd, not the stubs.
#
# The rest of the suite asserts what revertii ASKS systemd to do, which is the
# right thing to test for behaviour that is revertii's own. It cannot answer
# the two questions the tool actually rests on: does systemd accept a transient
# timer armed this way, and does it fire when nobody confirms.
#
# Skips itself where there is no systemd (macOS, containers without a user
# manager) rather than failing for a reason that is not about revertii. A skip
# here is not a pass — CI runs on a VM where these must execute.

load helper

setup() {
  command -v systemctl >/dev/null || skip "no systemctl on this machine"
  systemctl --user show-environment >/dev/null 2>&1 || skip "no systemd --user manager for this session"

  # The real thing this time: no stub bin dir on PATH.
  export TEST_TMP="$BATS_TEST_TMPDIR/revertii"
  export REVERTII_CONFIG_DIR="$TEST_TMP/etc"
  export REVERTII_STATE_DIR="$TEST_TMP/var"
  mkdir -p "$REVERTII_CONFIG_DIR" "$REVERTII_STATE_DIR"
  export REVERTII="$BATS_TEST_DIRNAME/../bin/revertii"
  # Unique per test, so a leftover unit from a previous run cannot be mistaken
  # for this one's.
  SERVICE="t$$-$BATS_TEST_NUMBER"
  export SERVICE
}

teardown() {
  [ -n "${SERVICE:-}" ] || return 0
  systemctl --user stop "revertii-revert-$SERVICE.timer" >/dev/null 2>&1 || true
  systemctl --user stop "revertii-revert-$SERVICE.service" >/dev/null 2>&1 || true
  systemctl --user reset-failed "revertii-revert-$SERVICE.service" >/dev/null 2>&1 || true
}

write_real_config() {
  cat > "$REVERTII_CONFIG_DIR/$SERVICE.conf" <<EOF
KIND=daemon
SNAPSHOT='echo v1.0.0'
UPDATE='true'
RESTORE='printf "%s" "\$REVERTII_SNAPSHOT" > $TEST_TMP/reverted'
HEALTH='true'
HEALTH_TIMEOUT=2
HEALTH_INTERVAL=1
REVERT_AFTER=5
$*
EOF
  chmod 600 "$REVERTII_CONFIG_DIR/$SERVICE.conf"
}

@test "systemd accepts the transient timer, and confirming removes it" {
  # HEALTH blocks long enough that the timer is still armed while we look at
  # it — the stubs can say revertii asked for a timer, only systemd can say
  # one exists.
  write_real_config "HEALTH='sleep 3'" "HEALTH_TIMEOUT=8" "REVERT_AFTER=30"
  "$REVERTII" update "$SERVICE" >/dev/null 2>&1 &
  local pid=$!

  local seen=no
  for _ in 1 2 3 4 5 6 7 8; do
    if systemctl --user is-active --quiet "revertii-revert-$SERVICE.timer" 2>/dev/null; then
      seen=yes
      break
    fi
    sleep 0.5
  done
  wait "$pid" || true

  [ "$seen" = yes ] || { systemctl --user list-timers --all | head -20; false; }
  # A healthy update disarms on its way out, so by now it must be gone.
  run systemctl --user is-active --quiet "revertii-revert-$SERVICE.timer"
  [ "$status" -ne 0 ]
}

@test "the timer fires on its own when the update takes revertii with it" {
  # The whole reason the tool exists. UPDATE kills revertii mid-run, so nothing
  # in this process ever checks health, disarms, or reverts — exactly what
  # happens when the update kills the host's own access. Only the armed timer
  # is left, and it has to finish the job by itself.
  write_real_config "UPDATE='kill -9 \$PPID'" "REVERT_AFTER=5"

  local armed_at
  armed_at=$(date +%s)
  run "$REVERTII" update "$SERVICE"
  [ ! -f "$TEST_TMP/reverted" ] || {
    echo "revertii reverted before dying — the test did not reproduce the case"
    false
  }

  for _ in $(seq 1 40); do
    [ -f "$TEST_TMP/reverted" ] && break
    sleep 1
  done

  [ -f "$TEST_TMP/reverted" ] || {
    echo "the timer never fired"
    systemctl --user list-timers --all | head -20
    journalctl --user -u "revertii-revert-$SERVICE.service" --no-pager -n 30 2>/dev/null || true
    false
  }

  # When it fired, not just that it did. systemd defaults to AccuracySec=1min
  # and will happily defer a 5s timer past 20s to batch wakeups — which makes
  # "revert armed: 5s from now" untrue by a wide margin, and leaves a broken
  # service broken for the difference. Measured here because no stub can.
  local waited=$(( $(date +%s) - armed_at ))
  [ "$waited" -le 12 ] || {
    echo "timer fired after ${waited}s for REVERT_AFTER=5 — systemd deferred it (AccuracySec?)"
    false
  }
  [ "$(cat "$TEST_TMP/reverted")" = v1.0.0 ] || {
    echo "reverted, but not to the recorded snapshot: $(cat "$TEST_TMP/reverted")"
    false
  }
}

@test "a RESTORE that fires from the timer finds the same commands the update did" {
  # Same class as the config dir: the unit starts with a fresh environment, so
  # whatever PATH the caller had is not automatically the one the revert runs
  # with. A restore command calling something outside systemd's default PATH
  # (podman from linuxbrew, a wrapper in ~/.local/bin) would work at update
  # time and fail at revert time — the one moment nobody is watching.
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/restore-helper" <<HELPER
#!/bin/sh
printf '%s' "\$1" > $TEST_TMP/reverted
HELPER
  chmod +x "$TEST_TMP/bin/restore-helper"
  export PATH="$TEST_TMP/bin:$PATH"

  write_real_config "UPDATE='kill -9 \$PPID'" \
    "RESTORE='restore-helper \"\$REVERTII_SNAPSHOT\"'" "REVERT_AFTER=5"

  run "$REVERTII" update "$SERVICE"
  for _ in $(seq 1 40); do
    [ -f "$TEST_TMP/reverted" ] && break
    sleep 1
  done

  [ -f "$TEST_TMP/reverted" ] || {
    echo "the revert never ran the helper — PATH did not survive into the timer unit"
    journalctl --user -u "revertii-revert-$SERVICE.service" --no-pager -n 20 2>/dev/null || true
    false
  }
  [ "$(cat "$TEST_TMP/reverted")" = v1.0.0 ]
}

@test "a revert the timer drove leaves no state behind" {
  # The stubs cannot catch this one: they record that revertii asked systemd to
  # stop the unit, but a stub cannot do what systemd does — kill the asking
  # process, because the process IS that unit. Everything after the stop call
  # then silently does not happen, and the leftover state makes a later
  # `revertii revert` restore a snapshot from an update that already came back.
  write_real_config "UPDATE='kill -9 \$PPID'" "REVERT_AFTER=5"

  run "$REVERTII" update "$SERVICE"
  for _ in $(seq 1 40); do
    [ -f "$TEST_TMP/reverted" ] && break
    sleep 1
  done
  [ -f "$TEST_TMP/reverted" ] || {
    echo "the timer never reverted — this test cannot say anything about state"
    false
  }

  [ ! -f "$REVERTII_STATE_DIR/$SERVICE.state" ] || {
    echo "state left behind after the revert completed:"
    cat "$REVERTII_STATE_DIR/$SERVICE.state"
    false
  }
}

@test "the transient unit does not outlive itself" {
  # --collect is what keeps a fired unit from sitting in systemd's list as
  # failed/inactive forever. A leftover would make the next run's "is a revert
  # still pending" check answer yes for a revert that already happened.
  write_real_config
  run "$REVERTII" update "$SERVICE"
  [ "$status" -eq 0 ]

  run systemctl --user list-units --all "revertii-revert-$SERVICE.*" --no-legend
  [ -z "${output// /}" ] || {
    echo "unit left behind: $output"
    false
  }
}
