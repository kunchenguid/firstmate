---
name: cockpit-refresh
description: >-
  Load before refreshing, changing, or verifying a cockpit page (Miko or Geris), before wiring or editing a page's refresh button, or when the captain says a page is stale, wrong, or missing one of his questions or to-dos.
user-invocable: false
metadata:
  internal: true
---

# cockpit-refresh

This skill owns the rules and the step order of a cockpit refresh.
`tools/cockpit/cockpit-sync.py --help` owns the commands, flags, environment variables, truth-JSON shape, and page contract.
`tools/cockpit/README.md` owns the tool inventory and each host tool's paths.

## The button contract

Every refresh of every cockpit page, whether from the captain's "Ververs alles" button, a timer, or by hand, runs this package.
Never rebuild or hand-edit a page around it, and never answer a refresh click with only a partial pass.
The order is fixed:

1. Sync: run `tools/cockpit/cockpit-sync.sh` with the page's own scope and `--page <live page>`.
2. Stop if it fails: the live page now carries the failure banner, and nothing else is published.
   Tell the captain the refresh failed and why.
3. Build the page to a scratch file from the truth JSON of step 1.
   Item statuses come from `goals[]`, never from the raw goal marks.
   Render all captain actions from `section1`, including ordered manual steps and tests, never from memory or an older page.
4. Run the shared drive pass with that same truth file, not a second goal export; it fills the keyed steps in section 1 automatically.
5. Verify the scratch page with `cockpit-sync.sh --verify-page`, which rejects missing or stale goal views.
6. Publish only when step 5 reports no problem.
   Otherwise keep the old page and mark it with `--banner-only`.
7. Route the findings: report every `MISMATCH` line to the owner of the record.

A page host may add its own sources and layout between steps 3 and 4, but may not drop, reorder, or soften a step.

## What a refresh must get right

- Every item of every goal on the page is re-checked each time: pull request state from the forge, the live task state, and the goal mark.
- A status taken from a message is shown only after it is checked against the forge, the worker, or the deployment.
- Every goal item, including dropped items, appears consistently in its goal list, WBS box and keyed Kanban card, and counts in both rings.
- Any popup about an item shows the same verified status.
- "Live for customers" means deployed: the version production actually serves, not only merged on main.
- Every active worker is on the board.
- A coloured status never carries text saying it is not happening now, and nothing shows as running while something before it is still open.
- Everything the captain must or can do has a question or steps in the decisions section, in plain words.
- A question appears once, and an answered or resolved one does not appear.
- Entries under `must` come first; `can` and `later` may be collapsed but not left out silently.
- Each page shows only its own project's goal cards and captain entries, with its captain steps first in section 1.
- Captain steps for work that belongs to no cockpit appear once, under "Overige projecten" inside section 1 of the page whose scope also names `main`.
- Two refreshes in a row make zero differences when the world did not change.

## Miko page working rules

- Until the captain says Miko goes live for customers, security repairs run alongside and block nothing.
- The hourly firstmate timer and the captain's refresh button run the same pass.

## Mismatches

A mismatch is a finding, not a page failure.
An `unrouted-decision-key` line is an open worker or secondmate question that is not on the captain's list: firstmate holds it through `captain-hold-lifecycle` when it is his, or answers and resolves it.
The page shows the verified status; the goal record stays the record owner's to mark through `bin/fm-goal.sh` (see `drive-goal`).
A `stale-decision-key` line means a status log still holds a key whose question is already answered: its writer appends the `resolved` line.
Use `cockpit-sync.sh --captain-waiting` to follow up on missing cockpit entries; route a real question not covered by a goal step through `captain-hold-lifecycle`, never by typing it into the page.
Give an entry its plain-language question, options, and recommendation in the hold's question context, so every later refresh carries them.

## Improving the package

When a refresh missed something or showed something stale:

1. Reproduce it as a case in `tests/cockpit-tools.test.sh` on the synthetic goal home and page, and see it fail.
2. Add the check in `tools/cockpit/cockpit-sync.py`: a flag in `verify_item` for item truth, a source or rule in `captain_list` for the decisions section, or a rule in `verify_page` for the built page.
3. Update the script's `--help` when a field, flag, or page rule changes, and this skill only when a rule or the step order changes.
4. Run `bin/fm-lint.sh` and the cockpit test, then ship it as an ordinary firstmate change.

Fix the package, never one page by hand, so the same miss cannot return on the other cockpit.
