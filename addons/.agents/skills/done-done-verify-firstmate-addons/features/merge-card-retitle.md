# Legacy merge-card retitle

Run `bash merge-card/tests/retitle-old-cards.test.sh` for the regression, then `done-done run merge-card-retitle` from the repository root.
The regression drives the executable through a stub board interface; the done-done journey seeds a fixture board and drives the same executable through the real sign-off-axi.
Together they check dry-run safety, evidence preservation, key and link mapping, unmappable cards, archival, and idempotence.
