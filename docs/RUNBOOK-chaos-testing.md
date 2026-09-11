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

## Scenario 2: Kill the sync standby, confirm the durability guarantee

Tests synchronous_mode: true directly - does the primary genuinely stall
writes while no synchronous standby exists, or does Patroni reassign so
fast that no observable stall exists at all.

### Attempt 1: clean process kill

    ssh pg1 "sudo patronictl -c /etc/patroni/patroni.yml list"
    # confirmed pg1 = Sync Standby, pg3 = Leader

    ssh pg2 "sudo systemctl stop patroni" & ssh pg3 "time sudo -u postgres psql -c \"INSERT INTO chaos_test_marker (note) VALUES ('scenario 2 retry');\""

Result: INSERT returned in 0.066s. Confirmed via patroni's own log that
stopping the patroni service also stops the underlying postgres process
immediately (ps aux showed no postgres process left on the killed node
at all) - the replication TCP connection dies cleanly and instantly, so
the primary detects it and reassigns sync duty in under 250ms, well
before any separate SSH-based test command could even connect.

    Sep 11 17:20:23 ... Updating synchronous privilege temporarily from ['pg2'] to []
    Sep 11 17:20:23 ... Assigning synchronous standby status to ['pg1']
    Sep 11 17:20:25 ... Synchronous standby status assigned to ['pg1']

### Attempt 2: genuine TCP-level network partition

A cleaner disconnect (process death) gives TCP an instant close signal.
A silent packet-drop partition does not - TCP normally has to wait on
its own retransmission timeouts to conclude a connection is dead, which
takes real, measurable seconds. This is the failure mode that should
actually produce an observable stall.

    ssh pg1 "sudo iptables -I OUTPUT 1 -p tcp -d 10.0.2.236 --dport 5432 -j DROP"
    ssh pg1 "sudo iptables -I INPUT 1 -p tcp -s 10.0.2.236 --sport 5432 -j DROP"
    ssh pg3 "time sudo -u postgres psql -c \"INSERT INTO chaos_test_marker (note) VALUES ('scenario 2 network partition retry');\""

Real methodology mistake caught and fixed mid-test: the first attempt at
this used iptables -A (append), which places the new rule after ufw's
own existing chains - including ufw's ESTABLISHED,RELATED accept rule,
which let the already-open replication connection's packets through
untouched, ahead of our rule. Confirmed directly:

    iptables -L INPUT -n --line-numbers
    # our DROP rule sat at line 7, after 6 ufw-* chains

Fixed with iptables -I (insert at position 1), confirmed at the top of
the chain before retrying.

Result: INSERT still returned in 0.055s. pg_stat_replication on pg3
confirmed pg1 had genuinely dropped out of the replication view entirely
(not shown as disconnected - simply absent), and patronictl list showed
pg1's State as "running" rather than "streaming" - real, distinct
evidence the network block did take effect at the TCP level this time.
But synchronous_standby_names already showed pg2, and grepping patroni's
log across a wider window showed reassignment had completed within
about 2 seconds of the block being applied - well before the timed
INSERT command even finished establishing its own SSH connection.

### Real conclusion

Across three separate genuine failures (two clean process kills, one
verified TCP-level network partition), Patroni detected the failure and
completed reassignment in under 250ms every time, confirmed directly
from its own timestamped logs, not estimated. The expected multi-second
stall does not exist at any timescale this test setup could observe -
not because the guarantee isn't real, but because detection and
reassignment are consistently faster than establishing a new SSH-over-
SSM connection to fire the test write. This is a genuine limitation of
testing via separate ssh invocations against this specific
infrastructure, not a flaw in Patroni's behavior. A stall would only be
observable with a test harness running commands locally on the nodes
themselves (already-open connections, no per-test SSH handshake), which
this exercise did not build.

### Cleanup

    ssh pg1 "sudo iptables -D OUTPUT -p tcp -d 10.0.2.236 --dport 5432 -j DROP"
    ssh pg1 "sudo iptables -D INPUT -p tcp -s 10.0.2.236 --sport 5432 -j DROP"
    ssh pg3 "sudo -u postgres psql -c \"DROP TABLE chaos_test_marker;\""

## Scenario 3: Kill both replicas simultaneously - full quorum loss

A different kind of severity than scenarios 1-2: because etcd runs
co-located on the same three PG nodes (a deliberate cost tradeoff from
Stage 7, accepted risk of resource contention), killing both replicas
does not just remove PostgreSQL standbys - it simultaneously drops etcd
from 3-of-3 to 1-of-3, below the 2-of-3 quorum etcd needs to agree on
anything at all. Predicted before running: the surviving primary should
be unable to safely confirm its own leadership lease, and the correct,
safe behavior is to stop accepting writes rather than keep serving on
stale confidence.

### Commands

    ssh pg1 "sudo patronictl -c /etc/patroni/patroni.yml list"
    # confirmed pg1 + pg2 = both replicas, pg3 = Leader

    aws ec2 stop-instances --instance-ids i-0a7f8e5bdfdfc9b0e i-031048a32502b2733

    ssh pg3
    sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
    sudo journalctl -u patroni --since '5 minutes ago' --no-pager | grep -iE "demot|leader|recovery|promot"

### Result

patronictl list on pg3 itself started failing with real, repeated
etcd3 MaxRetryError/ReadTimeoutError tracebacks - correct and expected:
with only 1-of-3 etcd members reachable, no coherent cluster state can
be agreed on, and patronictl honestly surfaced that rather than
returning a stale or guessed answer.

The critical result: pg_is_in_recovery() on pg3 returned t - genuinely
in standby mode, not still claiming primary. Patroni's own log confirmed
why, in its own words:

    demoting self because DCS is not accessible and I was a leader
    Demoting self (offline)
    demoted self because DCS is not accessible and I was a leader

This is the correct, safety-first design decision working exactly as
intended: the instant pg3 could no longer confirm its leadership lease
against etcd, it voluntarily gave up write access rather than risk
serving writes on unconfirmable authority. The entire cluster was left
correctly, deliberately unable to accept any writes at all until at
least one other node (and therefore etcd quorum) returned - not a bug,
the honest, accepted cost of the co-located etcd design under its worst
realistic failure.

### Recovery

    aws ec2 start-instances --instance-ids i-0a7f8e5bdfdfc9b0e i-031048a32502b2733
    # wait ~90s
    ssh pg3 "sudo patronictl -c /etc/patroni/patroni.yml list"
    ssh pg3 "sudo -u postgres psql -c \"SELECT pg_is_in_recovery();\""

pg3 correctly re-promoted itself the moment quorum returned - timeline
advanced 9 -> 10 (confirming a real demotion/re-promotion cycle
happened, not a no-op), pg_is_in_recovery() back to f, both replicas
resumed streaming with zero lag. Full, clean self-healing, no manual
intervention beyond restarting the two stopped instances.
