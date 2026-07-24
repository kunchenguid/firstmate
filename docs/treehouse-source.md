# Treehouse install source

Firstmate installs [treehouse](https://code.byted.org/obric/treehouse) by
building it from source at a pinned tag and commit, not by downloading a
prebuilt binary.

## Why source, not a binary download

Treehouse's upstream distribution model is prebuilt binary tarballs attached to
GitHub Releases (plus a GitHub Pages `install.sh` that downloads them).
Firstmate's source of truth for treehouse is the internal Codebase mirror
`code.byted.org/obric/treehouse`, and Codebase releases cannot host binary
attachments.
So there is no "same discipline, different download URL" option: the pinned,
reproducible install has to build from source.
Building from the pinned tag and commit with `go build` gives the same integrity
guarantees the old checksum pin gave (an exact commit, plus `go.sum` for
dependencies), without needing a hosted binary.

## Where the pin lives

`bin/fm-install-treehouse.sh` is the single owner of the install pin:

- `FM_TREEHOUSE_CI_VERSION` / `FM_TREEHOUSE_CI_TAG` - the pinned version (`v2.0.1`).
- `FM_TREEHOUSE_CI_COMMIT` - the exact commit `v2.0.1` must resolve to,
  verified after clone so a moved or forged tag cannot substitute other source.

The script clones the pinned tag, verifies the commit, and builds with
`go build -ldflags "-X main.version=v2.0.1"` (equivalent to the upstream
Makefile's `make build VERSION=v2.0.1`), which makes `treehouse --version` print
`v2.0.1` - the same post-install check the script has always enforced.
It requires a Go 1.25+ toolchain and git, and fails loudly if either is missing
or Go is too old.

`FM_TREEHOUSE_SRC_REPO` overrides the clone URL (default: the Codebase mirror).
The required real-Herdr CI lane runs on GitHub's public runners, which cannot
reach the internal Codebase host, so that lane points this at the identical
`github.com/kunchenguid/treehouse` mirror; the commit-SHA pin verifies either
source because both mirrors carry the same commit for `v2.0.1`.
`bin/fm-bootstrap.sh`'s `install_cmd(treehouse)` prints the human-facing
equivalent (`git clone ... && make install VERSION=v2.0.1`).

## Upgrading the pin

Upgrading treehouse is a deliberate, separate change: edit the pin variables in
`bin/fm-install-treehouse.sh` (version, tag, and commit) and re-verify the build.
Nothing bumps the pin automatically.

## Keeping the mirror fresh

`bin/fm-sync-treehouse-upstream.sh` refreshes the Codebase mirror from the
canonical `github.com/kunchenguid/treehouse` upstream.
It is a manual, idempotent, safe-to-rerun helper: it pushes new branches and
tags additively (never mirror-pushes, prunes, or force-pushes, so Codebase-only
refs survive), drops GitHub-only pull refs, and reports a non-fast-forward
instead of clobbering.
It only makes newer upstream tags and commits available in the mirror; it never
touches the install pin.
Run it periodically, or right before bumping the pin so the mirror carries the
tag you intend to pin.
It is not wired into any cron or CI.

## Migration provenance

Date: 2026-07-24.
The mirror was seeded by mirroring the upstream and pushing branches and tags to
`code.byted.org/obric/treehouse` (GitHub-only `refs/pull/*` refs stripped first):

```
git clone --mirror https://github.com/kunchenguid/treehouse.git
# delete refs/pull/* from the mirror
git push --mirror https://code.byted.org/obric/treehouse.git
```

Post-migration `git ls-remote https://code.byted.org/obric/treehouse.git`:

```
c0b7f685d4511eec765ab4cbb47583178424eb45	HEAD
c0b7f685d4511eec765ab4cbb47583178424eb45	refs/heads/main
5b8ecdec49034fe6861d63b8ea331490bb14c946	refs/tags/v2.0.1
```

The repo's default branch is `main`; `v2.0.1` resolves to commit
`5b8ecdec49034fe6861d63b8ea331490bb14c946`, which is the commit pinned in
`bin/fm-install-treehouse.sh`.
A local `bin/fm-install-treehouse.sh <dir>` run against the Codebase mirror built
and installed treehouse and printed `v2.0.1`.
