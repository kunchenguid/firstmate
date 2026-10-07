#!/usr/bin/env bash
# Hermetic quota-axi stand-in for the spawn quota preflight: no quota evidence
# unless a test supplies FM_FAKE_QUOTA_AXI_JSON.
printf '%s\n' "${FM_FAKE_QUOTA_AXI_JSON:-"{}"}"
