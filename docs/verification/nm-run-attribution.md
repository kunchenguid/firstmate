# no-mistakes run attribution verification

Repeatable evidence for the code-identity rule that decides whether a no-mistakes run belongs to a crew's worktree.
The rule itself is owned by [`../../bin/fm-nm-run-lib.sh`](../../bin/fm-nm-run-lib.sh) (`fm_nm_head_identity`) and its consumer contract by [`../../bin/fm-crew-state.sh`](../../bin/fm-crew-state.sh); this page records evidence only.

Date: 2026-08-18.
Installed CLI: `no-mistakes version v1.48.0 (2ac3769) 2026-08-08T06:39:01Z`.

## The pipeline head is not the worktree head during a run

A live run's recorded head is the head the PIPELINE has advanced to as it applies its own fix commits, and those commits are pushed to the configured target rather than fetched into the crew's worktree.
The head a run was launched against is a separate value.
Both were read from one in-flight run while its crew's worktree still sat at the launch head:

```console
$ no-mistakes runs --limit 4
  running      fm/fm-turnend-guard-afk-false-blind 416c0d30  2026-08-18 09:10  https://github.com/kunchenguid/firstmate/pull/2557
  running      fm/fm-wedge-aging-ignores-busy e4370ecc  2026-08-18 08:24  https://github.com/kunchenguid/firstmate/pull/2554
  running      fm/fm-brief-no-mistakes-cli 2e878030  2026-08-18 02:22  https://github.com/kunchenguid/firstmate/pull/2566
  failed       fm/fm-brief-no-mistakes-cli a5bc06b6  2026-08-18 02:13

$ git -C <crew worktree> rev-parse HEAD
a5bc06b6ee6829997c6bcc498b1e3d40a99bf1b7

$ git -C <crew worktree> rev-parse --verify 2e878030^{commit}
fatal: Needed a single revision
```

The pipeline head is not merely different from the worktree head; it does not resolve in that repository at all, so no ancestry comparison can be made against it.
This is the ordinary shape of a healthy run, and it grows more likely the more fix rounds a run performs, which is why `fm_nm_head_identity` reports it as `unverified` rather than folding it into `mismatch`.

## Which surfaces report which head

`no-mistakes runs` prints the current head's short SHA only, and `axi status` prints a single `head` field that is likewise the CURRENT head - shown here on a run whose launch head and current head differ:

```console
$ no-mistakes axi status --run 01M09420FAAJ8WRT6BTY29A38R
run:
  id: "01M09420FAAJ8WRT6BTY29A38R"
  branch: fm/fm-wedge-aging-ignores-busy
  status: running
  head: e4370ecc
  ...
```

`no-mistakes axi status --help` lists no output-format flag, and no `--json` surface exists on it.
The only read-only surface that reports the launch head is `axi sync --check`, documented as "freshly verify and return the plan without changing HEAD":

```console
$ no-mistakes axi sync --check
branch_sync:
  ...
  pipeline:
    run: ""
    status: ""
    phase: ""
    submitted_head: ""
    current_head: ""
```

`submitted_head` is therefore the identity anchor the attribution rule falls back to, and every empty or blocked answer from that command is treated as "no answer" rather than as a refutation.

## Regression coverage

`tests/fm-crew-state.test.sh` pins both directions over throwaway git repos and a fake CLI serving the exact shapes above.
Seven assertions cover the case: a live run at an unresolvable head reported through `axi status` and through the coarse runs list; a terminal verdict preserved when `submitted_head` binds the run; a terminal verdict withheld as `unknown` on both paths when nothing binds it; a genuine failure at the current head still reported `failed`; and a provably diverged newest row blocking attribution instead of falling through to an older row.

```console
$ bash tests/fm-crew-state.test.sh | tail -1
all fm-crew-state tests passed
```
