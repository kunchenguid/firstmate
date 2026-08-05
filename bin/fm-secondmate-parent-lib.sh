#!/usr/bin/env bash

fm_secondmate_parent_record_parse() {
  local file=$1 line schema= route= parent_home= parent_host=
  local schema_count=0 route_count=0 parent_home_count=0

  FM_SECONDMATE_PARENT_ROUTE=
  FM_SECONDMATE_PARENT_HOME=
  FM_SECONDMATE_PARENT_HOST=

  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*)
        schema_count=$((schema_count + 1))
        schema=${line#schema=}
        ;;
      route=*)
        route_count=$((route_count + 1))
        route=${line#route=}
        ;;
      parent_home=*)
        parent_home_count=$((parent_home_count + 1))
        parent_home=${line#parent_home=}
        ;;
      parent_host=*)
        parent_host=${line#parent_host=}
        ;;
    esac
  done < "$file"

  [ "$schema_count" -eq 1 ] || return 1
  [ "$route_count" -eq 1 ] || return 1
  [ "$schema" = fm-secondmate-parent.v1 ] || return 1
  case "$route" in
    local)
      [ "$parent_home_count" -eq 1 ] || return 1
      [ -n "$parent_home" ] || return 1
      FM_SECONDMATE_PARENT_HOME=$parent_home
      ;;
    remote) ;;
    *) return 1 ;;
  esac

  FM_SECONDMATE_PARENT_ROUTE=$route
  FM_SECONDMATE_PARENT_HOST=$parent_host
}
