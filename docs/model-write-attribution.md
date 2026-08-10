# Model-write attribution on GitHub

A browser model session that can write to GitHub writes as the account owner.
This page owns the token those writes carry, why that exact token, and the sweep that finds writes which lack it.

## The problem this addresses

Every write the fleet makes to GitHub authenticates as the captain's own account.
An issue comment, a pull request review, and a pushed commit all record the owner's login with `author_association: OWNER`, no bot marker, and no separate machine identity.
Some of those writes additionally carry `performed_via_github_app`, but that field appears nowhere a human reads a comment, so the write still presents as the owner's own writing.

Nothing at write time can separate a model session from the captain typing, and nothing can be added to the identity that would.
Using a distinct machine account was considered and rejected: the browser-to-GitHub link already exists on the personal account, and moving would mean creating an account and unlinking the personal one.

The chosen design is therefore a convention the session applies to itself, plus detection after the fact.

## The token

The token is exactly:

```
SOL-AI:
```

A write that carries it is declaring itself as model-authored.
A write that lacks it is not thereby the captain's - it is simply undeclared.

This spelling was chosen because it survives every surface a write lands on and because it is greppable without false positives.

- It is ASCII uppercase letters, one hyphen, and one trailing colon.
- None of those characters carry meaning in GitHub-flavored Markdown, which renders comment and review bodies: there is no emphasis pair, no link or reference bracket, no autolink or raw HTML angle, no heading or issue-reference `#`, no `@` mention that would notify a real person, no emoji shortcode, no strikethrough, no code span, and no leading list marker.
- A trailing colon does not make it a link: GitHub's autolinker wants a scheme with `://` or one of its known prefixes.
- Git applies no markup to a commit message at all, so the same bytes survive a subject line unchanged.
- An all-caps hyphenated compound ending in a colon is not a word in English or in code, so a search for it returns deliberate uses and nothing else.
- A human reading a comment understands it without a lookup, which is the entire point.

Changing the token means changing it in `bin/fm-attribution-sweep.sh` in the same commit.
The script holds the one constant and this page holds the reasoning; splitting them would leave the convention and its detector disagreeing.

## Where the token goes

Lead the text with it.

- An issue or pull request comment: the first characters of the body, followed by a space.
- A pull request review: the first characters of the review body, followed by a space.
- A commit: in the commit message.
  Prefer the subject; where a repository lints commit subjects, put it at the start of the first body line instead.
  The sweep reads the whole message, so either placement counts.

## Reaching the convention when a prompt is written

The rule is only useful if it is in front of whoever composes the session, so the tool emits it ready to paste:

```
bin/fm-attribution-sweep.sh --convention
```

Paste that block at the top of a browser model session that can write to GitHub.
`bin/fm-attribution-sweep.sh --token` prints the bare token for scripting.

## The sweep

```
bin/fm-attribution-sweep.sh [--repo <owner/name>]... [--kind comments|reviews|commits]... [--since <iso8601>]
```

The script's header and `--help` own its flags, bounds, and output markers.
Four properties matter more than the mechanics.

**It is the reason the convention is worth anything.**
A model can silently omit the token, and no write-time mechanism can stop it on this identity.
Detection after the fact is what converts an unenforceable rule into a detectable one.

**It reports candidates, not authors.**
A write under this account without the token is exactly what an undeclared model session and a comment the captain typed by hand both look like in every field GitHub exposes.
The sweep prints the evidence available for each candidate - author association, the app that performed the write when GitHub records one, and a commit's signature state, committer, and the branch or pull request it was found through - and says in its own output that the captain judges.

**A clean run is distinguishable from a run that could not look.**
Every scope ends in exactly one of observed-clean, candidates, or could-not-observe.
An unreachable API, an expired token, a truncated response, an exhausted request budget, and an unparsable reply are all could-not-observe, never an empty finding.
The exit status carries the same three values: `0` clean, `10` candidates, `20` at least one scope unobserved.
Candidates found before a scope went unobserved are still listed, and the summary still reports the scope as unobserved.

**It never writes.**
Every call is a GET through one chokepoint, and the sweep does not comment on, edit, close, or delete anything it finds.

## What the sweep can and cannot see

Knowing where coverage stops is part of trusting a clean result.

- Only writes inside the window are examined, and the run's own summary names the window it covered.
  Anything older was not looked at.
  The default window is 7 days, chosen so a default run finishes inside the default request budget instead of reporting could-not-observe, because a detector whose first run usually says it could not look trains its operator to ignore it.
  Widen it with `--since` or `FM_SWEEP_WINDOW_DAYS`, and raise `--budget` with it: measured on this fleet's own repositories, a 14-day window already costs more than the default budget allows.
- An empty repository set is could-not-observe, never a clean sweep.
  GitHub answers the owner listing with an empty array both for a token whose scopes exclude the account's repositories and for an account that owns nothing, and those are the same bytes on the wire, so neither can be reported as having found nothing.
- Commits are reached through branches and through pull request heads.
  The pull request pass is what finds a commit whose branch was deleted after the pull request closed, which is the normal end state for finished work; without it that commit appears in no branch listing at all.
  It costs roughly one request per pull request in the window, which is what the request budget is for.
- A commit that belongs to no branch and no pull request is reachable only by SHA and is not enumerable.
  The sweep cannot see it and does not pretend to.
- GitHub stops listing a pull request's commits at 250.
  Reaching that wall is reported as could-not-observe for the scope rather than treated as the end of the list.
- Review comments left on individual diff lines are a separate GitHub object from the review bodies the `reviews` kind reads.
  They are not currently swept.
- A review submitted with no body carries no token, so the `reviews` kind reports every bare approval as a candidate.
  That is correct by the definition above - the write is undeclared - but it is the sweep's standing source of routine candidates, and the `state=` field in a candidate's evidence is what separates a bodiless `APPROVED` from a review that had prose and still omitted the token.
- An issue body, a pull request title or body, and a commit comment are all writes under the same identity that no kind reads.
  They sit outside the swept scope of comments, reviews, and commits, so a clean run says nothing about them either way.
- A commit is matched to the window by the later of its committer and author dates, because a rebase or cherry-pick carries an author date from before the window onto a commit pushed inside it.
  A commit whose branch and pull request were both touched entirely before the window is outside it and was not examined.

## The retained probe writes, and how to recognise them

Five writes in `sbracewell64/firstmate` are unprefixed, tied to the 2026-08-02 capability probe, and **deliberately kept**.
They are the sweep's only real-world red control, and they will be reported as candidates by every run whose window covers 2026-08-02.

If you are looking at a candidate and wondering whether to act on it, check this list first.

| Kind | Identifier | How it identifies itself |
|---|---|---|
| Issue comment | `5158866063` | body carries the nonce |
| Review | `4838962417` | body carries the nonce |
| Review | `4838972180` | body carries the nonce |
| Commit | `c73f62d045e8` | empty commit, message `test: verify browser commit capability` |
| Commit | `3e05033a95a1` | added `docs/sol-probe.md`, which carries the nonce |

Four independent ways to confirm one, in order of how quickly you can check.

- The identifier appears in the table above.
- The timestamp falls on 2026-08-02 between 15:17Z and 15:31Z, a span of about thirteen minutes that holds all five.
- A commit candidate carries `pr=24` in its evidence, because branch `probe/sol-capability` was deleted and only the pull request pass can still reach these two commits.
- Opening one of the three text writes shows the nonce `SOLPROBE-AIBQQE4JCTMV`, which was generated for this probe and appears in no other comment, review, or commit message.

The nonce is a reliable marker for the comment and the two reviews only.
Commit `c73f62d045e8` is the one the browser session pushed, and it changes no files at all, so neither the nonce nor any other content marker appears in it; its message and its emptiness are what identify it.
Commit `3e05033a95a1` is the probe scaffolding that planted the nonce for the session to read, so it carries the nonce in its diff rather than in its message.

A candidate that fails all four checks is not a probe artifact and should be judged on its own merits.

### Why they exist

They are what a browser model session produced on 2026-08-02 when it was asked to prove it could comment, review, and push a commit.
That measurement is the evidence the whole convention rests on: every one of them recorded the account owner with `author_association: OWNER` and no bot marker, which is why write-time enforcement was ruled impossible and detection after the fact was chosen instead.
Independent evidence is preserved outside this repository at `data/sol-capability-probe/github-evidence.md`.
That note agrees with this section: it records the decision to keep the artifacts, calls them a deliberate permanent known-positive, states that a sweep reporting them is working correctly, and leaves the question of how to recognise them to this page.
It enumerates only four artifacts, omitting scaffolding commit `3e05033a95a1`, which appears there as a parent SHA rather than as a swept write.
The table above supersedes it on the set, and every entry was verified against the live API rather than copied from the note.

Those two documents agreeing that the artifacts still exist is what keeps this section usable, and they have already disagreed once.
The note previously opened by saying the artifacts had been deleted, which would lead a reader here to conclude that any candidate dated 2026-08-02 must be genuine - the exact inversion this section exists to prevent.
No test can catch a repeat, because the note is private to the operator's home and absent from every clone and CI run, so a check asserting agreement would pass without reading anything.
Whoever edits either document reconciles both by hand.

### Why they were not deleted

Deletion was proposed, investigated, and declined on measured grounds.

It is only partly possible in the first place: a pull request cannot be deleted, only closed, and both commits survive because the pull request retains them.
Removing the comment while the reviews and commits stayed would have left a half-removed control, which is worse than either keeping or removing the whole thing.

The stronger reason is that a red control which exists in the real world, on the real account, is worth more than tidiness.
Every other control this detector has is synthetic, and a synthetic control can only confirm the assumption already written into it.
These five already earned their keep: proving the sweep against them is what exposed a real defect, an early filter that skipped app-performed writes and would therefore have hidden comment `5158866063` - the single most representative example of what the sweep exists to catch.

### Why they are not filtered out

The sweep does not special-case them, and it should not.
A known-positive that stops being reported has stopped being a control, and a suppression list is exactly the mechanism that lets a detector quietly stop working.
Labelling them is what replaces filtering, and a label only reaches a triager where that person is already standing.
The sweep's own summary therefore says that candidates dated 2026-08-02 may be known permanent ones and points at this page; the table above owns recognising them.

## The residual exposure

A missing token is indistinguishable from the captain's own writing until a sweep runs.
The sweep cadence is therefore the exposure window, and no cadence is currently scheduled: running it is a deliberate act.
This was accepted knowingly when the convention was chosen over a separate machine identity.

## Maintaining this page

Keep the token, its rationale, and the sweep's guarantees here, and keep flags and output formats in the script's own header and `--help`.
When the token changes, change both in one commit.
