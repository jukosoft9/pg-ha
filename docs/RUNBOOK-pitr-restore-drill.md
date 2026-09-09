# PITR Restore Drill — Verified 2026-09-09

## Procedure
1. On the live primary, created a marker table and wrote a timestamped row (Write A).
2. Forced that WAL segment to archive immediately (`pg_switch_wal()`), rather than
   depend on natural rotation timing.
3. Captured `now()` as the restore target — a timestamp after Write A, before
   anything else existed.
4. Waited, wrote a second marker row (Write B), force-archived that segment too.
5. Restored the most recent full backup into an isolated scratch directory
   (`--pg1-path=<scratch>`, never the live PGDATA), targeting the captured timestamp
   (`--type=time --target=...`).
6. Started the restored data directory as a standalone `pg_ctl` instance on a
   different port (5433), with `archive_mode = off` — deliberately never touching
   the live cluster's systemd unit, Patroni, or S3 stanza.
7. Connected read-only (recovery paused automatically at the target) and queried
   the marker table.

## Result
- Write A: present.
- Write B: absent.
- `pg_is_in_recovery()`: true (correctly paused, not promoted).
- PostgreSQL's own log confirmed why: *"recovery stopping before commit of
  transaction 786, time 2026-09-09 18:39:26"* — it identified Write B's exact
  commit time, saw it fell after the target, and stopped before applying it.

This is the actual guarantee PITR makes: not "a backup exists," but "recovery can
be aimed at an exact moment and will stop there precisely" — verified against a
real boundary condition (a write 22 seconds after the target, a second write 16
minutes later), not just a restore-to-latest.

## Cleanup performed
Scratch instance stopped and its data directory deleted; marker table dropped from
the live cluster. No trace of the drill remains on any running node.

## Notes for next drill
- `--delta` on `pgbackrest restore` disables itself if the target directory has
  no `PG_VERSION`/`backup.manifest` yet — harmless when the directory is
  genuinely empty (our case), but worth knowing it's not silently ignoring
  real data.
- Standalone restored instances need explicit isolation: a non-default port,
  and `archive_mode = off` so the scratch instance can never push WAL back into
  the same S3 stanza the live cluster depends on.