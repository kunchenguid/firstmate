# fleet-dashboard

The read-only fleet dashboard — server, builder and app — moved **verbatim** out
of the Firstmate fork into this add-on repository. Nothing serves it from here
yet: the live dashboard keeps building and serving from the fork's
`bin/fm-dashboard.sh`, and the fork-side shim that will exec into this directory
lands in a later PR. Until that swap this directory is dormant. `fm-dashboard.sh`
and the app under `fm-dashboard/` carry the deliberate differences from the
fork described under Provenance.

## Layout

- `fm-dashboard.sh` — the `build | serve` entry: collects every source, writes
  the three static pages plus `board.json` and `data.json`, and serves the app
  read-only but for ticket comments (python3 stdlib, no network reference).
- `fm-dashboard/` — the app: `index.html`, `app.js`, `app.css`, `board.js`,
  `ui.js`, `insights.js`, `insights.css`, `tickets.js` (the Tickets board, new here), `icon.svg`,
  and `vendor/` (Preact + htm, Inter, and the vendored `LICENSES`).

## Tests

Run the behavior suite with `fleet-dashboard/tests/run-fork-suite.sh [checkout]`: it copies a Firstmate checkout (the argument, `FM_FIRSTMATE_DIR`, or a fresh clone when neither is set) to a scratch tree, swaps in this directory's `fm-dashboard.sh` and `fm-dashboard/`, and runs the suite there.
`fleet-dashboard/tests/fm-dashboard-partial-backlog.test.sh` runs on its own and checks the lower-bound counts when a single home's backlog cannot be read.

## Frozen contract (unchanged)

- CLI: `fm-dashboard.sh [build]` and `fm-dashboard.sh serve [--bind ADDR]
  [--port N]` (plus `-h`); every other invocation prints the usage line and
  exits 2.
- Output: `$FM_HOME/state/dashboard/` — `board.json`, `data.json`, the static
  pages `index.html`, `backlog.html` (+ its `backlog.home.html` variant) and
  `measure.html`, plus the retained `filed.json` and `history.tsv`.
- Data keys: `board.json` carries the flow reader's `fm-flow.v1` observation
  under `flow`, or `flow_error` naming the cause (the reader's last error line,
  its exit or the 180 s deadline) when that reader is unavailable or unreadable,
  with the matching `models_error` / `skills_error` keys for the statistics
  readers.

## Provenance: deliberate changes from the fork

Every moved file was compared byte for byte against its fork source
(`bin/fm-dashboard.sh` and `bin/fm-dashboard/`) at move time; the 16-file
sha256 manifest matched across fork source, this directory, and both scratch
copies used by the proof below
(evidence: `data/addons-extraction/parity/identity-manifest.txt` in this home's
task data). Treat any future diff against the fork file as a contract change,
not a refactor.

Four changes are deliberate. `fm-dashboard.sh` no longer blanks the fleet's Ready
and queue numbers when a single home's backlog cannot be read: it counts the
homes that were read, marks a partial count as a lower bound (`≥`), names each
unread home with its reason, and reports the partial metric with status
`partial` in `data.json`. Only when no home could be read does the tile show
the unknown dash as before. It also adds one environment input, `FM_BIN` (see
For the fork shim lane), defaulting to the script's own directory so a fork
copy behaves exactly as before. The third changes the ask list: it lists
newest first by default with an oldest-first toggle, and each ask carries a
type tag (yes/no, pick or approval) with a matching filter. The ask type reads
from the optional fifth column of `data/captain-asks.tsv` (the row is `id`,
`since`, `text`, `url`, `type`) when it is `yn`, `pick` or `approval`, and is
otherwise inferred from the ask text — once in `fm-dashboard.sh`'s static
overview page and again in the app (`ui.js`, `app.js`, `app.css`). The fourth
adds the Tickets board: `tickets.js`, its route and styles in `app.js` and `app.css`, the
`Entry` export in `board.js` that its ticket page reuses, and
the `tickets` and `tickets_unread` keys `fm-dashboard.sh` adds to `board.json` from the
backlog it already reads, Overview naming the source of every figure (from each
metric's `source` in `data.json`) on hover and under its card, and the ticket comment: the server's one write, `POST /comment`.
It takes the owner's sign-off board token: `config/owner-board` names the board's `board.json`, and its `<board>.token` is read on each comment.
A device that opened the board's access link carries the board's `sign-off-<port>` cookie, and the browser sends it to the dashboard too when both are opened at the same address, so nothing is pasted (with no such config, comments are off).
The comment goes to the owning lead with `fm-send.sh` (or to Main with `fm-inbox.sh note`) and asks for the answer in the thread:
the lead runs `"$FM_HOME/bin/fm-secondmate-report.sh" note <comment id> <answer>`, Main `fm-inbox.sh reply <note id> <answer>`.
The build shows each comment with its pickup (the steer or note moved to `handled/`) and answer (the lead's `corr=<comment id>` line on its channel, or Main's inbox reply).
The Ship tab is removed, with its `ship/` files and the vendored three.js it alone used. The app takes the approved Tickets prototype's look: neutral greys and one accent in both themes (Insights included), Tickets as the landing view, Overview labelled Metrics, a phone dock that names each view, flat neutral Metrics cards, and Board cards whose names drop leading tags and Main refs as tickets do. Tickets filters by release as well as project and lays open items in release lanes (Next release, After, Later; `#/tickets?by=release`); each Metrics lifecycle stage and To land open the Board filtered to that stage (`#/board?stage=ci`, a removable Stage chip); a phone's column switcher scrolls sideways only, never the page. Every memory pressure figure (the Metrics Memory card, the generated pages, `data.json` and Insights) is the memory gate's own sustained reading, the lower of the 10 s and 60 s averages. Metrics shows Time in stage: each open lane at its time in its current stage, the median per stage, and the bottleneck (most lane-hours, lanes on hold left out); a row opens the stage-filtered Board. A ticket's name and description are whole even when `tasks-axi list` cuts them (filled from `show --full`, cached in `state/dashboard/full-text.json`), its ask names the Main message that carried it, and its page shows the lane's proof (completion receipt and done-done verdict). Metrics' Flow card shows GitHub's merges in the repositories the fleet recorded merges in beside the recorded ones, by local day, with the records' coverage (one read-only `gh pr list` per repository at most every 30 minutes, kept in `state/dashboard/forge.json`; `FM_DASHBOARD_FORGE=off` skips it).
Every other moved file remains byte-identical to the fork.

## Side-by-side proof (re-run before the served path swaps)

The acceptance proof builds the fork copy and this copy in two throwaway
`FM_HOME` dirs over one identical fixture and diffs the two
`state/dashboard/` outputs byte for byte. Its fixture reads every home's
backlog, so the two copies still agree there; the deliberate differences
above are the cases where they are now expected to diverge.

One command (harness lives with this task's evidence):

```sh
bash <task-data>/run-parity.sh  # the harness lives with this task's evidence
```

It must end with `ALL CHECKS PASSED`, with both
`diff-fork-vs-moved-pass1.txt` and `diff-fork-vs-moved-pass2.txt` empty.
Manual recipe if the harness is gone:

1. Copy `bin/fm-dashboard.sh` + `bin/fm-dashboard/` from the fork and
   `fleet-dashboard/` from this repo into two scratch dirs; verify sha256 of
   every moved file matches across both except the files named in the
   deliberate differences above.
2. Overlay identical deterministic reader stubs next to both scripts
   (`fm-flow.sh` exiting non-zero for pass 1, a fixed `fm-flow.v1` JSON for
   pass 2; fixed `fm-model-stats.sh` / `fm-skill-stats.sh`; a fixed TOON
   `fm-tasks-axi.sh` + addressing lib), and PATH stubs for `herdr`, `adb`,
   `pgrep`, `systemctl`, a fake `/proc` (`FM_DASHBOARD_PROC`) and an empty
   `FM_DEVICE_LOCK_DIR`.
3. Copy one synthesized fixture into two throwaway `FM_HOME` dirs: the most
   tasks, the longest titles, a lane in every state plus a held lane, asks,
   recorded merges, quota and machine samples, and a home whose flow reader is
   broken so `flow_error` is exercised; pin `TZ=UTC LC_ALL=C` and freeze the
   clock (`PYTHONPATH=sitecustomize.py` stubbing `datetime.now`/`time`) so
   both builds run at one instant.
4. Run `fm-dashboard.sh build` with each home, capture
   `$FM_HOME/state/dashboard/`, and `diff -r` the captures: identical
   `board.json` and `data.json`, page HTML identical outside the deliberate
   differences above. The only path a build prints is
   its index page path, which names its own `FM_HOME` — normalize that line
   and the stdout must match too.
5. Check the CLI contract (`-h`, bad subcommand, bad port, extra build
   argument → usage line and exit 2) and smoke `serve --bind 127.0.0.1
   --port 18787` from the moved copy: 200 on `/`, `/app.js`, `/board.json`,
   `/backlog`, `/measure`, `/data.json`, 404 elsewhere.

## For the fork shim lane

`FM_BIN` names the directory holding the Firstmate helper scripts a build runs (`fm-tasks-axi.sh`, `fm-flow.sh`, ...); unset, it defaults to this script's own directory, so a fork copy is unaffected.
Run from this repository it must point at the Firstmate `bin/`, which makes the later shim `FM_BIN=<firstmate>/bin exec <addons>/fleet-dashboard/fm-dashboard.sh "$@"`: a set `FM_BIN` without `fm-tasks-axi.sh` is refused.

The shipped `fm-dashboard.service` runs
`<fm-home>/bin/fm-dashboard.sh serve --bind "$(tailscale ip -4 |
head -1)" --port 4390` with `FM_HOME=<fm-home>`; the later shim
must keep that exact path and argv (it will exec
`fleet-dashboard/fm-dashboard.sh`). Re-run the side-by-side proof above
immediately before the served path swaps, and keep this README's proof
sections honest when the harness moves.

CI note: `.github/workflows/addons-ci.yml` ShellChecks and syntax-checks this
directory's `fm-dashboard.sh` (an add-on script is a shell script one level
under a top-level add-on directory) — it passed at move time.
