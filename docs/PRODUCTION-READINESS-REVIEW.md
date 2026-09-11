# Production Readiness Review

An honest assessment of this platform against real production standards,
referencing actual evidence already produced by this project rather than
restating unverified claims. Where something has been proven, the proof
is cited directly. Where something is a known gap, it is stated plainly.

## Architecture Overview

A 3-node PostgreSQL 18 cluster (one primary, two standbys, one AZ each)
managed by Patroni for automatic failover, coordinated through a
co-located 3-node etcd cluster for distributed consensus. PgBouncer pools
connections on each PG node; HAProxy (2 nodes) routes write traffic to
whichever node Patroni's REST API currently reports as primary, and read
traffic across the standbys. pgBackRest handles physical backups and WAL
archiving to S3. A dedicated monitoring node runs Prometheus, Grafana,
and Alertmanager, scraping metrics from every tier. Terraform provisions
all infrastructure; Ansible configures it; GitHub Actions runs
terraform validate/fmt and ansible-lint on every push. Internal TLS
(a self-signed CA generated once, per-node leaf certificates) secures
every service-to-service connection - PostgreSQL, etcd, Patroni's REST
API, and PgBouncer.

## High Availability and Failover

Not a design claim - proven through nine documented chaos-testing
scenarios (docs/RUNBOOK-chaos-testing.md), each with real commands,
real log evidence, and real timing data:

- Hard instance-level primary failure: clean failover, exact promotion
  timestamp captured from Patroni's own history (Scenario 1)
- Sync standby failure and the synchronous_mode: true durability
  guarantee: reassignment consistently completed in under 250ms across
  three separate real failures - fast enough that the expected
  measurable write-stall could never actually be observed with this
  project's own tooling, an honest methodological finding in itself
  (Scenario 2)
- Full etcd quorum loss (both replicas killed): the surviving primary
  correctly, voluntarily demoted itself - "demoting self because DCS is
  not accessible and I was a leader" - rather than risk serving writes
  on unconfirmable leadership (Scenario 3)
- Old primary rejoin after failover: clean timeline reconciliation,
  confirmed via Patroni's own divergence-detection log lines
  (Scenario 4)
- Single etcd member loss: fully transparent, zero disruption at any
  layer, confirmed via direct etcd-level health queries, not just
  Patroni's view (Scenario 5)
- Two genuinely distinct etcd quorum-loss timings, directly contrasted:
  ~110 seconds when a leader's own etcd stays alive but loses
  reachability to peers (Scenario 6), versus under 1 second when
  isolation is total (Scenario 7) - a real, nuanced, evidence-based
  finding that contradicted the initial prediction going in

Known, deliberate limitation, also proven rather than assumed: HAProxy
has no floating VIP (Keepalived was explicitly scoped out in Stage 9).
Scenario 8 proved this produces an immediate, total "Connection
refused" for any client still pointed at the specific load balancer
whose HAProxy process dies - the only protection is the client itself
knowing to retry a second address. This is a real, documented
production gap, not an oversight.

## Data Durability and Recovery

Physical backups via pgBackRest to S3, with continuous WAL archiving
(archive_mode/archive_command pushed through patronictl edit-config,
since Patroni owns postgresql.conf dynamically - not templated by hand).
Authentication to S3 uses the EC2 instance's IAM role exclusively - no
static AWS credentials anywhere in this project.

Not just configured - genuinely tested. The PITR restore drill
(docs/RUNBOOK-pitr-restore-drill.md) wrote two timestamped marker rows,
force-archived each WAL segment, then restored into a fully isolated
scratch instance targeting a timestamp between the two writes.
PostgreSQL's own recovery log confirmed the precise mechanism: it
identified the second write's exact transaction and commit time, saw it
fell after the target, and explicitly stopped before applying it. The
restored instance showed the first marker present, the second absent -
direct proof PITR lands at an exact point, not just "restore succeeds."

Real, known gap: backups exist only in the same AWS region as the
primary cluster. See docs/DECISION-disaster-recovery.md for the
reasoning behind not building cross-region replication of this backup
data - a genuine limitation, deliberately accepted, not overlooked.

## Security

- TLS on every internal connection: PostgreSQL, etcd (client and peer),
  Patroni's REST API, PgBouncer - all using a self-signed internal CA
  generated once and never leaving the control machine, with per-node
  leaf certificates carrying the correct SAN (both hostname and IP)
- All secrets (database passwords, replication credentials, the etcd
  cluster token) held in Ansible Vault, encrypted at rest, verified
  never committed in plaintext anywhere in git history (checked via
  git log --all -p across every commit, not just current state)
- Defense-in-depth firewalling: AWS security groups plus host-level ufw
  on every node - a pattern that directly caused, and then caught, four
  separate real incidents across this build (PostgreSQL's port,
  etcd's ports, Patroni's REST API, and later the LB tier's exporter
  ports) where the security group allowed traffic but ufw silently
  blocked it, or vice versa. Each was found by actually exercising the
  real cross-node path, not by inspecting configuration
- IAM least-privilege: the node role's S3 policy is scoped to exactly
  the backup bucket, nothing broader
- SSH hardened (password auth and root login both disabled) on every
  node; all administrative access via SSH-over-AWS-Session-Manager, no
  direct SSH ports ever exposed to the internet
- No secrets in the CI pipeline: ansible-lint and terraform validate
  both run without any AWS credentials at all (terraform init
  -backend=false), by design

Real, known gap: the internal CA's root key has a 10-year validity with
no rotation procedure defined or tested. Per-node leaf certificates are
90 days, following the correct long-root/short-leaf pattern, but nothing
in this project automates or has ever tested actually rotating them
before expiry.

## Observability

Full metrics coverage: node_exporter on all 6 hosts, postgres_exporter
and pgbouncer_exporter on all 3 PG nodes, HAProxy's native Prometheus
support (chosen deliberately over the officially retired standalone
haproxy_exporter, confirmed via its own GitHub release notes), and
Patroni's own built-in /metrics endpoint scraped over TLS. All 17 scrape
targets confirmed UP, not just configured - a real security-group gap
between the LB tier and the monitoring host was found and fixed
specifically because Prometheus's own targets page showed it failing,
the same "actually exercise the real path" pattern that caught every
other cross-node gap in this build.

The full alert pipeline (Prometheus -> Alertmanager) was proven
end-to-end with a real, deliberately triggered failure - not a config
inspection: stopped an exporter, watched the alert transition
Inactive -> Pending -> Firing (confirming the for: duration correctly
prevents a single missed scrape from paging), confirmed the identical
alert with correct labels appeared in Alertmanager, then confirmed both
systems independently returned to a clean state on recovery.

Grafana dashboards are provisioned as code (a datasource YAML file, not
manual UI clicks), matching this project's rebuild-from-scratch
requirement.

Real, significant gap, stated plainly: exactly one alert rule exists in
this entire project - TargetDown (up == 0). There is no alerting on
replication lag, disk space, connection saturation approaching
max_connections, checkpoint frequency, or transaction ID wraparound
age - the metrics for most of these are already being scraped by
postgres_exporter, but no rules have been written against them. A real
production deployment of this architecture would need a materially
larger alert rule set before the phrase "we have monitoring" means
anything close to "we would actually get paged before this becomes an
outage."

Real, undocumented single point of failure, surfaced incidentally
during Scenario 9's AZ-mapping check rather than called out on its own:
Prometheus, Grafana, and Alertmanager all run on one instance (mon1)
with zero redundancy. Losing that one node does not affect the database
cluster's own availability (Prometheus only pulls metrics; nothing in
the PG/etcd/Patroni/HAProxy chain depends on it), but it does mean
losing all visibility into the system at exactly the moment something
else might be going wrong - a real, meaningful gap for a genuine
production deployment, never independently tested (see
docs/RUNBOOK-chaos-testing.md, Scenario 9's closing section for why).

## Automation and Infrastructure as Code

Terraform for all AWS infrastructure, Ansible for all configuration,
both fully idempotent and confirmed as such repeatedly - most notably
when a restructured, previously-orphaned role was re-run against the
live, already-configured cluster and reported changed=0 across every
task on all three nodes.

CI (GitHub Actions) runs terraform fmt/validate and ansible-lint at the
'production' profile on every push. Genuinely proved its value more than
once, not just theoretically: caught two real, previously-invisible
undeclared Ansible collection dependencies (community.general,
ansible.posix) that had been silently present on the local development
machine's own accumulated install history and were never actually
declared anywhere in the project - exactly the "works on my machine"
failure mode CI exists to catch, confirmed the first time this project
was ever evaluated on a genuinely clean environment.

Two real structural gaps were found and permanently fixed during chaos
testing, not initial development - both documented in
docs/RUNBOOK-chaos-testing.md's Scenario 1 entry: PGDG's default
PostgreSQL cluster silently re-enabling itself on all three nodes after
a reboot (fixed by switching disable: false to masked: true, immune to
re-enablement rather than just currently off), and an entire Ansible
role that had been silently orphaned from site.yml since Stage 8,
discovered only because a real instance restart exposed it - a genuine
reminder that static code review alone did not catch this, and the only
real proof of completeness would be a full destroy/rebuild from zero,
which remains untested (see Recommended Next Steps).

## What Has Never Been Tested

Stated plainly, not buried in a gaps list: this project has proven
correctness under failure extensively - nine real chaos scenarios, a
real PITR restore, real automatic failover. It has never once proven
performance under real load. Every test in this entire build ran
against an essentially idle cluster. There is no data on:

- How failover timing changes under genuine write throughput, versus
  the near-instant reassignments observed against an idle cluster
- Whether PgBouncer's pool sizing (default_pool_size: 25) is remotely
  correct for any real workload, since it has never been tested against
  more than a handful of manual test connections
- Whether HAProxy's health-check interval and fall/rise thresholds
  produce acceptable failover behavior under real concurrent traffic
- Actual backup/restore duration and performance characteristics at any
  data volume beyond the trivial size this learning cluster has ever
  held (the one real backup taken was 43.7MB)
- Resource contention between co-located etcd and PostgreSQL under real
  I/O pressure - a deliberate, accepted cost tradeoff from Stage 7 that
  has never been stress-tested to see where it actually breaks

"Production ready" without load testing is an honest overstatement of
what this review can actually claim - this system is proven resilient,
not proven to perform.

## Recommended Next Steps for a Real Production Deployment

In rough priority order:

1. A materially larger Alertmanager rule set - replication lag, disk
   space, connection saturation, wraparound age, checkpoint frequency -
   before "we have monitoring" is a meaningful production claim
2. Real load testing (pgbench or equivalent) to validate every timing
   and sizing assumption currently based only on idle-cluster behavior
3. A real destroy/rebuild-from-zero test - the strongest possible proof
   that everything documented as "automated" genuinely is, given that
   the orphaned-role gap found during chaos testing was invisible to
   code review and only surfaced through an actual instance restart
4. Keepalived + a floating VIP across the two load balancers (Stage 9's
   documented, deliberate gap - Scenario 8 proved its real cost)
5. Monitoring redundancy, or at minimum an documented, accepted decision
   about mon1 being a real single point of failure for visibility
6. A TLS certificate rotation procedure, tested at least once, before
   the first 90-day leaf certificate expiry becomes a real incident
7. Cross-region DR, if the business requirement actually calls for it -
   see docs/DECISION-disaster-recovery.md for what this would build on

## Summary

This is a genuinely production-shaped platform - real HA, real
automatic failover, real tested backups and PITR, real TLS everywhere,
real CI catching real bugs, and nine chaos-testing scenarios with actual
evidence rather than assumed outcomes. It is not, as of this review,
production-ready in the full sense of that phrase - it has never faced
real load, its alerting covers one condition out of many that matter,
and its own monitoring stack is a single point of failure. Every gap
above is named because it was found or reasoned through directly during
this project's own build and testing process, not identified from a
generic checklist.
