---
name: deploy
description: >-
  Report what is merged but not yet live, and say what is waiting on the captain.
  Use when the captain invokes /deploy or asks what is not deployed, what is waiting to go live, or whether the site is up to date.
  Everything that can go live without him already has; this is only the report.
user-invocable: true
metadata:
  internal: true
---

# /deploy

The captain's standing instruction: everything that can be deployed without him
is deployed automatically the moment it merges. `/deploy` is how he checks, and
the list he sees must contain only what he actually has to decide.

## Do this

For every project in `data/projects.md` that has a deploy policy at
`config/deploy-policy/<project>`, run:

```
bin/fm-deploy-status.sh <project>
```

Run it for each such project. A project with no policy is not deploy-managed
from this home; do not mention it.

## Report it like this

The script already speaks the captain's language. Relay what it says, and add
nothing mechanical: no shas in the lead sentence, no unit names, no paths on the
host, no talk of policies, ranges, or classification.

- **Everything is live, nothing is waiting.** One line: everything merged is
  already live. Stop there.
- **Things are waiting only on the captain.** List exactly those, each with the
  concrete reason it needs him (the design surface it touches). Then say plainly
  that he can approve them and they go live. Nothing else belongs in this list.
- **Something could not be checked** - the machine was unreachable, or what is
  live is not on the main line of work. Say that as the finding, name the
  project, and treat it as needing attention. Never report an unknown as "up to
  date".

If the captain approves, deploy exactly what he approved:

```
bin/fm-deploy.sh <project> <sha> --with-captain-permission "<his own words>"
```

Quote his actual words. The flag by itself is not permission, and the deploy
records those words. Give him the outcome in one line afterwards.

If a deploy went wrong, the previous version goes back with one command:

```
bin/fm-deploy.sh <project> --rollback
```

## What not to do

Do not deploy a change that touches a captain-reserved surface without his word
in this session, and never treat a standing `yolo` posture as that word: `yolo`
governs merging, and this gate is about what the captain sees on his own site.
Do not deploy while the project reports a run in progress - the script refuses,
and that refusal is a finding, not an obstacle.
