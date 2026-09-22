"""Firstmate plugin entry point.

Registers firstmate fleet-management hooks into Hermes Agent:
  - on_session_start / on_session_reset: run fm-session-start.sh, cache digest
  - pre_llm_call: inject cached digest once per session
  - pre_verify: prevent blind stops while fleet work is active
"""

from . import hooks


def register(ctx) -> None:
    """Register all firstmate hooks with the Hermes plugin system."""
    ctx.register_hook("on_session_start", hooks.on_session_start)
    ctx.register_hook("on_session_reset", hooks.on_session_reset)
    ctx.register_hook("pre_llm_call", hooks.pre_llm_call)
    ctx.register_hook("pre_verify", hooks.pre_verify)
