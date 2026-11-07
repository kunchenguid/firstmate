#!/usr/bin/env bash
# Focused host-failure recovery fixtures share the extension conformance setup.
# Keep the repeated launch-timeout probes outside the short aggregate deadline.
export FM_EXTENSION_BINDING_SEGMENT=lifecycle-host-errors
exec bash "$(dirname "${BASH_SOURCE[0]}")/fm-extension-binding.test.sh"
