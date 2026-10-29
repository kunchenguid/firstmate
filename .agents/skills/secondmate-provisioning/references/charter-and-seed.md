# Charter and seed

Load this with the `secondmate-provisioning` skill before scaffolding a charter, seeding or validating a home, or setting the secondmate harness pin.

Scaffold a secondmate charter with:

```sh
bin/fm-brief.sh <id> --secondmate {<project>...|--no-projects}
```

The scaffold writes a charter brief instead of a task brief.
Set `FM_SECONDMATE_CHARTER='<charter>'` to fill the charter text and `FM_SECONDMATE_SCOPE='<scope>'` when the routing scope differs.
If you scaffold without `FM_SECONDMATE_CHARTER`, replace the `{TASK}` placeholder before seeding.
Pass `--no-projects` instead of a project list to scaffold a project-less charter for a domain whose subject is the firstmate repo itself, whose home is a firstmate worktree and whose crews take pooled worktrees of the same repo.
`--no-projects` is mutually exclusive with a project list, and omitting both still fails loudly, so an accidental omission is never mistaken for a deliberate project-less seed.
Re-seeding a populated home as project-less is refused non-destructively when the home contains project clones or `data/projects.md` entries.
Retire or clean that home first, and re-scaffold a stale project-bearing charter with `--no-projects` before seeding.
Keep custom charter text focused on the persistent responsibility, available project clones, and genuinely domain-specific hard rules.
The scaffolded charter, later copied to `data/charter.md`, owns the standard lifecycle and escalation wording.
Preserve the generated charter sections unless the domain genuinely needs a hard rule.

Provision a local persistent home and registry entry after the charter is filled:

```sh
bin/fm-home-seed.sh <id> <home|-> {<project>...|--no-projects}
```

Provision a whole remote home through its configured SSH host with:

```sh
bin/fm-remote-home-seed.sh <id> <ssh-alias> <remote-root> <remote-home> {<project>[=<origin-url>]...|--no-projects}
```

You resolve each project's origin yourself - from the captain, the project registry, a clone that exists elsewhere, `gh-axi`, or an explicit paste - and name it as `<project>=<origin-url>`; the seed validates and transports what you supply.
A remote seed therefore creates nothing in this home beyond the route, the charter brief, and a launch record once it is launched: never clone a project into `projects/`, initialize no-mistakes here, or run a fleet sync just to seed a remote secondmate.
A bare `<project>` remains a convenience for a project this home already has cloned, whose configured origin is read instead.
[`docs/remote-secondmates.md`](../../../../docs/remote-secondmates.md#provision-a-route) owns the rest of the operator contract, and [`bin/fm-project-origin-lib.sh`](../../../../bin/fm-project-origin-lib.sh) owns the accepted origin forms.
Pass `--no-projects` in the project position to seed the project-less home described above; the same mutual-exclusion and fail-loud-on-omission rules apply.
It may only seed a home with no project clones or project-registry entries, and refuses conversion of populated homes without changing them.
`-` durably leases a fresh firstmate worktree via `treehouse get --lease` under the secondmate id.
The lease survives with no live process and is never recycled by later `treehouse get` or `prune`.
The slot stays reserved across restarts until the lease is released.
Release happens only on explicit retirement or seed rollback, never on routine restart or recovery.

`bin/fm-home-seed.sh` copies the charter into the secondmate home as `data/charter.md`.
It also writes the gitignored `.fm-secondmate-parent` durable binding before the required `.fm-secondmate-home` identity marker; the parser header in [`bin/fm-secondmate-parent-lib.sh`](../../../../bin/fm-secondmate-parent-lib.sh) owns the record contract, and both files must remain in place.
[`docs/configuration.md`](../../../../docs/configuration.md#choose-the-secondmate-harness) owns the primary's secondmate runtime pins, per-mate overrides, launch precedence, compatibility, and malformed-file refusal.
Select the registered mate's id when resolving its pin; [`bin/fm-harness.sh`](../../../../bin/fm-harness.sh)'s header owns the resolver commands.

`bin/fm-home-seed.sh` refuses to copy a missing or placeholder charter.

Direct seed without a preexisting brief requires `FM_SECONDMATE_CHARTER`.
Run `bin/fm-home-seed.sh validate` when checking registry integrity; its header owns the complete validation and refusal mechanics.

Seeding is transactional.
If validation, cloning, no-mistakes initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.

Secondmate project lists may include `no-mistakes` and `direct-PR` projects only.
`local-only` projects stay with the main firstmate.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.
