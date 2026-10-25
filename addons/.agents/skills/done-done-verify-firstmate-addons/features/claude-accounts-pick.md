# Claude accounts: the chooser for new workers

## User outcome

New workers spread across eligible accounts of their provider in proportion to quota headroom, starting with the most headroom.

## Drive

Run `bash claude-accounts/tests/claude-accounts-pick.test.sh` (fixture registry, stub quota-axi, the add-on's own pool pick; 60:30:10 Claude headroom produces 6:3:1 across ten picks, Codex balances independently, concurrent picks retain assignments, old assignments expire, a 100:11 six-pick burst splits 5:1, launch prompts cannot rest healthy quota, rests follow the quota reset, a legacy rest cannot exclude 100/100 headroom, Codex weekly-only (null five_hour) clears a stale rest when seven_day.left is at/above the rest floor and keeps it below, and Claude with five_hour below 100 keeps the rest).
For the real accounts, `FM_BIN=<fork bin> done-done run claude-accounts-pick` runs the pool pick fm-spawn calls against a throwaway config/account-pool, starts one tiny Haiku task on the picked profile folder and reads every account's quota before and after.
For a live stale Codex rest, `POOL_STATE=<pool state dir> done-done run claude-accounts-codex-rest` (or `FM_HOME` whose `config/account-pool` names `state=`) copies the reading and rested list into a temp `--state` dir, runs pick, and leaves the live rest file untouched.

For normal-path spread proof, run six sequential `fm-spawn.sh acct-proof-1..6 <lab-project> --scout --harness claude --model claude-haiku-5-5 --backend herdr` tasks in a guarded named Herdr lab, each with its own fixture project and private pool.
Use `config/account-pool` pointing at this checkout, request only a `done` reply with no project changes, record the live quota snapshot and each worker's `account=` metadata, verify the assistant reply and clean worktree, and tear each worker down before the next spawn.
Capture through `done-done run --open claude-accounts-pick` / `run --close <id>` or a journey command; retain the text and `steps.json` in that run folder.

## Evidence

Capture `pick.txt` (ids, names and percentages only). Never open files inside a login folder or print a folder path or credential.
