# Releasing Agent Fleet

Agent Fleet remains independently versioned and installable even though its canonical source lives inside Firstmate.
Release tags use `agent-fleet-v<version>` and point at the Firstmate merge commit containing that exact component version.

## Prepare the release

1. Update `version` in `pyproject.toml` and `__version__` in `src/agent_fleet/__init__.py` to the same semantic version.
2. Run `uv lock` from this directory and commit the updated lockfile with the source change.
3. Run the complete local verification from this directory:

   ```sh
   uv sync --locked
   uv run --locked ruff check .
   uv run --locked pytest
   uv run --locked python -m compileall -q src
   uv build --out-dir dist
   ```

4. Open a Firstmate PR, wait for green repository checks, run exact-head Crosscheck, and merge only the admitted head after owner authorization.

## Tag and verify the release

1. Create the annotated `agent-fleet-v<version>` tag at the verified Firstmate merge commit and push that tag to `ruby-dlee/firstmate`.
2. Create the GitHub release from the tag and attach both files from `tools/agent-fleet/dist/`.
3. Install from the immutable tag in a clean tool environment:

   ```sh
   uv tool install --force \
     "agent-fleet @ git+https://github.com/ruby-dlee/firstmate.git@agent-fleet-v<version>#subdirectory=tools/agent-fleet"
   agent-fleet --format json version
   ```

4. Confirm that the reported CLI version matches the tag before announcing the release.

The Git tag and GitHub release are distribution records only.
Provider homes, credentials, registry data, leases, quota evidence, and session mappings are never release inputs or artifacts.
