# revertii

Update a service, and take the update back automatically if the service does
not come back healthy.

Built for the case where fixing it by hand is not an option, because you just
updated the thing your access runs through. The safety net is not "someone
notices and rolls back" — it is a timer armed on the host *before* the change,
which reverts on its own if nobody confirms in time.

```console
# revertii update gateway
snapshot: v2.3.1
revert armed: 300s from now (revertii confirm gateway to keep the update)
checking health (deadline 90s)…
not healthy within 90s — reverting
restoring: v2.3.1
reverted to v2.3.1
```

## Why the ordering is the design

1. **snapshot** the current state
2. **arm** the dead man's switch
3. **apply** the update
4. **check** health against a deadline
5. healthy → **disarm**; unhealthy → **revert now**, without waiting for the timer

Step 2 sits before step 3 deliberately. If the update takes the host with it,
steps 4 and 5 never run — the armed timer is the only thing left, and it is
already in place. That is the whole difference from a wrapper that updates and
then checks: this one survives its own failure.

The same idea as Cisco's `reload in 5` or `iptables-apply`: the change is
provisional until proven, and proving it is a separate, explicit act.

## Install

```console
# install -m 755 bin/revertii /usr/local/bin/revertii
# mkdir -p /etc/revertii && chmod 700 /etc/revertii
# install -m 600 examples/gateway.conf /etc/revertii/gateway.conf
```

Needs bash, systemd (for `systemd-run`) and whatever your own config commands
use. Nothing else — no runtime, no packages, no build.

## Two kinds of service, two meanings of healthy

This distinction is the one that is easy to get wrong, and getting it wrong is
silent.

**`KIND=daemon`** — healthy means *answers right now*. `HEALTH` is retried
until the deadline, because "not up yet" and "not coming up" look identical
for the first few seconds. Check something the service has to actually
respond to; `systemctl is-active` alone will call a wedged process healthy.

**`KIND=job`** — a periodic job has no "now" to probe. Between runs, not
running *is* healthy. The signal is its last result and how old that is, and
because a fresh update may not have run yet, `PROBE_RUN=yes` starts it once on
purpose and waits for the outcome.

An untested backup job is the failure this exists for: it says nothing until
the day you need the backup.

## Configuration

One file per service in `/etc/revertii/<name>.conf`, sourced as shell — so it
can hold real commands, which is necessary because "how do I restore this" is
not expressible as a data value. That also makes it as privileged as a script:
revertii refuses to read a config that is group- or world-writable.

| Key | |
| --- | --- |
| `KIND` | `daemon` or `job` |
| `SNAPSHOT` | prints the current state on stdout — a tag, a commit, a version |
| `UPDATE` | applies the update |
| `RESTORE` | puts back `$REVERTII_SNAPSHOT` |
| `HEALTH` | succeeds only when the service really answers (`daemon`) |
| `UNIT` | the systemd unit whose result is the signal (`job`) |
| `HEALTH_TIMEOUT` | how long to keep checking before calling it failed |
| `REVERT_AFTER` | the dead man's switch; must exceed `HEALTH_TIMEOUT` |
| `PROBE_RUN` | run a `job` once after updating to see whether it still works |
| `MAX_AGE` | how old a job's last success may be |

**Use single quotes.** The file is sourced, so a double-quoted
`$REVERTII_SNAPSHOT` expands to nothing at that moment rather than at revert
time — leaving a `RESTORE` that looks correct and silently restores whatever
is already running. revertii warns when `RESTORE` never mentions the variable,
which is the usual symptom.

The snapshot reaches `RESTORE` through the environment and is never spliced
into the command string, so a tag containing a space or a quote cannot change
what runs.

See [`examples/`](examples/) for a containerised gateway, a restic backup job,
and a native unit running from a git checkout.

## Commands

```console
revertii update <service>    snapshot, update, verify, revert if unhealthy
revertii check <service>     run the health check only, change nothing
revertii revert <service>    restore the last snapshot now
revertii confirm <service>   disarm the pending revert, keep the update
revertii status <service>    what is armed, what was snapshotted, when
revertii list                configured services
```

`--dry-run` prints what would happen and changes nothing. Exit codes: `0`
fine, `1` reverted, `2` refused to act, `3` the restore itself failed — that
last one means the host is running neither the old state nor a verified new
one, and it says so rather than exiting quietly.

## Letting an agent trigger it

The reason this is a separate tool rather than something an agent does
directly: an agent that can run `revertii update gateway` cannot install
arbitrary things, cannot restart arbitrary units, and cannot leave a broken
version running. The worst it can do is cause a five-minute outage that
resolves itself.

Grant that one command — via sudoers, or by having the agent write a request
that a host-side unit picks up — and keep the rest of the host out of reach.

## What it does not do

Not a deployment tool: it runs the `UPDATE` command you wrote, it does not
know how to build, push or orchestrate anything. Not a monitor: it checks
health during an update window and then stops looking — for continuous
watching, point your existing monitoring at the same `HEALTH` command.

## Development

```console
$ shellcheck bin/revertii
$ bats test/
```

The tests stub `systemctl` and `systemd-run`, which is what makes them
runnable off Linux — and is also the right boundary on Linux: they assert what
revertii *asked* systemd to do, including that the timer is armed before the
update runs. Whether systemd then honours a transient timer is systemd's
business.

## License

GPL-3.0-or-later.
