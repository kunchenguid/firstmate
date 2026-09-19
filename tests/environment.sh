#!/usr/bin/env bash
# Test environment boundary shared by the runner and direct test entry points.
# Call before a test creates fixtures. Tests set their deliberate per-case
# overrides afterwards; inherited operational-home routing is never a fixture.
# A startup child marker also bypasses the outer deadline and writes the parent's
# breadcrumb, so it must not cross a test entry even when home routing is clean.
# Keep this free of filesystem writes, traps, or fixture creation.
fm_test_sanitize_environment() {
  unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE \
    FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND FM_SESSION_START_STAGE_FILE \
    TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
    OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_URL JEV_BASE JEV_TIMEOUT \
    FM_JEV_DISPATCH_SHADOW FM_JEV_DISPATCH_EXTRA FM_JEV_DISPATCH_COMPACT \
    FM_WIKI_ENGINE FM_WIKI_CATALOG
}
