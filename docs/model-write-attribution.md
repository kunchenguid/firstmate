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
- A commit: in the commit message. Prefer the subject; where a repository lints commit subjects, put it at the start of the first body line instead. The sweep reads the whole message, so either placement counts.

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
The sweep prints the evidence available for each candidate - author association, the app that performed the write when GitHub records one, and a commit's signature state, committer, and branch - and says in its own output that the captain judges.

**A clean run is distinguishable from a run that could not look.**
Every scope ends in exactly one of observed-clean, candidates, or could-not-observe.
An unreachable API, an expired token, a truncated response, an exhausted request budget, and an unparsable reply are all could-not-observe, never an empty finding.
The exit status carries the same three values: `0` clean, `10` candidates, `20` at least one scope unobserved.
Candidates found before a scope went unobserved are still listed, and the summary still reports the scope as unobserved.

**It never writes.**
Every call is a GET through one chokepoint, and the sweep does not comment on, edit, close, or delete anything it finds.

## What the sweep can and cannot see

Knowing where coverage stops is part of trusting a clean result.

- Only writes inside the window are examined, and the window is printed in the run's own output. Anything older was not looked at.
- Commits are reached through branches and through pull request heads. The pull request pass is what finds a commit whose branch was deleted after the pull request closed, which is the normal end state for finished work; without it that commit appears in no branch listing at all. It costs roughly one request per pull request in the window, which is what the request budget is for.
- A commit that belongs to no branch and no pull request is reachable only by SHA and is not enumerable. The sweep cannot see it and does not pretend to.
- GitHub stops listing a pull request's commits at 250. Reaching that wall is reported as could-not-observe for the scope rather than treated as the end of the list.
- Review comments left on individual diff lines are a separate GitHub object from the review bodies the `reviews` kind reads. They are not currently swept.

## The residual exposure

A missing token is indistinguishable from the captain's own writing until a sweep runs.
The sweep cadence is therefore the exposure window, and no cadence is currently scheduled: running it is a deliberate act.
This was accepted knowingly when the convention was chosen over a separate machine identity.

## Maintaining this page

Keep the token, its rationale, and the sweep's guarantees here, and keep flags and output formats in the script's own header and `--help`.
When the token changes, change both in one commit.
