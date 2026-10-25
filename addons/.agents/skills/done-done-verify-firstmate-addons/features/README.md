# Feature map

- [Shared model pool helper](model-pool-helper.md): `fm-model-pool` pick/next JSON over the account pool with forced-limit A/B and Sol/Goat/Cursor fallovers.
- [quota-axi-pool](quota-axi-pool.md): PATH wrapper so dispatch `quota-axi --json` Claude runway matches fm-model-pool's account reading.
- [Incremental fleet-pulse chat export](incremental-fleet-pulse-chat-export.md): the refresh entry point appends only unseen redacted messages and filters injected wake lines.
- [Fleet dashboard wait reasons](fleet-dashboard-wait-reasons.md): run the approved live fleet dashboard at 390px and verify the named wait reasons and active-versus-parked counts.
- [Fleet dashboard live core](fleet-dashboard-live-core.md): run `done-done run core` (`fleet-dashboard/run-core-proof.sh`); it serves the dashboard against a seeded home and proves lanes on the Board and queue reasons on Insights at 390px in a real browser.
