#!/usr/bin/env bash
# Sourced by fm-config-inherit-lib.sh right after it declares FM_INHERITABLE_CONFIG:
# a secondmate home inherits the primary's config/lane-target. Appends to whatever
# list is declared, once, so Kun's own list stays untouched.
case " $FM_INHERITABLE_CONFIG " in
  *" lane-target "*) ;;
  *) FM_INHERITABLE_CONFIG="$FM_INHERITABLE_CONFIG lane-target" ;;
esac
