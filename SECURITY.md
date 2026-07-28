# Security policy

## Reporting

Report privately through [GitHub's private vulnerability
reporting](https://github.com/bmmmm/revertii/security/advisories/new) — not as
a public issue, and not in a pull request.

Expect a first reply within a week. Single-maintainer project, so that is an
estimate rather than a commitment.

## The trust boundary, stated plainly

**Whoever can write a service config can run commands as whoever runs
revertii.** That is not a flaw to be fixed; it is what the config *is*.
`SNAPSHOT`, `PREPARE`, `UPDATE`, `RESTORE` and `HEALTH` hold shell commands
because "how do I put this back" cannot be expressed as data, and the file is
sourced so those commands can use pipes, redirects and variables like any
script.

**Which is why root is worth avoiding.** revertii does not require it: run as
an ordinary user against systemd `--user` units and rootless podman, and the
blast radius of that boundary is one user account rather than the host. Root
is only needed for system-wide units, where `systemctl restart` needs it
anyway.

Either way, treat a service config exactly as you would treat a script owned
by the account that runs it:

```console
$ chmod 700 ~/.config/revertii && chmod 600 ~/.config/revertii/*.conf
# chown root:root /etc/revertii && chmod 700 /etc/revertii   # if running as root
```

revertii refuses to read a config that is group- or world-writable, which
catches the common mistake but is not a substitute for the directory
permissions above.

## In scope

- **Executing anything the config did not ask for.** The snapshot value in
  particular reaches `RESTORE` through the environment and is never spliced
  into a command string — a tag containing a quote or a semicolon must not be
  able to change what runs. A path around that is a vulnerability.
- **A revert that silently does not revert.** Reporting success while the
  service was left on the unverified version defeats the entire purpose. This
  includes the timer failing to arm without the update being refused.
- **Privilege escalation through the state directory.** `/var/lib/revertii`
  holds the snapshot a later revert acts on; if an unprivileged user can write
  it, they choose what root restores.
- **The permission check being bypassable** — e.g. through a symlink, a
  race between the check and the source, or a mode the check does not catch.

## Not in scope

- **The commands in your own config.** revertii runs what you wrote, as you
  wrote it. A destructive `RESTORE` is a bug in your config.
- **A service that is compromised rather than broken.** The health check asks
  whether a service answers, not whether it is trustworthy. A backdoored image
  that passes its health check will be kept.
- **Anything requiring root to begin with.** If an attacker can already edit
  root-owned files, they do not need revertii.
- **systemd's behaviour.** revertii asks `systemd-run` for a transient timer;
  whether systemd honours it is systemd's business. A host where transient
  units do not fire is a host where this tool cannot work — and it will refuse
  to update rather than proceed without a way back.

## Supported versions

The tip of `main`. No maintained release branches.
