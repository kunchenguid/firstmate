#!/usr/bin/env bash
# Install, inspect, or remove the single global Pi activator for one physical
# FirstMate host root.
# Usage: fm-host-setup.sh install <host-root> [--home <firstmate-home>] [--backend <name>]
#        fm-host-setup.sh status
#        fm-host-setup.sh uninstall
#
# The activator is installed under ${PI_CODING_AGENT_DIR:-~/.pi/agent} and is
# dormant unless Pi's physical cwd equals the configured host root and
# FM_TARGET_WORKTREE is unset.
# Install updates only a file carrying this script's ownership marker, refuses
# conflicting ambient FM_ROOT_OVERRIDE/FM_HOME/FM_HOST_ROOT/FM_BACKEND values,
# and writes nothing into the host repository.
# Uninstall removes only that owned activator file.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SOURCE="$FM_ROOT/.pi/extensions/lib/fm-host-activator.ts"
OWNER='// firstmate-host-activator managed-v1'
# shellcheck source=bin/fm-host-root-lib.sh
. "$SCRIPT_DIR/fm-host-root-lib.sh"

usage() {
	awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

agent_dir() {
	local dir=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
	case "$dir" in
	'~') dir=$HOME ;;
	\~/*) dir="$HOME/${dir#\~/}" ;;
	esac
	case "$dir" in
	/*) printf '%s\n' "$dir" ;;
	*) fail "PI_CODING_AGENT_DIR must be absolute (or start with ~/): $dir" ;;
	esac
}

owned_file() {
	local file=$1 first=
	[ -f "$file" ] && [ ! -L "$file" ] || return 1
	IFS= read -r first <"$file" || return 1
	[ "$first" = "$OWNER" ]
}

physical_dir() {
	local label=$1 path=$2 resolved
	[ -d "$path" ] || fail "$label is not an existing directory: $path"
	resolved=$(cd "$path" 2>/dev/null && pwd -P) || fail "$label cannot be resolved: $path"
	case "$resolved" in
	*[$'\001'-$'\037'$'\177']*) fail "$label contains a control character" ;;
	esac
	printf '%s\n' "$resolved"
}

check_ambient() {
	local name=$1 expected=$2 actual=${!1-}
	[ -z "$actual" ] || [ "$actual" = "$expected" ] ||
		fail "$name is already set to a conflicting value"
}

render_activator() {
	local output=$1 root=$2 home=$3 host=$4 backend=$5 source_json config_json
	source_json=$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$SOURCE")
	config_json=$(node -e '
    const [fmRoot, fmHome, hostRoot, backend] = process.argv.slice(1);
    process.stdout.write(JSON.stringify({ fmRoot, fmHome, hostRoot, backend }));
  ' "$root" "$home" "$host" "$backend")
	{
		printf '%s\n' "$OWNER"
		printf '// firstmate-host-config: %s\n' "$config_json"
		printf 'import activateFirstmateHost from %s;\n' "$source_json"
		printf 'const config = %s;\n' "$config_json"
		printf 'export default function (pi: Parameters<typeof activateFirstmateHost>[0]) { return activateFirstmateHost(pi, config); }\n'
	} >"$output"
}

show_status() {
	local target=$1 config_json
	if [ ! -e "$target" ] && [ ! -L "$target" ]; then
		printf 'FirstMate Pi host activator: not installed\n'
		return 0
	fi
	owned_file "$target" || fail "refusing unmanaged Pi extension: $target"
	config_json=$(sed -n 's#^// firstmate-host-config: ##p' "$target" | head -1)
	[ -n "$config_json" ] || fail "managed Pi extension has no readable configuration: $target"
	node -e '
    const c = JSON.parse(process.argv[1]);
    console.log("FirstMate Pi host activator: installed");
    console.log("host: " + c.hostRoot);
    console.log("firstmate root: " + c.fmRoot);
    console.log("firstmate home: " + c.fmHome);
    console.log("worker backend: " + c.backend);
  ' "$config_json"
}

ACTION=${1:-}
case "$ACTION" in
-h | --help)
	usage
	exit 0
	;;
status | uninstall)
	[ "$#" -eq 1 ] || fail "$ACTION takes no arguments"
	;;
install)
	shift
	;;
*)
	usage >&2
	exit 2
	;;
esac

PI_DIR=$(agent_dir)
TARGET="$PI_DIR/extensions/fm-firstmate-host.ts"

case "$ACTION" in
status)
	show_status "$TARGET"
	;;
uninstall)
	if [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
		printf 'FirstMate Pi host activator: not installed\n'
		exit 0
	fi
	owned_file "$TARGET" || fail "refusing to remove unmanaged Pi extension: $TARGET"
	rm -- "$TARGET"
	printf 'removed %s\n' "$TARGET"
	;;
install)
	command -v node >/dev/null 2>&1 || fail "node is required"
	[ -f "$SOURCE" ] || fail "activator template is missing: $SOURCE"
	HOST_ARG=${1:-}
	[ -n "$HOST_ARG" ] || fail "install requires <host-root>"
	shift
	HOME_ARG=$FM_ROOT
	BACKEND=herdr
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--home)
			[ "$#" -ge 2 ] || fail "--home requires a value"
			HOME_ARG=$2
			shift 2
			;;
		--backend)
			[ "$#" -ge 2 ] || fail "--backend requires a value"
			BACKEND=$2
			shift 2
			;;
		*) fail "unknown install argument: $1" ;;
		esac
	done

	ROOT_REAL=$(physical_dir "FirstMate root" "$FM_ROOT")
	HOME_REAL=$(physical_dir "FirstMate home" "$HOME_ARG")
	HOST_REAL=$(physical_dir "host root" "$HOST_ARG")
	fm_host_root_assert_operational_roots "$HOST_REAL" "$ROOT_REAL" "$HOME_REAL" || exit $?
	[ -f "$HOST_REAL/AGENTS.md" ] || fail "host root has no AGENTS.md: $HOST_REAL"
	(
		export FM_ROOT_OVERRIDE=$ROOT_REAL FM_HOME=$HOME_REAL
		# shellcheck source=bin/fm-backend.sh
		. "$SCRIPT_DIR/fm-backend.sh"
		fm_backend_validate_spawn "$BACKEND"
	) || exit $?

	check_ambient FM_ROOT_OVERRIDE "$ROOT_REAL"
	check_ambient FM_HOME "$HOME_REAL"
	check_ambient FM_HOST_ROOT "$HOST_REAL"
	check_ambient FM_BACKEND "$BACKEND"

	if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
		owned_file "$TARGET" || fail "refusing to overwrite unmanaged Pi extension: $TARGET"
	fi
	mkdir -p "$PI_DIR/extensions"
	TMP=$(mktemp "$PI_DIR/extensions/.fm-firstmate-host.XXXXXX") || fail "could not create temporary activator"
	trap 'rm -f "${TMP:-}"' EXIT
	render_activator "$TMP" "$ROOT_REAL" "$HOME_REAL" "$HOST_REAL" "$BACKEND"
	chmod 0644 "$TMP"
	if [ -f "$TARGET" ] && cmp -s "$TMP" "$TARGET"; then
		rm -f "$TMP"
		trap - EXIT
		printf 'unchanged %s\n' "$TARGET"
	else
		mv -f -- "$TMP" "$TARGET"
		trap - EXIT
		printf 'installed %s\n' "$TARGET"
	fi
	show_status "$TARGET"
	;;
esac
