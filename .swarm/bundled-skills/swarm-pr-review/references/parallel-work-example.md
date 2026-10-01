# Parallel-work supersession example (relocated from SKILL.md, issue #2859 F0)

### Example: parallel swarm superseded local fix work

```
PARALLEL WORK CHECK (pre-fix):
- Branch: copilot/fix-legacy-hive-data-migration
- Local HEAD: 3c04997c fix: resolve PR #1238 review findings
- Remote HEAD: 79d7ec64 fix(knowledge-migrator): harden legacy migration loop
- Diverged: yes (remote is 2 commits ahead with more comprehensive fix)
- New commits on remote: 2
- Parallel swarm work detected: yes (different author)
- Decision: abandon-use-remote
- Rationale: Remote added 17 unit tests + try/catch error handling that
  surpassed my planned batch-rewrite. Verified by re-running the test suite:
  remote has 25/25 passing, my local plan would have produced 9/9.
```

Worked PARALLEL WORK CHECK transcript: remote supersession with an
abandon-use-remote decision.
