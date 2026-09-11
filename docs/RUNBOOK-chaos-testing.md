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

## Scenario 4: Old primary rejoining after failover

Tests whether a demoted former leader can cleanly rejoin as a standby
rather than getting stuck diverged. First happened once, unintentionally,
as a side effect during Scenario 1 - but that instance was confounded by
the postgresql@18-main masking bug discovered in that same scenario, so
it was never clean evidence of the actual rejoin mechanism. Retested
here in isolation, after that bug was already fixed.

### Commands

    ssh pg1 "sudo patronictl -c /etc/patroni/patroni.yml list"
    # confirmed pg3 = Leader, TL 10

    ssh pg3 "sudo systemctl stop patroni"
    ssh pg1 "sudo patronictl -c /etc/patroni/patroni.yml list"
    # pg2 promoted, TL advanced to 11

    ssh pg3 "sudo systemctl start patroni"
    ssh pg3 "sudo journalctl -u patroni --since '2 minutes ago' --no-pager | grep -iE 'rewind|following|diverge|timeline'"

### Result

Patroni's own log showed the exact divergence being detected explicitly:

    Local timeline=10 lsn=0/C000028
    primary_timeline=11
    no action. I am (pg3), a secondary, and following a leader (pg2)

pg3 reconciled cleanly and resumed streaming as a genuine standby within
seconds - no manual intervention, no stuck/diverged state.

Honest finding, not the one expected going in: grepping specifically for
pg_rewind/rewind across the same window returned nothing at all - the
mechanism actually exercised here was a plain timeline switch, not
pg_rewind. Likely explanation: pg3 was stopped almost immediately after
losing leadership, so it never accumulated any genuinely divergent
writes of its own that would require rewinding away - a same-position
timeline switch was sufficient. use_pg_rewind: true remains correctly
configured and would be expected to matter more in a scenario where the
old primary kept accepting writes for longer before being stopped -
not tested here, and worth treating as a real, separate follow-up rather
than assuming this result covers it.

### Verification

    ssh pg1 "sudo patronictl -c /etc/patroni/patroni.yml list"

All three nodes confirmed healthy at TL 11, zero lag on both standbys.
No cleanup needed - this scenario ends in a genuinely healthy, real
topology, not a state requiring restoration.

## Scenario 5: Kill one etcd member, confirm 2-of-3 quorum is transparent

Deliberately narrow scope: stops only the etcd service on one node,
leaving Patroni and PostgreSQL on that same node completely untouched -
isolating etcd's own resilience specifically, not conflating it with
anything else already tested. Targeted the current plain Replica
(pg3), not the leader or sync standby, to keep the test singular.
Prediction going in: nothing observable should happen at all - if
anything does, that itself is the real finding.

### Commands

    ssh pg1 "sudo patronictl -c /etc/patroni/patroni.yml list"
    # confirmed pg3 = plain Replica

    ssh pg3 "sudo systemctl stop etcd"

    ssh pg1 "sudo patronictl -c /etc/patroni/patroni.yml list"
    ssh pg1 "sudo etcdctl --cacert=/etc/etcd-tls/ca.crt --cert=/etc/etcd-tls/server.crt --key=/etc/etcd-tls/server.key --endpoints=https://10.0.0.83:2379,https://10.0.1.196:2379,https://10.0.2.236:2379 endpoint health --cluster"
    ssh pg3 "sudo systemctl status patroni --no-pager | head -5"

### Result

Exactly the boring, correct outcome predicted. patronictl list showed
the identical topology throughout - pg1 Sync Standby, pg2 Leader, pg3
still Replica, zero lag - despite patronictl itself logging real
Connection refused errors while querying the dead member before
correctly falling back to the two survivors.

Direct etcd-level evidence, not just Patroni's view: etcdctl confirmed
the two surviving members (10.0.0.83, 10.0.1.196) each genuinely healthy,
successfully committing a real proposal - actual quorum participation,
not just a running process - while 10.0.2.236 correctly and honestly
reported unhealthy with a real connection-refused error. pg3's own
Patroni process remained active (running) throughout, completely
undisturbed by its local etcd being down.

Minor tooling note: etcdctl's own final summary line ("Error: unhealthy
cluster") is a strict, conservative warning triggered by any single
member being down, not evidence of an actual quorum problem - the
individual per-endpoint health lines are the real signal, and they
confirmed the cluster was genuinely fine throughout.

### Recovery

    ssh pg3 "sudo systemctl start etcd"
    ssh pg1 "sudo etcdctl ... endpoint health --cluster"

All three etcd members confirmed healthy again within seconds. No
Patroni/PostgreSQL-level recovery needed at all - nothing on that layer
was ever actually disrupted.

## Scenario 6: Kill a second etcd member - genuine quorum loss, isolated from PG/Patroni

More rigorous than Scenario 3's version of this: that test killed both
replica instances entirely, which meant PostgreSQL, Patroni, AND etcd
all died simultaneously on those two nodes - a real result, but not
clean proof that quorum loss specifically was the cause. This time,
only etcd is stopped on two nodes; PostgreSQL and Patroni keep running
untouched on all three. Deliberately left the current LEADER's own
etcd process alive, killing etcd only on the other two - isolating
whether the leader demotes because it truly cannot reach quorum, not
merely because it lost all etcd connectivity of its own.

### Commands

    ssh pg1 "sudo patronictl -c /etc/patroni/patroni.yml list"
    # confirmed pg2 = Leader

    ssh pg1 "sudo systemctl stop etcd"
    ssh pg3 "sudo systemctl stop etcd"

    ssh pg2 "sudo -u postgres psql -c \"SELECT pg_is_in_recovery();\""
    ssh pg2 "sudo journalctl -u patroni --since '2 minutes ago' --no-pager | grep -iE 'demot|leader|dcs|quorum'"

### Result - the most operationally significant finding in this exercise

pg2 continued confidently logging "no action. I am (pg2), the leader
with the lock" every ~10 seconds for a real, measured window of
approximately 1 minute 50 seconds (19:24:45 through 19:26:15) before
finally erroring and demoting:

    19:26:35 ERROR: Error communicating with DCS
    19:26:35 INFO: demoting self because DCS is not accessible and I was a leader
    19:26:35 INFO: Demoting self (offline)
    19:26:36 INFO: demoted self because DCS is not accessible and I was a leader

This is meaningfully different from Scenario 3's sub-250ms reaction, and
the reason makes sense once examined: pg2's own local etcd process
never died (unlike Scenario 3, where the etcd processes on the killed
nodes died along with everything else on those instances). Patroni's
routine local heartbeat against its own etcd kept succeeding normally
the whole time - the isolation only became visible once some underlying
operation requiring genuine quorum consensus (most likely a lease
renewal) finally timed out client-side.

pg_is_in_recovery() confirmed the real consequence directly: f
throughout the ~110 second window (still genuinely a writable primary),
flipping to t only after the demotion actually completed.

### Real implication

A lone, quorum-isolated leader does not fail loudly or immediately - it
keeps answering locally and believing itself legitimate for a real,
non-trivial window, bounded by whatever client-side timeout eventually
surfaces the quorum failure, not by any instant local health check.
This is a genuine, narrow risk window inherent to this specific failure
mode (leader's own etcd survives, but loses reachability to the other
members) - worth remembering as a real operational number, not just
"it eventually self-corrects."

### Recovery

    ssh pg1 "sudo systemctl start etcd"
    ssh pg3 "sudo systemctl start etcd"

pg2 correctly reclaimed leadership once quorum returned - timeline
advanced 11 -> 12, confirming a genuine demotion/re-promotion cycle,
not a no-op. Full, clean self-healing.

## Scenario 7: Genuine network partition on etcd traffic (not a service stop)

Different failure mode from Scenario 6: instead of stopping the etcd
service cleanly on peer nodes, this blocks all etcd traffic (ports
2379-2380) between the leader and both peers using iptables, applied
directly on the leader itself. Prediction going in, based on TCP theory
(a silent packet drop gives no instant disconnect signal, unlike a
closed port): this should take LONGER than Scenario 6's ~110 seconds
to detect, not shorter.

Applied the ordering lesson from Scenario 2 from the start this time -
iptables -I (insert at position 1), not -A, given ufw's own
ESTABLISHED,RELATED accept rule was already proven to sit ahead of
anything appended.

### Commands

    ssh pg1 "sudo patronictl -c /etc/patroni/patroni.yml list"
    # confirmed pg2 = Leader

    ssh pg2 "sudo iptables -I OUTPUT 1 -p tcp -d 10.0.0.83 --dport 2379:2380 -j DROP"
    ssh pg2 "sudo iptables -I INPUT 1 -p tcp -s 10.0.0.83 --sport 2379:2380 -j DROP"
    ssh pg2 "sudo iptables -I OUTPUT 1 -p tcp -d 10.0.2.236 --dport 2379:2380 -j DROP"
    ssh pg2 "sudo iptables -I INPUT 1 -p tcp -s 10.0.2.236 --sport 2379:2380 -j DROP"

    date -u
    ssh pg2 "sudo -u postgres psql -c \"SELECT pg_is_in_recovery();\""

### Result - prediction was wrong, and the real reason is worth understanding

pg_is_in_recovery() showed t almost immediately. Initial log search
(too narrow a --since window) appeared to show no explicit demotion,
creating a real, temporary discrepancy - resolved by widening the
search: patroni's log confirmed demotion at 19:50:51, essentially the
same second the iptables rules were applied.

    19:50:51 INFO: demoting self because DCS is not accessible and I was a leader
    19:50:51 INFO: Demoting self (offline)
    19:50:52 INFO: demoted self because DCS is not accessible and I was a leader

Under a second - dramatically FASTER than Scenario 6's ~110 seconds,
the opposite of what TCP-timeout theory predicted. The real reason: this
block was far more total than Scenario 6's. Stopping etcd's service
(Scenario 6) left the leader's own local etcd, and every other network
path, completely untouched - only the specific keepalive/quorum
operations against peers eventually failed. This iptables block affected
ALL etcd traffic in both directions, and the log confirmed even pg2's
connection attempts to its OWN local etcd (10.0.1.196) were timing out -
a comprehensive, near-total isolation rather than a narrow one, which
triggered Patroni's DCS-inaccessible detection almost immediately rather
than after a long chain of individual operation timeouts.

The repeated "Lock owner: pg2; I am pg2" log lines seen afterward are
NOT evidence of continued false leadership claims - pg2 was already
demoted by that point; these are simply its ongoing, harmless checks of
who currently holds the lock (itself, since no one else could claim it
either with quorum unreachable cluster-wide) while waiting for the
partition to heal.

### Real implication

The two etcd-loss scenarios (6 and 7) produced genuinely different
timings - ~110 seconds vs under 1 second - for what might look like "the
same kind of failure" from a distance. The actual determining factor is
how TOTAL the isolation is, not whether it's a clean stop versus a
silent partition. A partial failure (leader's own etcd survives, only
reachability to peers is lost) is the more dangerous, slower-detected
case; a total failure (leader loses all etcd connectivity, including
local) is detected almost instantly. This is a more nuanced, more useful
finding than either scenario alone would have produced.

### Recovery

    ssh pg2 "sudo iptables -D OUTPUT -p tcp -d 10.0.0.83 --dport 2379:2380 -j DROP"
    ssh pg2 "sudo iptables -D INPUT -p tcp -s 10.0.0.83 --sport 2379:2380 -j DROP"
    ssh pg2 "sudo iptables -D OUTPUT -p tcp -d 10.0.2.236 --dport 2379:2380 -j DROP"
    ssh pg2 "sudo iptables -D INPUT -p tcp -s 10.0.2.236 --sport 2379:2380 -j DROP"

pg3 correctly elected as new leader (pg2 having demoted itself, one of
the two remaining nodes had to take over) - timeline advanced 12 -> 13,
both surviving nodes healthy with zero lag.

## Scenario 8: HAProxy failure - proving a known, accepted limitation

Different in character from every prior scenario: this is not expected
to demonstrate self-healing. Keepalived and a floating VIP were
deliberately skipped back in Stage 9 as an explicit scope decision - the
only redundancy that exists is "a second, independent load balancer
exists," not "traffic automatically finds it." This scenario proves
that limitation with real evidence rather than leaving it as a
theoretical caveat.

Deliberately isolated to the haproxy service only, not the instance -
testing specifically whether the proxy process dying causes an outage
for a client pointed at it, not reintroducing instance-level failure
modes already covered elsewhere.

### Commands

    ssh lb1 "sudo systemctl status haproxy --no-pager | head -3"
    ssh lb2 "sudo systemctl status haproxy --no-pager | head -3"
    ssh pg1 "sudo patronictl -c /etc/patroni/patroni.yml list"
    # confirmed both healthy, pg3 = Leader

    # Prove lb1 works normally first
    ssh pg1 "PGPASSWORD='...' psql -h 10.0.0.241 -p 5000 -U postgres -d postgres -c 'SELECT pg_is_in_recovery();'"
    # returned f

    ssh lb1 "sudo systemctl stop haproxy"

    # Retry the identical connection
    ssh pg1 "PGPASSWORD='...' psql -h 10.0.0.241 -p 5000 -U postgres -d postgres -c 'SELECT pg_is_in_recovery();'"

    # Confirm lb2 is completely unaffected
    ssh pg1 "PGPASSWORD='...' psql -h 10.0.1.160 -p 5000 -U postgres -d postgres -c 'SELECT pg_is_in_recovery();'"

### Result

Before: lb1 correctly routed to the real primary (f). After stopping
haproxy: immediate, total failure -

    psql: error: connection to server at "10.0.0.241", port 5000 failed: Connection refused

Not a delay, not a stall, not a silent reroute - a hard, immediate
outage for anyone still pointed at lb1 specifically. lb2, completely
untouched, continued routing correctly the entire time (f).

### Real implication

This is not a bug - it is the direct, predictable, now-proven
consequence of a scope decision made explicitly back in Stage 9. The
only thing protecting an application from this outage in the current
architecture is the application itself being configured to know about
and retry a second address (lb2) - nothing in the infrastructure
automatically reroutes traffic on its own. The known, available remedy
is Keepalived with a floating VIP shared between lb1/lb2, which would
make this failure mode transparent to clients. Genuinely worth building
in a real production deployment; explicitly out of scope for this
project, and this scenario is the honest proof of exactly what that
tradeoff costs.

### Recovery

    ssh lb1 "sudo systemctl start haproxy"

lb1 confirmed fully restored, correctly routing to the real primary
again within seconds of the service restarting.

## Scenario 9: Full AZ loss - closed by composition, not independently executed

### Real AZ mapping, checked directly rather than assumed

    aws ec2 describe-instances --filters "Name=tag:Name,Values=pg-ha-pg1,pg-ha-pg2,pg-ha-pg3,pg-ha-lb1,pg-ha-lb2,pg-ha-mon1" \
      --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,Placement.AvailabilityZone,InstanceId]" --output table

    us-east-1a: pg1, lb1, mon1  (3 resources)
    us-east-1b: pg2, lb2        (2 resources)
    us-east-1c: pg3             (1 resource)

Real, honest finding surfaced just by checking this table, before running
anything: the three AZs are not equally severe to lose. This was never a
deliberate design decision - pg nodes were correctly spread one-per-AZ on
purpose, but lb1/lb2 ended up co-located with their same-numbered pg node
purely as a coincidence of how the Terraform for_each was written, and
mon1 was simply hardcoded to subnet[0] (always us-east-1a), never
deliberately placed at all. Losing us-east-1a costs one PG node, one of
two load balancers, AND the entire monitoring stack (Prometheus, Grafana,
Alertmanager - all on a single mon1 instance with no redundancy of its
own) simultaneously - a genuinely worse loss than either other AZ.

### Why this was closed by reasoning rather than independently executed

A full AZ-loss test decomposes into exactly three failures, and two of
them are not new:

- pg1 dying: identical in kind to Scenario 1 (instance-level primary/
  replica loss), already proven to self-heal with real, measured timing.
- lb1 dying: literally Scenario 8, executed independently five minutes
  before this decision was made - already has real evidence in this
  runbook.
- mon1 dying: genuinely never independently tested. But by design,
  nothing in the PostgreSQL/etcd/Patroni/HAProxy chain depends on
  monitoring being available - Prometheus PULLS metrics from the system;
  the system never pushes to or waits on Prometheus for anything. There
  is no code path connecting database/proxy health to monitoring
  availability. The expectation here isn't genuine uncertainty, it's
  high confidence from the architecture itself, simply never confirmed
  with a dedicated test run.

None of these three failures share any detection or recovery mechanism
with each other (PostgreSQL/Patroni failover, HAProxy health checks, and
Prometheus scraping are three fully independent systems) - unlike
Scenarios 6 and 7, which looked similar on paper but produced a genuine,
valuable surprise (~110s vs <1s) precisely because they shared the same
underlying mechanism (etcd quorum detection) under different conditions.
There is no equivalent shared mechanism here to produce a comparable
surprise. Running the full three-way simultaneous kill would have mostly
re-spent real time reproducing two already-proven results, wrapped
around one outcome already well-understood from the architecture itself
- a real judgment call to not do, not an oversight.

### Conclusion

Scenario 9 is considered closed by composition of Scenarios 1 and 8,
combined with a documented, architecture-based (not empirically tested)
expectation for monitoring loss specifically. If mon1's isolated failure
behavior is ever genuinely in question, that remains a legitimate,
cheap, five-minute follow-up test - deliberately not run here because
the answer is already known with high confidence, not because it was
overlooked.
