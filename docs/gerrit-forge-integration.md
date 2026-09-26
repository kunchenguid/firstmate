# Gerrit forge integration

This note is the design reasoning for giving Firstmate a forge axis, worked through Gerrit because Gerrit is the case that forces it.
It is written for whoever integrates a forge with Firstmate rather than for the operator of any one fleet, so it argues about axes, vocabulary, and ownership, and never about which projects should be registered how.
Every question it raises is answered, and each decision is stated in the body where the reasoning for it sits rather than collected into a list at the end.

The mechanics it reasons about have their own owners.
[`bin/fm-pr-lib.sh`](../bin/fm-pr-lib.sh) owns the provider-tagged identity and the merge-poll artifacts, [`bin/fm-pr-merge.sh`](../bin/fm-pr-merge.sh) owns merging, [`bin/fm-project-mode.sh`](../bin/fm-project-mode.sh) owns the registered delivery posture, and [`bin/fm-dod-lib.sh`](../bin/fm-dod-lib.sh) owns what a delivery mode tells a worker.
This note asserts the design that the changes following it implement, so it states what the forge field in the registry and the delivery-mode rules that consume it are for, not what they were before.

## 1. Gerrit is not a forge variant

GitHub and GitLab differ in vocabulary, URL shape, and the API each one offers.
Gerrit differs in what the reviewed object *is*, which is not a difference an adapter can absorb.

Branch-shaped review, which is what GitHub and GitLab do, makes the reviewed object a branch plus a request to merge it.
Its identity is the pair of repository and number.
Its history is the branch's commits, preserved as pushed, and a new revision is a new commit appended to the branch.
"The same change" means the same pull-request number, and the content under that number is whatever the branch's tip is now.

Change-shaped review, which is what Gerrit does, makes the reviewed object a single commit carrying a `Change-Id` footer.
Its identity is that footer; the server-assigned change number is only a short handle for it.
A new revision is a new *patch set*: an amended commit that replaces the previous one rather than following it.
"The same change" means the same `Change-Id`, across commits with different hashes and different trees.

Three things follow, and each one breaks an assumption that branch-shaped review lets a tool make for free.

Identity is content-independent and survives rewriting.
A pull request's identity is attached to a ref that accumulates; a change's identity is attached to a footer that travels through `git commit --amend` and `git rebase` unharmed.
The inverse is the sharp edge: regenerating a `Change-Id` does not produce a new revision of the change, it produces a *different* change, and the review history of the original is orphaned.
So the operation that is routine and safe on a branch - rewrite the commit, force-push, same pull request - is the operation that silently discards review state here, and it discards it through a commit-message footer rather than through anything a tool would think to guard.

History is replaced rather than preserved.
There is no accumulated branch on the server whose commits land; there is a sequence of patch sets of which the last one is what merges.
An integration that wants to show "what changed since the last review" is asking a question about two patch sets, not about commits added to a branch.

A branch is not the unit of anything.
A local branch of three commits is three changes related by a parent chain, not one reviewable object.
This is the point at which the branch-shaped assumption stops being a vocabulary mismatch and starts being an arity mismatch: one worker branch no longer maps to one reviewable thing.

### Forks and the magic ref answer the same question

Gerrit has no forks.
A project is one shared repository, and there is no separate namespace a proposer owns.
Next to a branch-shaped forge that reads as a missing feature, and it is better read as the other half of the same design.

Both models exist to answer one question: how does someone propose a change to a branch they cannot write?
A branch-shaped forge answers it with a fork, a repository the proposer does own, from which a pull request points back at the original.
Gerrit answers it with `refs/for/<branch>`, which by construction creates a change and cannot create a branch, so permission to propose is a separate grant from permission to write the target.

`refs/for` is therefore not an odd publication target that happens to stand in for a push plus an API call.
It is the access-control primitive, and change-shaped review is what that primitive produces.
Reading it as a publication quirk is what makes the rest of Gerrit look like a pile of exceptions rather than one decision followed through.

What does *not* differ is worth stating, because it bounds the problem.
Reading review state after publication fits Firstmate's existing record with no new shape.
`bin/fm-pr-lib.sh` already carries a provider-tagged identity of provider, url, host, path, and number, because GitLab had already forced host and an arbitrarily nested path into it, and a Gerrit change URL populates those same fields.
The break is not in watching a change.
It is in making one.

## 2. The vocabulary map

| Term | Branch-shaped (GitHub, GitLab) | Change-shaped (Gerrit) | What that costs an integration |
|---|---|---|---|
| publish | push the branch, then open a pull request: two steps, the second one a forge API call through a vendor CLI | one `git push HEAD:refs/for/<branch>`: creating the change *is* the push | the publish step is a vendor CLI on one side and plain git on the other, so it cannot be a single parameterized command |
| review | comments and approvals attached to the pull request, plus forge CI reporting check runs against the branch | comments and label votes (`Code-Review`, `Verified`) attached to the change; CI votes a label | "checks green" is a label value rather than a set of check runs, and the pipeline's CI step has no check runs to watch |
| merged | the pull request is closed and its content is in the base branch, usually squashed | the change is *submitted*, and its status becomes `MERGED` | "merge" names an action Firstmate performs, while "submit" names one it must not - see section 4 |
| head | a commit hash that identifies what was reviewed and stays valid | a patch-set revision, and every amend or rebase produces a new one | a recorded head quietly becomes the *previously* reviewed content, so a Gerrit task records none |
| number | repository-scoped on GitHub, project-scoped on GitLab; addressing it needs owner and repository, or host and path | server-global; with the host pinned, the number alone names the change | the project path is not part of a Gerrit read at all |

The head row is the one that bites hardest, because it fails quietly.
On GitHub a recorded head stays true: it is the commit that was reviewed and, absent a new push, the commit that will merge.
On Gerrit the same recorded value goes stale on every amend, and a stale value does not look stale - it looks like a perfectly well-formed revision, because it is one.
Anything that compares against it is then comparing against an earlier patch set while believing it is comparing against the change.

### Where today's mode names mislead

Not one of Firstmate's three delivery-mode names refers to a stopping point, and each misses it differently.

`direct-PR` names an artifact.
On a forge with no pull request the name has no referent at all, which is why the natural first rule is to refuse the combination rather than give it a meaning: there is nothing to rename it to from inside the mode's own vocabulary.
But the refusal follows from the name, not from anything the mode does - "push your work and stop without running the pipeline" is a coherent instruction on Gerrit.

`no-mistakes` names a pipeline.
It happens not to name an artifact, which is the only reason it survives the transplant unmodified.

`local-only` names a place, and it is the closest of the three to honest, because where this mode stops is a place.

So the name that blocks Gerrit is blocking it on a noun, and the name that lets Gerrit through does so by accident.
That is a symptom.
Section 3 is the diagnosis.

## 3. The axes and the composition test

Three properties are in play, and they answer three different questions.

- **Mode** is where the worker stops.
- **Forge** is what the publication artifact is, and therefore which tool makes it.
- **Shape** is whether a task's work is published as a stack of changes or as one squashed change.

One test decides whether a property sits on the right axis.
**An axis in the right place composes with every value of the others without special cases.**
A candidate that needs a new value each time some other axis gains one is not an axis at all; it is that other axis wearing this one's name.

### The candidate that fails it

An earlier candidate made shape a mode: `direct-PR` would mean a topic'd stack, and a new `direct-change` would mean a single squashed change.
It fails immediately.
`no-mistakes` needs the same distinction the moment it ships to Gerrit, so it splits too; `local-only` needs it as well, since a ready branch is already either one commit or several.
Three modes become six, and every mode added afterwards arrives needing two names instead of one.
Shape is not varying *with* mode there, it is varying *inside* every value of mode, which is the signature of a property that has been folded into the wrong axis.

### Why shape is not the forge either

Shape already exists on GitHub, it predates Gerrit entirely, and it is load-bearing in four places today:

- `bin/fm-pr-merge.sh` defaults a GitHub merge to `--squash` when the caller selects no method.
- `bin/fm-fleet-sync.sh`'s branch pruning reasons about it explicitly, dropping the ancestry check on the grounds that pull requests in this fleet are squash-merged, so a merged branch is never an ancestor and such a check would prune nothing.
- `bin/fm-teardown.sh`'s landed-work test accepts content present in the default branch precisely because a squash collapses the branch's commits and per-commit patch identities stop matching.
- `bin/fm-ff-lib.sh` reconciles a clean secondmate divergence through a three-way tree proof, as happens after an upstream squash merge.

It appears nowhere in the registry.
A property that four mechanisms depend on, across pruning, teardown safety, merging, and secondmate convergence, and that no project has ever declared, is not a Gerrit concept arriving with Gerrit.
It is an existing axis that has been pinned to one value by assumption for long enough to become invisible.
That it survived being invisible says how rarely it varies, not where it belongs.

### The hinge: pre-publication versus post-publication

Firstmate has no forge property for GitLab and has never needed one.
`bin/fm-pr-lib.sh` derives the provider from the merge-request URL *after the fact*, tagging the stored identity with it, and the work is handed to `glab`; workers create the artifact with the vendor CLI, and `bin/fm-pr-merge.sh` merges through that same CLI.
Firstmate owns none of the mechanics.
Every forge decision it makes, it makes with the URL already in hand.

Gerrit breaks that in exactly one way.
The forge must be known **before** anything is published, because there is no pull request to open.
A worker cannot be told "push your branch and open a pull request, and we will work out the forge from the URL afterwards": the instruction it needs differs before any URL exists, between a push to `refs/for/<branch>` and a push followed by a `gh-axi` call.

That is the whole of what a `forge=` annotation buys: **a pre-publication signal, where GitLab only ever needed a post-publication one.**
Everything downstream of publication - watching, reading state, reporting - continues to work off the provider tag derived from the URL, exactly as it does for GitLab, because by then the URL exists.

### How the forge is known: detected, then proposed for confirmation

The binding is **detected from the project's origin and proposed at intake for confirmation**, rather than declared cold in the registry or inferred silently at use time.
Detection is what every other forge already gets for free, because the URL tells Firstmate what it is dealing with.
Confirmation is what stops a wrong guess from becoming a silent second source of truth, since a mis-detected forge produces a brief that is internally consistent and wrong.
Proposing it at intake also puts the signal where a pre-publication signal has to be, in the brief at scaffold time with no clone read and no network call, while keeping a human at the one point where the evidence can be misread.
The delivery-mode design takes that shape, treating a protocol fact such as an SSH remote on port 29418 or a `refs/for/<branch>` push target as good evidence to propose the binding while refusing to infer it later.

The tool with the broadest forge coverage in this stack corroborates detection, though more narrowly than it first appears to.
no-mistakes binds its provider by calling `DetectProvider(remoteURL)` across the six forges its `Provider` type names - GitHub, GitLab, Bitbucket, Azure DevOps, Forgejo and Gitea - and no project declares its forge anywhere in that scheme.
Only well-known hosts are recognised from the URL alone.
For a host it does not recognise, which is how Gerrit is nearly always deployed, it falls back to machine-local configuration keyed by host: SSH config, then whether the local `glab`, `gh` or `tea` CLI is logged in to that host, then a `FORGEJO_BASE_URL` environment variable, while its per-repository execution context resolves machine-local forge profiles.
What survives as corroboration is exactly one fact: no per-project declaration anywhere in the scheme, across six forges.

The same evidence also bears against detection.
Because it reads per-machine login state, one remote can resolve to different forges on two machines, or to none on a machine where the CLI is not logged in, and that is a genuine argument for declaring the forge rather than detecting it.
It does not overturn the decision, since confirmation at intake is where a misread is meant to be caught, but anyone relying on detection should know it is not purely structural.

#### Could the tool declare its own semantics instead?

That settles where the binding comes from without settling whether a project-level binding is needed at all.
Suppose the forge tool answered the question itself: a `forge-type` subcommand on `gerrit-axi` returning `change`, where a GitHub or GitLab tool would return `branch`.
The appeal is real, and the reasoning behind it is sound as far as it goes.
The origin URL already selects which tool to call, the tool then declares its own semantics, and no project ever carries an annotation that can drift from its remote.

Be precise about what that removes and what it does not.
It removes the per-project declaration, which is the part capable of disagreeing with reality.
It does not remove the mapping, because something must still get from a remote URL to the right tool before any tool can be asked anything, and that something is Firstmate.
The question is therefore not whether Firstmate holds forge knowledge, since it does either way, but whether it holds one thin host-pattern mapping for the whole fleet or one annotation per project.

Framed that way the mapping has a real advantage, for a reason that has nothing to do with Gerrit.
A host pattern is written once and is then either wrong for every project on that host or right for every project on it, which is a failure mode that announces itself on first use.
A per-project annotation can be wrong on exactly one project, which left alone is the failure mode that does not announce itself; intake confirmation is what closes it, because that one project's binding is put in front of a human at the moment it is recorded.
Asking the tool has a cost on the other side: a round trip, because asking the tool means running it, so the answer stops being available at scaffold time without a call, which is the property the pre-publication signal needed to begin with.
Caching the answer recovers that and reintroduces, in smaller form, the staleness the annotation had.

The answer is to keep a per-project binding and not to ask the tool.

That does not reverse the detected-and-confirmed binding above, and the two compose exactly.
Detection proposes, the per-project record is the durable answer that confirmation produces, and the forge tool is never asked what it is.
The earlier decision says where the proposal comes from; this one says where the confirmed answer lives.

It also disposes of the ambient-configuration objection raised just above.
A detector that reads per-machine login state is only ever proposing something a human confirms once, and what is recorded afterwards is a project fact rather than one machine's opinion.
The objection bounds how much weight detection can carry alone, which is the weight the confirmation step already removes.

### Applying "mode is where the worker stops"

Read the modes as stopping points rather than as artifacts and they line up cleanly:

- `local-only` stops at a ready branch and publishes nothing. Nothing about a forge applies, because no artifact is made: `bin/fm-merge-local.sh` fast-forwards the project's *local* default branch, and the intake guidance already allows a `local-only` project to have no remote at all.
- `direct-PR` publishes without the pipeline.
- `no-mistakes` runs the pipeline, then publishes.

On that reading the forge composes with the two modes that publish and is meaningless on the one that does not.
That inverts both rules the delivery-mode design currently carries, which permit `local-only forge=gerrit` as an annotation that changes nothing and refuse `direct-PR forge=gerrit` outright.
The composition test says that is backwards on both counts: the refusal lands on the combination that has a meaning, and the permission on the combination that does not.

The refusal reads as reasonable only because of the name.
"That mode's definition of done is a pull request this forge does not have" is a true statement about the string `direct-PR` and not about the stopping point it names, and section 2 is why those two came apart.

The permission is not merely useless, which is worth being plain about, because an inert annotation in a brief is not inert at landing.
`local-only`'s configured landing is a guarded fast-forward of the project's local default branch.
On a project whose changes are supposed to reach a review server, that landing advances local `main` with content the server has never seen, and the annotation that was supposed to record "this is a Gerrit project" is the one thing in the posture that does not get consulted.

## 4. What Gerrit makes structurally impossible

Three things, and they are not impossible in the same way.
Flattening them into one list of missing features would be the wrong lesson.

**There is no pull-request object.**
Nothing to open, nothing that holds a number before the push, and nothing that carries a description separate from the commit.
The commit message *is* the review description and the `Change-Id` footer *is* the identity, so any design that wants a handle on the reviewed thing before that thing exists cannot have one.
This is a property of Gerrit and no amount of tooling changes it.

**There is no branch on the remote.**
`refs/for/<branch>` is a magic ref rather than a destination: the push creates or updates a change and leaves behind no ref a later fetch can see.
Every mechanism that reasons about a remote branch therefore has no counterpart here - the gone-upstream prune in `bin/fm-fleet-sync.sh`, the remote-reachability leg of `bin/fm-teardown.sh`'s landed-work test, and the `refs/pull/<n>/head` fetch in `bin/fm-review-diff.sh`.
There is no separate namespace either, because there are no forks, so the change is the only remote artifact the work ever has.
The teardown test and the review diff each already have a fallback that reasons about content or about the local branch, and on Gerrit the fallback is not a fallback, it is the only path.
The prune has no fallback at all: a `refs/for/<branch>` push creates no upstream tracking ref, so nothing ever reads `[gone]`, the prune never fires, and ship branches accumulate locally after teardown.
That raises the stakes on the content leg of the landed-work test specifically, since it becomes the sole proof that unlanded work is not about to be discarded.
This is also a property of Gerrit.

The absence of forks also changes who needs what access.
With forks, proposing needs no write access to the target repository at all, because the proposer writes only their own copy.
On Gerrit, proposing requires push access to `refs/for/*` on the one shared repository, so an autonomous worker's identity cannot be confined to a namespace of its own; it holds a grant on the repository everyone else shares.
That is the provisioning consequence, and it is why the vote boundary in section 5 matters more here rather than less: an identity that can already reach the shared repository is held back only by the grants its account does not hold, so the label permissions on that account carry weight a separate namespace would otherwise share.

**The tool Firstmate calls cannot vote, and that is a requirement rather than an accident.**
`gerrit-axi` adds exactly two writes to its queries.
`publish` is one push to `refs/for/<branch>`, and `submit` is one call asking the server to submit one change, which the server may refuse.
Its README states the boundary - "it never votes, replies, sets reviewers, or abandons" - and its own test suite enforces it by failing if `gerrit review`, a REST call to the review endpoint, or a label option on a push appears anywhere in the code.
That tool lives in its own repository, so this design does not change it; section 5 argues why its powers stop where they do.
Firstmate's own refusal to submit is a policy rather than a capability limit, and what it protects is the decisive vote rather than the submit: a submit only succeeds once someone has recorded a `Code-Review+2`, and that vote is a positive attributed claim that a named human approved, read as such by colleagues and by any audit of the repository.
A server that permits self-approval is exactly what makes this a boundary Firstmate chooses rather than one it merely runs into, though the choice covers only Firstmate's own path: the server's label ACL on the worker account is what makes it binding on anything else.

So the first two are Gerrit's shape, and the third is a deliberate policy plus a property of a tool this design does not itself write.
Only the tool half could be changed by writing code, and it guards the tool's own path with the worker account's server-side label ACL behind it; section 5 argues that control and why the tool's powers stop at publish and submit.

## 5. Where responsibility sits: Firstmate or the forge tool

Start from the division that already works.
For GitLab, Firstmate knows which tool and calls it, the tool knows the forge, and Firstmate owns none of the mechanics.
Not the artifact's creation, not its URL shape beyond parsing it back into an identity, not the merge command.
The forge property Firstmate carries for GitLab is no property at all, only a tag read off a URL.

The question this raises for Gerrit is whether the stack-versus-squash glue belongs on the same side of that line.
**It does: the shape mechanics live in the forge tool.**
Section 3 settles what that tool is asked to be: it executes the mechanics and is never asked to declare its own semantics, because the project record already carries the binding.
A third candidate home came onto the board after this choice was made, and it is argued below rather than left implicit.

The case for it is that this is forge mechanics through and through.
Producing a stack of changes under a topic means giving each commit a `Change-Id`, pushing once to `refs/for/<branch>` with a topic option, and reasoning about the parent chain that makes the stack a stack.
None of that is a Firstmate concept, and every line of it Firstmate writes is a line Firstmate maintains on behalf of one forge.
Move it and Firstmate's job shrinks back to "know which tool, call it", which is exactly what it already is everywhere else.

### Does the pipeline need to know?

The strongest objection is that the no-mistakes pipeline, not Firstmate, is what runs at delivery time, so hiding forge mechanics inside a forge tool only helps if the pipeline can call that tool.
The objection is right about the mechanism.
no-mistakes does own publication: `push`, `pr`, and `ci` are its own pipeline steps, sitting alongside `review`, `test`, `document`, and `lint`, and a run reports each of them independently.

It does not defeat the answer, because on a Gerrit project those are precisely the steps that do not run.
The delivery design has a `forge=gerrit` worker pass `--skip push,pr,ci` on every run and skip nothing else, keeping `review`, `test`, `document`, and `lint` as the whole point of the run.
Publication then moves out of the pipeline entirely: once the run passes and its fixes are back on the worker's branch, the worker publishes that branch to the review server through the forge tool.
So the caller of the forge tool is Firstmate or the worker, never no-mistakes, and the pipeline never has to know `gerrit-axi` exists.
The objection's premise holds everywhere the pipeline publishes, and a Gerrit project is the one place it does not.

That answer is contingent, though, and reading it as structural would be a mistake.
The pipeline can be kept ignorant of the forge tool only because it has no Gerrit support to exercise: its `Provider` type names six forges and none of them is Gerrit, so its publication steps could not work against one.
The skip exists because those steps cannot function, not because publication belongs outside the pipeline on principle.
The push model would have to change too, not merely be switched on.
The pipeline pushes to a fork: this repository's own run records its push target as `kind=fork` against a personal GitHub URL while `origin` is the upstream repository.
A forkless forge has nowhere for that model to put anything, so Gerrit support there means a push step that targets `refs/for/<branch>` on the one shared repository rather than a fork it does not have.
Add Gerrit to that provider set with that push step and the skip disappears, the pipeline publishes natively, and the question of who calls the forge tool reopens.

### What powers the tool needs

`gerrit-axi` carries the shape mechanics.
`publish --stack --topic <t>` makes each commit on HEAD its own change under the topic, `publish --squash` makes them one change, and either keeps every `Change-Id` a commit already carries and stamps one only where a commit has none.
**It has publish and submit powers, and no voting powers at all.**
It lives in a separate repository, so it is the one piece of this design that does not land beside the rest.

Getting the risk boundary right matters more than the decision, because the intuitive cut is the wrong one.
The natural reading, and the one recommended earlier in this design, puts the boundary between publish and submit: publishing is reversible, submitting is not, so grant publish and withhold submit.
Evidence supersedes that reading rather than merely outweighing it.
Gerrit computes submittability on the server, independently of who asks.
A change observed on a live server with its `Verified` label satisfied and every other gate passed still reports `submittable: false` and `blocked_on: Code-Review` for as long as no human has voted, and a submit call against it fails there.
Granting submit therefore moves much less risk than it appears to, because what is being granted is the ability to ask a server that will refuse.

The hazard concentrates one step earlier, in **decisive voting**.
An agent that can record `Code-Review+2` can manufacture the approval and then submit legitimately against it, and at that point every gate really is satisfied and nothing anywhere records that no human ever approved.
That is exactly the attributed-claim problem section 4 identifies, a positive claim that a named human approved, read as such by colleagues and by any audit of the repository.
It is also why the server permitting self-approval makes this a policy boundary rather than a capability limit: the server will not stop it, so something else has to.

That something is not a tool.
The SSH connection a worker needs to push to `refs/for/*` also carries `gerrit review`, which accepts `--code-review` scores from -2 to +2, `--label LABEL=VALUE`, and `--submit`, gated only by whether the account holds the label permission and independent of anything `gerrit-axi` supports.
The durable control is therefore the worker account's server-side label ACL: an identity permitted to push to `refs/for/*` must not hold decisive `Code-Review` permission.
A tool that cannot vote, paired with an account that can, is not a boundary at all, only the appearance of one.

Behind that ACL, Firstmate's refusal and the tool's inability to vote are defence in depth, guarding the tool's own path rather than the account's.
Both are required here: Firstmate refuses to submit, and the tool never votes.
Neither replaces the ACL, and neither is worth much without it, which is why the account requirement is stated as the control and these two as what stands behind it.

So the trade is not publish against submit.
It is publish and submit on one side, where the server itself is the enforcement, against decisive voting on the other, where only the account's grants are.
A non-decisive `Code-Review+1` sits between them, since it records an opinion without satisfying the gate.

The line is drawn at the whole of voting rather than at the decisive half.
A `+1` satisfies no gate, so withholding it costs nothing the mechanics need, and the tool that cannot vote at all needs no one to reason about which votes are safe before each release.
Withholding votes from the tool does not replace the ACL; it keeps the tool's own path from being the one that tests it.
That matters more on a forkless forge, for the reason section 4 gives: the worker's identity already holds a grant on the shared repository, so its account's label permissions are the limit that stands between it and a manufactured approval, and the tool should not be a second way to probe that limit.

### A third place the mechanics could live

Two homes for the shape mechanics have been weighed so far, Firstmate and a forge tool Firstmate calls.
There is a third, and it deserves arguing as a peer rather than a footnote, because it was not in view when the choice above was made.
no-mistakes already carries a multi-forge abstraction, with a `Provider` type, per-provider packages, and a per-repository execution context, and Gerrit support could be contributed there natively following the pattern its six existing providers follow.

The case for it is that it removes part of a duplication the other two options create.
If the pipeline gains Gerrit support while Firstmate also has its own forge tool, `Change-Id` handling, magic-ref pushes, topic stacks and submittability are each implemented independently on both sides.
Contributing upstream removes that duplication for the pipeline-driven path only: when a `no-mistakes` worker publishes, `Change-Id` handling on push and magic-ref publication would live in a pipeline that already knows six forges, behind the forkless push step the contingent skip above shows it would need, rather than in a seventh integration beside it, and that abstraction is both more mature than a new one and shared rather than ours alone.

It removes only that part.
The pipeline never merges: its host interface finds, creates and updates pull requests and reads their state, checks and mergeability, and its `ci` step only verifies that a merge happened.
Merging, the merge poll and the stack watch below stay with Firstmate wherever publication lives, so Firstmate still needs a Gerrit-aware tool, and submittability and topic-stack reasoning still exist on both sides under this option.
Publication stays there too for the other delivery path: a `direct-PR` worker never runs the pipeline, so its magic-ref push, `Change-Id` handling and topic stack come from Firstmate's own tool whatever the pipeline gains.
It removes one caller of the forge tool's publication mechanics rather than the mechanics themselves.

The case against is a dependency the other two options do not carry.
Gerrit support upstream lands when that project decides it lands, at whatever scope its maintainers accept, and a forge needed now cannot be scheduled against someone else's roadmap.
A tool under our own hand ships when we ship it.
The honest reading is that the upstream route removes the publication duplication on the pipeline-driven path, not all of it, and pays for that with a schedule we do not control.

**So: build ours now, contribute upstream later.**
The two are sequential rather than exclusive, which is what makes the timing objection survivable.
A forge tool built now ships against a schedule we hold, and its publication mechanics are the part that could later be contributed upstream once they are known to work, at which point the pipeline-driven path stops calling Firstmate's tool to publish, while `direct-PR` publication, merging, the merge poll and the stack watch stay in it.
Choosing the upstream route first would have meant waiting; choosing it second costs only that the publication code is written before it is shared.

### Watching a stack

The merge poll watches one change number, and a stack is several changes, so grouping them by topic is the obvious handle.
Topic membership is mutable on the server, though, so a watch keyed on a topic alone is keyed on something anyone with access can change out from under it.

The resolution is to **pin the membership and detect growth rather than follow it**.
Record the change numbers the stack had when the watch was armed, keep watching exactly those, and re-read the topic only to notice that it no longer matches.
A change that appears or disappears is then reported as a change to the thing being watched, instead of being absorbed silently into it.
That keeps the watch's subject fixed, which is what makes a merged verdict mean anything, while still surfacing the case a bare pin would hide: someone adding a change to the stack after the watch was armed.

## Open questions

None.
Every question this note raised is answered where its reasoning sits, rather than repeated as a list here.
What is left is implementation.
