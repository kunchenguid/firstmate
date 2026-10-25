# lookout-adapter

`lookout-firstmate` turns this fleet's real data into the `lookout.fleet.v1` document that [Lookout](https://github.com/umeranjum17/lookout) shows (its contract is `docs/adapter.md` there).

```
lookout-firstmate [--home DIR] [--no-build]          # print the JSON
lookout-firstmate --serve [--port N] [--bind ADDR]   # the last good snapshot at once from /fleet.json (rebuilt every 30 s in the background; its generated_at says how old), for `lookout serve --adapter http://…/fleet.json`
```

It reuses the fleet dashboard builder (`fleet-dashboard/fm-dashboard.sh build`, run when `state/dashboard/data.json` is over 2 minutes old) and maps its `data.json` and `board.json` onto the contract; nothing is copied from the builder. Every home and state file is only read, and only whitelisted fields are taken (a lane's `.meta` gives model, harness and account id, nothing else).

Sources: `/proc` and the memory gate for `hosts`; `data.json` homes and agents with `board.json` cards for `homes`, `lanes` and `workers`; quota windows per provider and Claude account for `quota`; `board.json`'s flow lanes (30 days) for `merges`; lane history and devices for `history` and `devices`.

Test with fixture homes: `LOOKOUT_DIR=<lookout clone> lookout-adapter/tests/test.sh` (the contract check runs when `LOOKOUT_DIR` is set).

## Service

`install.sh` replaces `fm-dashboard.service` with `fm-dashboard-lookout.service`, which runs `fleet-serve`: the adapter, Lookout (`LOOKOUT_DIR`, a clone until lookout-axi is published) and `lookout-front` on the dashboard's address (tailnet IP, port 4390). Reads need no token, as before; `/tickets`, `/needs`, `/backlog`, `/measure` and `/overview` answer 301 to the sign-off board (its address from `state/signoff-board.url`, token dropped). Run `LOOKOUT_DIR=<clone> install.sh --dry-run` first. The apply starts the same command on a spare port (`SPARE_PORT`, 4395), checks `/api/fleet` and the redirect with curl, then stops the old unit and starts the new one (a swap of a second or two). `install.sh --rollback` removes the new unit and starts the old one again; the old unit's files are never edited. Install from a merged-main clone, since the unit names its path.
