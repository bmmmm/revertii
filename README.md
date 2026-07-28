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

1. **prepare** — build, pull, fetch: anything that does not touch what is running
2. **snapshot** the current state
3. **arm** the dead man's switch
4. **apply** the update
5. **check** health against a deadline
6. healthy → **disarm**; unhealthy → **revert now**, without waiting for the timer

Step 3 sits before step 4 deliberately. If the update takes the host with it,
steps 5 and 6 never run — the armed timer is the only thing left, and it is
already in place. That is the whole difference from a wrapper that updates and
then checks: this one survives its own failure.

Step 1 exists so the armed window stays short. A build can take longer than the
whole revert window, and a build *inside* that window is a race: the timer
fires mid-build and reverts, then the finished build switches to the new
version on top of the revert — live, unverified, with nothing armed behind it.
Put slow work in `PREPARE`; it runs before anything is armed. revertii also
detects the race after the fact and exits `4` rather than running a health
check whose result no longer controls anything.

The same idea as Cisco's `reload in 5` or `iptables-apply`: the change is
provisional until proven, and proving it is a separate, explicit act.

## Install

Root is not required. revertii follows whoever runs it: as root it uses
`/etc/revertii`, `/var/lib/revertii` and systemd's system scope; as an
ordinary user it uses XDG paths and `--user` units throughout.

**Rootless** — for podman containers under systemd `--user` units, which is
where an agent-triggerable command belongs:

```console
$ install -Dm755 bin/revertii ~/.local/bin/revertii
$ mkdir -p ~/.config/revertii && chmod 700 ~/.config/revertii
$ install -m600 examples/self-built-podman.conf ~/.config/revertii/myapp.conf
$ loginctl enable-linger "$USER"
```

That last line matters more than it looks. Without lingering, `--user` units
stop when the session ends — so the revert timer would die exactly when nobody
is logged in, which is the situation this whole tool is built for.

**As root** — for system units:

```console
# install -Dm755 bin/revertii /usr/local/bin/revertii
# mkdir -p /etc/revertii && chmod 700 /etc/revertii
# install -m600 examples/gateway.conf /etc/revertii/gateway.conf
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
| `PREPARE` | optional; build/pull/fetch — runs *before* the timer is armed |
| `SNAPSHOT` | prints the current state on stdout — a tag, a commit, an image ID |
| `UPDATE` | applies the update |
| `RESTORE` | puts back `$REVERTII_SNAPSHOT` |
| `HEALTH` | succeeds only when the service really answers (`daemon`) |
| `UNIT` | the systemd unit whose result is the signal (`job`) |
| `HEALTH_TIMEOUT` | how long to keep checking before calling it failed |
| `REVERT_AFTER` | the dead man's switch; must exceed `HEALTH_TIMEOUT` |
| `PROBE_RUN` | run a `job` once after updating to see whether it still works |
| `MAX_AGE` | how old a job's last success may be |

Two variables are handed *to* your commands rather than read from them:
`$REVERTII_SNAPSHOT` (in `RESTORE`) and `$REVERTII_SYSTEMD_SCOPE` (everywhere).

**Use single quotes.** The file is sourced, so a double-quoted
`$REVERTII_SNAPSHOT` expands to nothing at that moment rather than at revert
time — leaving a `RESTORE` that looks correct and silently restores whatever
is already running. revertii warns when `RESTORE` never mentions the variable,
which is the usual symptom.

The snapshot reaches `RESTORE` through the environment and is never spliced
into the command string, so a tag containing a space or a quote cannot change
what runs.

**Write `systemctl $REVERTII_SYSTEMD_SCOPE …`, not bare `systemctl`.** Your
commands face the same root-or-not question revertii answered at startup, and
they cannot see how it was answered — so revertii hands it to them:
`--system` as root, `--user` otherwise. A hardcoded `systemctl` always talks
to the system manager, which a rootless user cannot reach. That failure is
worst inside `RESTORE`, where it lands *after* the old state is back: old
image on disk, broken version still running, and a revert that ran to the
end. revertii warns about a scopeless `systemctl` when it is running rootless.

See [`examples/`](examples/) for a containerised gateway, a restic backup job,
a native unit running from a git checkout, and an image you build yourself.

For a self-built image, snapshot the **image ID**, not the tag: a rebuild moves
the tag, so a tag recorded beforehand points at the new image afterwards, and
restoring it would restore exactly what you were undoing. The old image stays
in local storage, which makes rollback for a self-built image easier than for a
pulled one — nothing has to come back from a registry.

## Commands

```console
revertii update <service>    snapshot, update, verify, revert if unhealthy
revertii check <service>     run the health check only, change nothing
revertii revert <service>    restore the last snapshot now
revertii confirm <service>   disarm the pending revert, keep the update
revertii status <service>    what is armed, what was snapshotted, when
revertii list                configured services
```

`--dry-run` prints what would happen and changes nothing.

Exit codes: `0` fine, `1` reverted, `2` refused to act, `3` the restore itself
failed, `4` the update outlived its own timer. The last two are the ones to
alert on: `3` means the host is running neither the old state nor a verified
new one, and `4` means a revert already happened and the update then completed
on top of it. Both say so rather than exiting quietly.

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

Most of the suite stubs `systemctl` and `systemd-run`, which is what makes it
runnable off Linux — and is the right boundary for behaviour that is
revertii's own: it asserts what revertii *asked* systemd to do, including that
the timer is armed before the update runs.

`test/systemd.bats` covers what a stub cannot answer, against a real user
manager: that systemd accepts the transient timer, that the unit does not
outlive itself, and — the case the tool exists for — that an `UPDATE` which
kills revertii mid-run still ends in a revert, carried out by the timer with
no process left to do it. It skips itself where there is no systemd, and CI
fails if it skipped there, because a skip reads as a pass.

Both of the bugs that file has found so far were invisible to the stubs,
which had faithfully recorded a correct request: systemd deferring a 5-second
timer to 21 (`AccuracySec` defaults to a minute), and the timer unit starting
with an environment that did not carry `REVERTII_CONFIG_DIR`, so a revert on
relocated paths woke up and found nothing.

Security issues go [privately](SECURITY.md), never in a public issue — and note
that a service config is executed as root by design, so it belongs in a
root-owned directory.

## Support

If this is useful to you, [ko-fi.com/bmabma](https://ko-fi.com/bmabma).

## License

GPL-3.0-or-later.
