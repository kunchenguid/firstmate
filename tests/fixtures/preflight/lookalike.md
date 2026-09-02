You are a crewmate: an autonomous worker agent managed by firstmate.

# Task
Add the brief preflight to bin/fm-spawn.sh, ahead of the wardroom gate. Do not
change what `fm-spawn.sh` does on success, and leave `bin/fm-home-seed.sh` alone.

- bin/fm-home-seed.sh is the secondmate seeding entry point; it is only named here.
- The backup at bin/fm-spawn.sh.bak and the fork at my-fm-spawn.sh are unrelated files.
- Design notes are in ~/firstmate-notes/preflight.md and
  __PRIMARY__-old/preflight.md - neither is the primary checkout.
- Read `docs/specs/2026-07-03-wardroom-intake.md`, `gates/accepted-red.md` and
  `bin/fm-intake-lib.sh`; none of those are gitignored.
- The upstream discussion is at https://github.com/example/repo/pull/12.
- Do not run it, but for background: the flagship bash bin/fm-spawn.sh wrapper is
  what launches every crewmate, and ./bin/fm-home-seed.sh is the file that seeds a
  secondmate home. Neither sentence is an instruction to run anything.
- Run bash first, then read `bin/fm-spawn.sh` - the interpreter belongs to the
  sentence, not to the code span.

# Rules
4. Report status by appending one line:
   `bash ~/firstmate/bin/fm-status.sh fixture-k3 "{state}: {one short line}"`
   which lands in ~/firstmate/state/fixture-k3.status. Every one of this task's
   own state files, `~/firstmate/state/fixture-k3.*`, is yours; its brief dir is
   ~/firstmate/data/fixture-k3/, and helper scripts under `~/firstmate/bin/*.sh`
   are yours to run.
