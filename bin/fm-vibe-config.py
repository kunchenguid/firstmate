#!/usr/bin/env python3
"""Validate a Vibe 3.0.2 model pin using its installed config loader.

Usage: fm-vibe-config.py <vibe-executable> <model-alias>
Print the native model name only after the effective pin resolves exactly.
The packaged Python entrypoint is required; no config or credential is printed.
"""
import asyncio
import os
from pathlib import Path
import subprocess
import sys


async def validate(alias):
    from vibe.app_server._cached_layers import apply_cached_layers
    from vibe.core.config.default_orchestrator import build_default_orchestrator
    from vibe.core.config.harness_files import init_harness_files_manager

    init_harness_files_manager("user", "project")
    orchestrator = await build_default_orchestrator()
    await apply_cached_layers(orchestrator)
    config = orchestrator.config
    model = config.get_active_model()
    if getattr(config, "_missing_pin", None) or config.active_model != model.alias:
        raise ValueError("requested Vibe model is unavailable")
    if alias not in (model.alias, model.name):
        raise ValueError("Vibe resolved a different model")
    print(model.name)


def main():
    if sys.argv[1] == "--installed":
        try:
            asyncio.run(validate(sys.argv[2]))
        except Exception:
            print("error: Vibe model pin could not be verified; refusing fallback", file=sys.stderr)
            return 1
        return 0
    executable, alias = sys.argv[1:]
    try:
        with Path(executable).resolve().open() as entry:
            shebang = entry.readline().strip()
        interpreter = shebang.removeprefix("#!")
        if not shebang.startswith("#!/") or not Path(interpreter).is_file():
            raise ValueError("not a packaged Python entrypoint")
        env = dict(os.environ, VIBE_ACTIVE_MODEL=alias)
        result = subprocess.run([interpreter, __file__, "--installed", alias], env=env,
                                capture_output=True, text=True, timeout=20)
        if result.returncode or len(result.stdout.splitlines()) != 1:
            raise ValueError("model unavailable")
        print(result.stdout.strip())
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        print("error: Vibe model pin could not be verified with its installed Python config loader; refusing fallback", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
