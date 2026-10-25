# Vision

## Who it is for

Anyone who runs a fleet of coding agents on their own machine and wants it to keep moving when a provider slows down, a task wedges, or an agent tries something destructive.

We are the first users: this is one public repo for the fleet dashboard and every other add-on we built for our own fleet.

## The problem

A busy fleet keeps hitting the same gaps: runaway deletes, burned provider quota, stalled tasks, merges nobody watches.

We first closed those gaps with patches in our fork of the fleet manager. Every feature patched into the fork pulls it further from upstream, so taking an upstream update turns into a merge.

## The end state

In the owner's words: "Whatever is in [the upstream] repo stays in [the fleet manager], only our customizations and extra stuff moves to addons. Like an extension: install, uninstall, and [upstream] updates keep working with no merge."

- The fork stays a thin layer over upstream: only bug fixes and small hook points.
- Every feature lives here as an add-on that installs and removes on its own. Take only the ones you need.
- Every fork change that is not upstream yet is tracked, with its way out, in [FORK-EXIT.md](FORK-EXIT.md).

## Principles and quality bar

- **An add-on before a fork patch.** The next core gap goes in an add-on when it can; a fork patch only when it cannot, and it joins the fork exit list the same day.
- **Wrap, don't copy.** An add-on runs on the upstream tool plus our thin layer, so upstream updates arrive with no merge.
- **Clean install and uninstall.** Every add-on installs and uninstalls cleanly, like an extension.
- **A guard's block is final.** A blocked destructive action is not retried or worked around, no agent or reviewer approves it, and the block alerts you.
- **The dashboard is exact and glanceable.** Numbers are deterministic and correct, the first phone screen answers everything ("I should not be needing to open and dig into the weeds"), and "Waiting on you" shows only what really needs you. It is visual first, with real charts, not a page of text.
- **Functional first.** A new thing a user can do, working end to end and rolled out, comes before polish. Working with slight rough edges beats never shipped; the main path's look and flow still have to be right.
- **Proof on the real product.** Integration and end-to-end tests only, driving the real product like a user.
- **Small changes.** Each piece moves in a pull request of at most 300 changed lines.

## What it is not

- Not a replacement for the fleet manager. The add-ons run on top of it.
- Not the place for upstream bug fixes. Those stay in the fork as small fixes.
- Not a bundle you must take whole.
- Not a text-first status page.
- Not a home for scope nobody asked for. New scope is put to the owner as a decision before it is built.

## Next milestones

The last release was [v0.1.0](https://github.com/umeranjum17/firstmate-addons/releases/tag/v0.1.0), the first tagged cut, on 22 Oct 2026. All releases are on the [releases page](https://github.com/umeranjum17/firstmate-addons/releases).

1. **v0.2.0 "tickets"** (target 24-25 Oct 2026): a task needs a priority and a target release when it is added or held; a Tickets view on the fleet dashboard with release lanes; old evidence cards retitled.
2. **v0.3.0**: the account pool and the lead-wake policy leave the fork, each behind one hook line, so upstream updates need no merge.
