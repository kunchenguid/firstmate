# Brief-preflight fixtures

One brief per rule in `bin/fm-preflight-lib.sh`, plus the two that must PASS.

Every fixture is written for task id `fixture-k3`, so `state/fixture-k3.*` and
`data/fixture-k3/` are the sanctioned self-references and any other id under the
primary checkout is another task's material.

| file | expectation |
| --- | --- |
| `gitignored.md` | refused, naming `data/command-center-roadmap.md` |
| `primary-checkout.md` | refused, naming all three offenders: the `~/firstmate/...` paths and the `__PRIMARY__/...` one |
| `pool-lease.md` | refused, naming `bin/fm-home-seed.sh` and `bin/fm-spawn.sh` |
| `status-redirect.md` | refused, naming the `>>` target and the missing verb |
| `clean.md` | **passes** - the shape a real brief has |
| `lookalike.md` | **passes** - every near-miss the rules must not match |

## `__PRIMARY__`

A fixture cannot know the checkout root of the machine reading it, so wherever an
ABSOLUTE primary-checkout path is meant the fixture writes `__PRIMARY__` and the
suite substitutes a root it chose itself.

This is not cosmetic.
An earlier cut hardcoded one machine's root (`/Users/.../firstmate`), which meant
that offender was under no root anywhere else: the preflight never reported it,
and the assertion naming it passed on exactly one laptop and failed in CI.
A gate must never assert a property of the machine it runs on.
The suite therefore renders every `__PRIMARY__` fixture under two different roots
and asserts against the root the run actually used.

`lookalike.md` is the one that keeps this gate honest. A gate that refuses
everything is not a gate; the three refused fixtures prove the rules fire, and
this one proves they fire only on the real thing.
