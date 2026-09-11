# Decision: Cross-Region DR Deliberately Not Built

Stage 14 in the original roadmap called for cross-region disaster
recovery. Deliberately skipped, with reasoning recorded here rather
than silently omitted.

## Options considered

1. A full, continuously-running standby cluster in a second AWS region
   - most complete, textbook answer
   - real, ongoing cost: a second VPC, more EC2 instances, another NAT
     gateway - roughly doubling this project's AWS footprint
   - real complexity: cross-region streaming replication has genuine
     latency challenges not present in the current single-region,
     multi-AZ design

2. S3 Cross-Region Replication of the pgBackRest backup bucket, plus a
   tested, documented restore procedure into a fresh DR-region instance
   - genuinely cheap - the real backup produced in Stage 10 was 43.7MB;
     replicating something that size costs pennies a month, not a real
     budget line
   - directly reuses everything already built and proven in Stage 10
     (real physical backups, a genuinely tested point-in-time restore)
   - not a continuously-running standby - RTO would be "time to spin up
     a fresh instance and restore," not "instant failover"

3. Skip entirely, document the tradeoff

## Decision: option 3

The deciding factor was not primarily AWS cost - option 2's actual
dollar cost is negligible. The real cost is engineering time and
effort, and the marginal value of that effort was judged low relative
to what this project has already built and proven:

- Real physical backups, WAL archiving, and a genuinely executed,
  verified point-in-time restore (docs/RUNBOOK-pitr-restore-drill.md)
- Real streaming replication and automatic failover, proven across
  multiple scenarios, not just configured
- Nine documented chaos-testing scenarios
  (docs/RUNBOOK-chaos-testing.md) showing exactly how this system
  behaves under real failure, including two scenarios that directly
  contradicted initial predictions and were resolved with real evidence

Every capability a real DR strategy would actually be built from -
physical backups, WAL shipping, restore procedures, failover mechanics -
already exists and is already proven in this project. The marginal
credibility gained from literally having a second AWS region running is
small compared to what already exists; the marginal effort to build and
properly document it is real and was judged better spent on Stage 15
(production-readiness review) instead.

## What this means in practice

If asked to design cross-region DR for this architecture, the honest
answer draws directly on what already exists: extend the pgBackRest S3
target with Cross-Region Replication, maintain a documented (and
periodically drilled) restore procedure into the second region, and
size the RPO/RTO tradeoff around how much WAL-replication lag is
acceptable - the same fundamentals proven in Stage 10, applied to a
second region rather than genuinely built and running here.
