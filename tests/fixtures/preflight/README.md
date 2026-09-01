# Brief-preflight fixtures

One brief per rule in `bin/fm-preflight-lib.sh`, plus the two that must PASS.

Every fixture is written for task id `fixture-k3`, so `state/fixture-k3.*` and
`data/fixture-k3/` are the sanctioned self-references and any other id under the
primary checkout is another task's material.

| file | expectation |
| --- | --- |
| `gitignored.md` | refused, naming `data/command-center-roadmap.md` |
| `primary-checkout.md` | refused, naming the `~/firstmate/...` paths |
| `pool-lease.md` | refused, naming `bin/fm-home-seed.sh` and `bin/fm-spawn.sh` |
| `status-redirect.md` | refused, naming the `>>` target and the missing verb |
| `clean.md` | **passes** - the shape a real brief has |
| `lookalike.md` | **passes** - every near-miss the rules must not match |

`lookalike.md` is the one that keeps this gate honest. A gate that refuses
everything is not a gate; the three refused fixtures prove the rules fire, and
this one proves they fire only on the real thing.
