# Repository intake live read-only evidence - 2026-07-22

The feature-branch intake was run once against the primary Firstmate home's registered project inventory with `--refresh --attention-fingerprint`.
Its private checkpoint was redirected into this disposable worktree's ignored `.no-mistakes/` directory, so the primary home, project clones, GitHub, and external systems were not changed.

The run completed in 2 seconds through `gh-axi` and returned one stable SHA-256 attention fingerprint with 29 attention records at critical severity.
The checkpoint reported the Asia/Kolkata day `2026-07-22`, GitHub rate-limit remaining `4677`, and an overall failed observation rather than a false all-clear.

Of four registered projects, one canonical home clone resolved and was fully observed with 25 open issues and no open pull requests.
Three registered projects had no clone at their required `FM_HOME/projects/<id>` locations, so each remained explicitly unavailable with no GitHub absence or completion claim.
That is the intended fail-closed boundary: the first slice exposes missing registered-source custody instead of silently omitting those projects or scraping unstructured prose in the registry description for alternate paths.

The retained evidence contains allowlisted metadata only.
No issue bodies, comments, patches, workflow logs, transcript content, credentials, project files, browser state, deployment state, or external mutations were requested.
