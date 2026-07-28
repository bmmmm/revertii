#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# The update sequence. The ordering assertions matter more than they look:
# the timer has to be armed BEFORE the update runs, or an update that takes
# the host down leaves nothing behind to undo it.

load helper

setup() { setup_stub_env; }

@test "a healthy update arms the timer, then disarms it and keeps the change" {
  write_config gw
  run "$REVERTII" update gw
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy — update kept"* ]]
  timer_was_armed
  timer_was_disarmed
  [ ! -f "$REVERTII_STATE_DIR/gw.state" ]
}

@test "the timer is armed before the update command runs" {
  # Written as an ordering check on purpose: this is the property the whole
  # design rests on, and it is invisible in any single-step assertion.
  write_config gw "UPDATE=\"echo UPDATE-RAN >> '$STUB_LOG'\""
  run "$REVERTII" update gw
  [ "$status" -eq 0 ]
  local armed update_ran
  armed=$(grep -n 'systemd-run .*--on-active' "$STUB_LOG" | head -1 | cut -d: -f1)
  update_ran=$(grep -n 'UPDATE-RAN' "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$armed" ] && [ -n "$update_ran" ]
  [ "$armed" -lt "$update_ran" ]
}

@test "an unhealthy service is reverted without waiting for the timer" {
  write_config gw 'HEALTH="false"' 'HEALTH_TIMEOUT=2'
  run "$REVERTII" update gw
  [ "$status" -eq 1 ]
  [[ "$output" == *"not healthy within"* ]]
  [[ "$output" == *"reverting"* ]]
  [[ "$output" == *"reverted to v1.0.0"* ]]
  [ ! -f "$REVERTII_STATE_DIR/gw.state" ]
}

@test "the snapshot reaches RESTORE through the environment, not the command string" {
  # A tag carrying a quote or a space must not be able to change what runs.
  # Note the single quotes around RESTORE: the config is sourced, so a
  # double-quoted $REVERTII_SNAPSHOT would expand to empty right there rather
  # than at revert time. Same trap a real config falls into.
  cat > "$REVERTII_CONFIG_DIR/gw.conf" <<EOF
KIND=daemon
SNAPSHOT='printf %s "registry/app:1.0 evil"'
UPDATE=true
RESTORE='printf "GOT[%s]" "\$REVERTII_SNAPSHOT" >> $STUB_LOG'
HEALTH=false
HEALTH_TIMEOUT=1
HEALTH_INTERVAL=1
REVERT_AFTER=60
EOF
  chmod 600 "$REVERTII_CONFIG_DIR/gw.conf"

  run "$REVERTII" update gw
  [ "$status" -eq 1 ]
  grep -q 'GOT\[registry/app:1.0 evil\]' "$STUB_LOG"
}

@test "a RESTORE that never mentions the snapshot is warned about" {
  # The likeliest cause is a double-quoted $REVERTII_SNAPSHOT in the config,
  # which the shell expanded to nothing while sourcing — leaving a RESTORE
  # that silently restores whatever happens to be current.
  write_config gw 'HEALTH="false"' 'HEALTH_TIMEOUT=1' 'RESTORE="true"'
  run "$REVERTII" update gw
  [[ "$output" == *"RESTORE does not mention"* ]]
  [[ "$output" == *"single quotes"* ]]
}

@test "a failing update command reverts instead of leaving it half-applied" {
  write_config gw 'UPDATE="false"'
  run "$REVERTII" update gw
  [ "$status" -eq 1 ]
  [[ "$output" == *"update command failed"* ]]
  [[ "$output" == *"reverted to v1.0.0"* ]]
}

@test "PREPARE runs before the timer is armed" {
  # Building an image can outlast the whole revert window. Anything that does
  # not touch the running service belongs outside the armed window.
  write_config gw "PREPARE=\"echo PREPARE-RAN >> '$STUB_LOG'\""
  run "$REVERTII" update gw
  [ "$status" -eq 0 ]
  local prepared armed
  prepared=$(grep -n 'PREPARE-RAN' "$STUB_LOG" | head -1 | cut -d: -f1)
  armed=$(grep -n 'systemd-run .*--on-active' "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$prepared" ] && [ -n "$armed" ]
  [ "$prepared" -lt "$armed" ]
}

@test "a failing PREPARE stops before anything is armed or changed" {
  write_config gw 'PREPARE="false"'
  run "$REVERTII" update gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"prepare failed"* ]]
  [[ "$output" == *"nothing was changed"* ]]
  ! timer_was_armed
}

@test "an update that outlived its own timer is reported, not health-checked" {
  # The race this catches: the timer fires mid-update and reverts, then the
  # update finishes on top of the revert. The new version is live, unverified,
  # with nothing armed behind it — and a health check now decides nothing.
  # UPDATE clearing the timer state is the stub's way of saying "the timer
  # fired and reverted while I was still running".
  write_config gw "UPDATE=\"echo inactive > '$TEST_TMP/timer-state'\""
  run "$REVERTII" update gw
  [ "$status" -eq 4 ]
  [[ "$output" == *"fired while UPDATE was still running"* ]]
  [[ "$output" == *"move the slow part"* ]]
  [[ "$output" == *"PREPARE"* ]]
}

@test "a snapshot that produces nothing stops the update before it starts" {
  write_config gw 'SNAPSHOT="true"'
  run "$REVERTII" update gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"snapshot produced nothing"* ]]
  ! timer_was_armed
}

@test "a failing snapshot stops the update" {
  write_config gw 'SNAPSHOT="false"'
  run "$REVERTII" update gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"snapshot failed"* ]]
  ! timer_was_armed
}

@test "the update is refused when the timer cannot be armed" {
  # No safety net means no update — the whole premise is that the change is
  # provisional, and it is not provisional if nothing can take it back.
  write_config gw
  touch "$TEST_TMP/systemd-run-fails"
  run "$REVERTII" update gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not arm the revert timer"* ]]
  [[ "$output" == *"refusing to update"* ]]
}

@test "a second update is refused while a revert is still pending" {
  write_config gw
  set_timer_active
  run "$REVERTII" update gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"already has a revert pending"* ]]
}

@test "a failed RESTORE says plainly what state the host is in" {
  # There is no third fallback, so the only useful thing left is an honest
  # report — silence here is how a host ends up in an unknown state unnoticed.
  write_config gw 'HEALTH="false"' 'HEALTH_TIMEOUT=1' 'RESTORE="false"'
  run "$REVERTII" update gw
  [ "$status" -eq 3 ]
  [[ "$output" == *"RESTORE FAILED"* ]]
  [[ "$output" == *"neither the confirmed old state nor a verified new one"* ]]
  [[ "$output" == *"v1.0.0"* ]]
}

@test "confirm disarms the timer and keeps the update" {
  write_config gw
  set_timer_active
  run "$REVERTII" confirm gw
  [ "$status" -eq 0 ]
  [[ "$output" == *"keeps the update"* ]]
  timer_was_disarmed
}

@test "confirm without a pending revert says there is nothing to confirm" {
  write_config gw
  run "$REVERTII" confirm gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"no pending revert"* ]]
}

@test "a timer-fired revert is logged differently from a requested one" {
  # This line is how she reconstructs afterwards, from the journal and without
  # logging in, whether someone decided this or nobody confirmed in time.
  write_config gw
  printf 'snapshot=v1.0.0\narmed_at=1\n' > "$REVERTII_STATE_DIR/gw.state"

  run "$REVERTII" revert gw --from-timer
  [ "$status" -eq 0 ]
  [[ "$output" == *"revert timer fired"* ]]
  [[ "$output" == *"not confirmed"* ]]

  printf 'snapshot=v1.0.0\narmed_at=1\n' > "$REVERTII_STATE_DIR/gw.state"
  run "$REVERTII" revert gw
  [ "$status" -eq 0 ]
  [[ "$output" == *"on request"* ]]
  [[ "$output" != *"timer fired"* ]]
}

@test "revert without a recorded snapshot refuses rather than inventing one" {
  write_config gw
  run "$REVERTII" revert gw
  [ "$status" -eq 2 ]
  [[ "$output" == *"nothing was recorded to go back to"* ]]
}

@test "dry-run changes nothing and arms nothing" {
  write_config gw
  run "$REVERTII" update gw --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would run"* ]]
  ! timer_was_armed
  [ ! -f "$REVERTII_STATE_DIR/gw.state" ]
}

@test "a job is probed by running it once and reading its result" {
  write_config backup 'KIND=job' 'HEALTH=""' 'UNIT=restic-backup.service' 'PROBE_RUN=yes'
  run "$REVERTII" update backup
  [ "$status" -eq 0 ]
  [[ "$output" == *"starting restic-backup.service once"* ]]
  grep -q 'systemctl start restic-backup.service' "$STUB_LOG"
}

@test "a job whose probe run fails is reverted" {
  # The quiet failure this exists for: a backup job broken by an update says
  # nothing until the day someone needs the backup.
  write_config backup 'KIND=job' 'HEALTH=""' 'UNIT=restic-backup.service'
  set_unit_result failed
  run "$REVERTII" update backup
  [ "$status" -eq 1 ]
  [[ "$output" == *"last result: failed"* ]]
  [[ "$output" == *"reverted to v1.0.0"* ]]
}

@test "check runs the health check and changes nothing" {
  write_config gw
  run "$REVERTII" check gw
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy"* ]]
  ! timer_was_armed
}

@test "status reports whether anything is awaiting confirmation" {
  write_config gw
  run "$REVERTII" status gw
  [ "$status" -eq 0 ]
  [[ "$output" == *"no update awaiting confirmation"* ]]

  set_timer_active
  printf 'snapshot=v1.0.0\narmed_at=%s\n' "$(date +%s)" > "$REVERTII_STATE_DIR/gw.state"
  run "$REVERTII" status gw
  [[ "$output" == *"revert in"* ]]
  [[ "$output" == *"v1.0.0"* ]]
}

@test "list shows configured services and flags pending reverts" {
  write_config gw
  write_config backup 'KIND=job' 'HEALTH=""' 'UNIT=x.service'
  run "$REVERTII" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"gw"* ]]
  [[ "$output" == *"backup"* ]]

  set_timer_active
  run "$REVERTII" list
  [[ "$output" == *"revert pending"* ]]
}
