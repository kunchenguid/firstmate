# Review standards for this repository

Rules the reviewer asked to have written down are recorded here so that a decision already resolved on one pull request is not re-litigated on the next one.
Each rule states the conditions it depends on because dropping those conditions turns a decision into a blind spot.

## A user-facing surface is not automatically a `VISION.md` violation

`VISION.md` says that the user talks to the Director and that workers report through the Director instead of addressing the user directly.
That rule protects who is answerable for delegated work.
It governs workers reporting outward, not every read-only interface the user may choose to operate.

Do not flag a user-facing front end as violating that rule while all of these conditions hold:

- It never claims to be the Director and says so in its own instructions.
- It has no tool that can change a project, merge, discard work, or grant authority.
- Work that cannot be answered from existing records is handed to the Director and announced as a handover rather than performed or claimed.

Any failed condition is worth flagging clearly.
A front end that gains a write tool, drops the disclaimer, or reports delegated work as its own is the case this rule exists to catch.

Such a front end may hold read access to user records and can therefore return a substantive answer without acting as the Director.
`bin/fm-voice-relay.py` is the surface on which this distinction was established.
