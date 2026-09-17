#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Parse the durable parent binding written into a seeded secondmate home.
#
# The fm-secondmate-parent.v1 record contains exactly one schema and route.
# A local route contains exactly one absolute parent_home and no parent_host.
# A secondmate below a project Firstmate also carries that stable repository authority identity.
# A remote route contains no parent_home; current provisioning includes its SSH
# alias as diagnostic-only parent_host, while legacy-compatible manifests may
# omit that field.
# Unknown fields are reserved for forward-compatible additions.
# Duplicate schema or route fields, a malformed local binding, an unsupported
# route or schema, a NUL-bearing record, and a symlinked record fail closed.
# Writers publish this record before .fm-secondmate-home so that the identity
# marker remains the seed-completion point.

fm_secondmate_parent_record_parse() {
  local file=$1 line schema='' route='' parent_home='' parent_host='' parent_role=''
  local authority_home='' authority_id='' repo_identity=''
  local schema_count=0 route_count=0 parent_home_count=0 parent_host_count=0 parent_role_count=0
  local authority_home_count=0 authority_id_count=0 repo_identity_count=0

  FM_SECONDMATE_PARENT_ROUTE=
  FM_SECONDMATE_PARENT_HOME=
  FM_SECONDMATE_PARENT_HOST=
  FM_SECONDMATE_PARENT_ROLE=
  FM_SECONDMATE_PARENT_REPO_AUTHORITY_HOME=
  FM_SECONDMATE_PARENT_REPO_AUTHORITY_ID=
  FM_SECONDMATE_PARENT_REPO_IDENTITY=

  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  # bash's read drops NUL bytes, and different bash generations disagree on the
  # result (3.2 truncates the value at the NUL, 5.x splices the surrounding
  # bytes together), so a NUL-bearing parent_home can resolve to a home the
  # record's bytes never name contiguously. Reject the whole record as corrupt
  # before any field parsing instead of letting the interpreter pick a home.
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || return 1
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
        parent_host_count=$((parent_host_count + 1))
        parent_host=${line#parent_host=}
        ;;
      parent_role=*)
        parent_role_count=$((parent_role_count + 1))
        parent_role=${line#parent_role=}
        ;;
      repo_authority_home=*)
        authority_home_count=$((authority_home_count + 1))
        authority_home=${line#repo_authority_home=}
        ;;
      repo_authority_id=*)
        authority_id_count=$((authority_id_count + 1))
        authority_id=${line#repo_authority_id=}
        ;;
      repo_identity=*)
        repo_identity_count=$((repo_identity_count + 1))
        repo_identity=${line#repo_identity=}
        ;;
    esac
  done < "$file"

  [ "$schema_count" -eq 1 ] || return 1
  [ "$route_count" -eq 1 ] || return 1
  [ "$schema" = fm-secondmate-parent.v1 ] || return 1
  if [ "$parent_role_count" -eq 1 ]; then
    case "$parent_role" in root|project-firstmate|secondmate) ;; *) return 1 ;; esac
  elif [ "$parent_role_count" -ne 0 ]; then
    return 1
  fi
  case "$route" in
    local)
      [ "$parent_home_count" -eq 1 ] || return 1
      [ "$parent_host_count" -eq 0 ] || return 1
      case "$parent_home" in /*) ;; *) return 1 ;; esac
      FM_SECONDMATE_PARENT_HOME=$parent_home
      if [ "$authority_home_count" -gt 0 ] || [ "$authority_id_count" -gt 0 ] || [ "$repo_identity_count" -gt 0 ]; then
        [ "$authority_home_count" -eq 1 ] && [ "$authority_id_count" -eq 1 ] && [ "$repo_identity_count" -eq 1 ] || return 1
        [ "$parent_role" = project-firstmate ] || return 1
        case "$authority_home" in /*) ;; *) return 1 ;; esac
        [[ "$authority_id" =~ ^sha256:[[:xdigit:]]{64}$ ]] || return 1
        [[ "$repo_identity" =~ ^sha256:[[:xdigit:]]{64}$ ]] || return 1
        FM_SECONDMATE_PARENT_REPO_AUTHORITY_HOME=$authority_home
        FM_SECONDMATE_PARENT_REPO_AUTHORITY_ID=$authority_id
        FM_SECONDMATE_PARENT_REPO_IDENTITY=$repo_identity
      elif [ "$parent_role" = project-firstmate ]; then
        return 1
      fi
      ;;
    remote)
      [ "$parent_home_count" -eq 0 ] || return 1
      [ "$authority_home_count" -eq 0 ] && [ "$authority_id_count" -eq 0 ] && [ "$repo_identity_count" -eq 0 ] || return 1
      [ "$parent_role" != project-firstmate ] || return 1
      ;;
    *) return 1 ;;
  esac

  FM_SECONDMATE_PARENT_ROUTE=$route
  FM_SECONDMATE_PARENT_HOST=$parent_host
  FM_SECONDMATE_PARENT_ROLE=$parent_role
}
