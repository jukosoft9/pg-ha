# Chaos Testing — Game Day Log

Systematic, deliberate failure injection against the running cluster, each
scenario documented with the real commands run, what was expected, and what
actually happened - reproducible, not just remembered.

## Scenario 1: Hard-kill the primary at the instance level

Genuinely more severe than a graceful "systemctl stop" (tested back in
Stage 8) - the entire EC2 instance goes down with no clean shutdown
signal at all.

### Commands

    # Confirm current leader
    aws ec2 describe-instances --filters "Name=tag:Name,Values=pg-ha-pg2" \
      --query "Reservations[0].Instances[0].InstanceId" --output text
    # -> i-031048a32502b2733

    # Kill it
    aws ec2 stop-instances --instance-ids i-031048a32502b2733

    # Watch from a survivor
    ssh pg1
    sudo patronictl -c /etc/patroni/patroni.yml list

    # Get exact promotion timing
    sudo patronictl -c /etc/patroni/patroni.yml history

    # Restore
    aws ec2 start-instances --instance-ids i-031048a32502b2733

### Result

pg3 promoted to Leader, pg1 correctly demoted to Sync Standby, timeline
advanced 8 -> 9. patronictl history confirmed the exact promotion
timestamp (2026-09-11T14:45:02), captured directly from Patroni's own
record rather than estimated from watching a terminal. pg2 correctly
dropped out of patronictl list entirely (not shown as unreachable -
genuinely absent), consistent with a hard kill versus a graceful stop.

patronictl history itself, while pg2 was down, printed real
ConnectTimeoutError lines while querying etcd on pg2's address before
falling back to the two surviving etcd members and returning a correct
answer anyway - direct, visible proof of 2-of-3 etcd quorum tolerating a
member loss, not just a claim.

## Real finding: the PGDG default cluster silently re-enables itself

Not a planned scenario - surfaced by scenario 1's restart.

### What happened

pg2, after restarting, showed patronictl list with blank TL and unknown
LSN instead of a normal streaming state. Patroni's own log showed
"password authentication failed for user postgres" - misleading at
first, since it looked like a credential problem. The real cause, found
in PostgreSQL's own log, was different entirely:

    FATAL:  could not create any TCP/IP sockets
    could not bind IPv4 address "0.0.0.0": Address already in use

ps aux confirmed a second, wrong Postgres process running against
/var/lib/postgresql/18/main - PGDG's own default cluster, which Stage 5
explicitly disabled. systemctl is-enabled postgresql@18-main returned
enabled-runtime on all three PG nodes, not just pg2 - a real, fleet-wide,
previously invisible condition. Likely cause: PGDG's package maintainer
scripts re-enabling their own default unit as part of routine package
upgrade housekeeping (this fleet runs unattended-upgrades, security-only)
- with no awareness that we'd deliberately turned it off. Not confirmed
with certainty from apt history, which came back empty; stated as the
leading theory, not a proven fact.

### Fix

disable: false isn't strong enough - it can be silently re-enabled by
something else later. masked: true replaces the unit file with a
symlink to /dev/null, making it structurally impossible to start
regardless of what re-enables it.

    sudo systemctl stop postgresql@18-main
    sudo systemctl mask postgresql@18-main

Applied by hand to all three nodes during the incident, then made
permanent in roles/postgresql/tasks/install.yml (masked: true instead of
enabled: false) so a future rebuild is immune to this from the start.

## Real finding: an entire role had been silently orphaned since Stage 8

Investigating the fix above led to discovering roles/postgresql/ had not
been called by any active play in site.yml since Stage 8 removed it to
avoid conflicting with Patroni's own management - but nothing had
verified whether everything in that removal was actually safe, or
whether some of it was a genuine, still-needed prerequisite.

### Investigation

Five direct greps, not assumptions:

    grep -rln "filesystem:\|ansible.posix.mount\|state: mounted" roles/
    grep -rl "postgresql-tls" roles/ | grep -v "roles/postgresql/"
    grep -rn "5432" roles/*/tasks/firewall.yml
    grep -A5 "bootstrap:" roles/patroni/templates/patroni.yml.j2 | grep -A5 "users:"
    grep -rln "pgdata_mount\|pgwal_mount" roles/patroni/ roles/etcd/

Confirmed real, active gaps: nothing else formats/mounts the storage
volumes, nothing else deploys the actual TLS certificate files (Patroni
and PgBouncer only reference the path), nothing else opens the port 5432
ufw rule, and the chown task that exists elsewhere
(patroni/tasks/decommission.yml) is permanently fenced behind
tags: [never] - meaning it would never run on a real rebuild either.

One thing was confirmed NOT a gap: whether Patroni's own bootstrap
creates the replicator role. Confirmed via Patroni's own official
documentation that this happens automatically from the
postgresql.authentication.replication config already present in
patroni.yml.j2 - no separate task needed. The old hand-rolled
replication_setup.yml task had already been fully superseded since
Stage 8's real bootstrap, safe to delete outright.

### Fix

Deleted five genuinely obsolete task files (initdb.yml,
replica_setup.yml, configure.yml, replica_conninfo.yml,
replication_setup.yml) and their now-unused handler - all superseded by
Patroni's own bootstrap and dynamic config management. Trimmed
roles/postgresql/tasks/main.yml to the five things that are genuinely
still required (storage, package install + mask, firewall, ownership,
TLS deployment) and reactivated the role as a real play in site.yml,
positioned before etcd/Patroni since both depend on it.

### Verification

Ran the reactivated play against all three live PG nodes:

    ansible-playbook site.yml --limit pg1,pg2,pg3 --diff

Result: changed=0 across all three - every task reported ok, proving the
reactivated role is genuinely idempotent against the already-running
cluster, not just theoretically correct. Directly confirmed the mask
state matches by hand afterward:

    ssh pg2
    sudo systemctl is-enabled postgresql@18-main
    # -> masked

### Open item

This was found by accident, via one scenario's side effect, not a
deliberate audit of every role. A full terraform destroy -> terraform
apply -> ansible-playbook site.yml from genuine zero is the only real
proof this (and every other role) is complete - still owed, not yet
done.
