# quota-axi-pool

PATH wrapper so dispatch's `quota-axi --json` Claude runway matches `fm-model-pool`'s account reading (same `claude-accounts.json` pick, floors, usage-credit refusal). Upstream quota-axi is unchanged. Non-JSON calls exec upstream with `CLAUDE_CONFIG_DIR` from a Claude pick.

```sh
bash quota-axi-pool/install.sh          # links ~/.local/bin/quota-axi; --dry-run ok
bash quota-axi-pool/uninstall.sh
bash quota-axi-pool/tests/quota-axi-pool.test.sh
bash quota-axi-pool/run-proof.sh        # done-done journey quota-axi-pool (screen: none)
```

Needs `account-pool` (`fm-model-pool`) and `state/claude-accounts.json` from the `claude-accounts` reader.
