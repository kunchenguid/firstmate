# reproduce: addyosmani/agent-skills

A position this adapter inserts before `work`, composed only when the routing table says the task is a bug fix.
`bin/fm-best-practices.sh` composes each `##` block below into the brief, where the block's heading is its id and a routing row in `manifest.json` may select it.

## reproduce
When the task is a bug fix, make the failure happen first, as `debugging-and-error-recovery`'s Step 1 says: reproduce it as close to how the user hit it as possible, as a failing check, before touching code.
A bug that will not reproduce is documented as such in your done summary rather than fixed blind.
