# SPDX-License-Identifier: GPL-3.0-or-later
# Test scaffolding: a throwaway config/state dir plus stubbed systemd.
#
# The stubs are what make this testable off Linux at all, but they earn their
# keep on Linux too: they record what revertii ASKED systemd to do, which is
# the part worth asserting. Whether systemd then honours a transient timer is
# systemd's business, not this tool's.

setup_stub_env() {
  export TEST_TMP="$BATS_TEST_TMPDIR/revertii"
  export REVERTII_CONFIG_DIR="$TEST_TMP/etc"
  export REVERTII_STATE_DIR="$TEST_TMP/var"
  export STUB_LOG="$TEST_TMP/systemd.log"
  mkdir -p "$REVERTII_CONFIG_DIR" "$REVERTII_STATE_DIR" "$TEST_TMP/bin"

  # Default stub behaviour, overridable per test through these files.
  echo inactive > "$TEST_TMP/timer-state"
  echo success > "$TEST_TMP/unit-result"

  # The stub tracks timer state rather than just logging, because revertii now
  # asks "is my timer still there" after the update — a stub that always says
  # "no" would make every normal run look like the timer had fired.
  cat > "$TEST_TMP/bin/systemd-run" <<'STUB'
#!/bin/sh
echo "systemd-run $*" >> "$STUB_LOG"
[ -f "$TEST_TMP/systemd-run-fails" ] && exit 1
echo active > "$TEST_TMP/timer-state"
exit 0
STUB

  cat > "$TEST_TMP/bin/systemctl" <<'STUB'
#!/bin/sh
echo "systemctl $*" >> "$STUB_LOG"
case "$1 $2" in
  "is-active --quiet")
    # `is-active` is asked both about the revert timer and, for jobs, about the
    # unit being probed. Only the timer's answer is scripted here; a probed job
    # reports "not running" so the health check can move on to its result.
    case "$3" in
      revertii-revert-*) [ "$(cat "$TEST_TMP/timer-state")" = active ] && exit 0 || exit 3 ;;
      *) exit 3 ;;
    esac
    ;;
esac
case "$1 $2" in
  "stop revertii-revert-"*) echo inactive > "$TEST_TMP/timer-state" ;;
esac
case "$1" in
  show)
    for a in "$@"; do
      case "$a" in
        -p) ;;
        Result) cat "$TEST_TMP/unit-result" ;;
        ExecMainExitTimestampMonotonic) echo 0 ;;
      esac
    done
    exit 0
    ;;
esac
exit 0
STUB

  chmod +x "$TEST_TMP/bin/systemd-run" "$TEST_TMP/bin/systemctl"
  export PATH="$TEST_TMP/bin:$PATH"
  export REVERTII="$BATS_TEST_DIRNAME/../bin/revertii"
}

# Write a service config. Extra lines are appended, so a test can override any
# default by passing e.g. 'REVERT_AFTER=1'.
write_config() {
  local name="$1"; shift
  {
    echo 'KIND=daemon'
    echo 'SNAPSHOT="echo v1.0.0"'
    echo 'UPDATE="true"'
    echo 'RESTORE="true"'
    echo 'HEALTH="true"'
    echo 'HEALTH_TIMEOUT=5'
    echo 'HEALTH_INTERVAL=1'
    echo 'REVERT_AFTER=60'
    for line in "$@"; do echo "$line"; done
  } > "$REVERTII_CONFIG_DIR/$name.conf"
  chmod 600 "$REVERTII_CONFIG_DIR/$name.conf"
}

timer_was_armed() { grep -q '^systemd-run .*--on-active' "$STUB_LOG"; }
timer_was_disarmed() { grep -q '^systemctl stop revertii-revert-' "$STUB_LOG"; }
set_timer_active() { echo active > "$TEST_TMP/timer-state"; }
set_unit_result() { echo "$1" > "$TEST_TMP/unit-result"; }
