#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Sealed producer, submit-acceptance, determinism, archive-shape, and refusal
# tests for the credential-free Azure validation runtime bundle.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VALIDATION="$ROOT/bin/fm-azure-validation.sh"
GUEST="$ROOT/bin/fm-azure-validation-guest.sh"
SUB=11111111-1111-4111-8111-111111111111

make_elf() {
  local path=$1 machine=${2:-62}
  python3 - "$path" "$machine" <<'PY'
import pathlib
import struct
import sys

path = pathlib.Path(sys.argv[1])
machine = int(sys.argv[2])
header = bytearray(64)
header[:16] = b"\x7fELF\x02\x01\x01\x00" + b"\x00" * 8
struct.pack_into("<HHIQQQIHHHHHH", header, 16, 2, machine, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0)
path.write_bytes(header + b"fixture-linux-artifact\n")
PY
  chmod 755 "$path"
}

make_inputs() {
  local root=$1
  mkdir -p "$root/artifacts" "$root/gh-axi/dist/bin" \
    "$root/gh-axi/dist/src" \
    "$root/gh-axi/node_modules/fixture-dependency/dist"
  make_elf "$root/artifacts/no-mistakes"
  make_elf "$root/artifacts/codex"
  make_elf "$root/artifacts/codex-code-mode-host"
  make_elf "$root/artifacts/gh"
  make_elf "$root/artifacts/node"
  printf '%s\n' \
    '{"name":"gh-axi","version":"1.0.0","type":"module","bin":{"gh-axi":"./dist/bin/gh-axi.js"},"dependencies":{"fixture-dependency":"1.0.0"}}' \
    >"$root/gh-axi/package.json"
  printf '%s\n' '#!/usr/bin/env node' \
    'import { main } from "../src/cli.js";' 'main();' \
    >"$root/gh-axi/dist/bin/gh-axi.js"
  printf '%s\n' 'import { run } from "fixture-dependency";' \
    'export function main() { run(); }' \
    >"$root/gh-axi/dist/src/cli.js"
  printf '%s\n' 'export const documentedSecretCommand = true;' \
    >"$root/gh-axi/dist/src/secret.js"
  printf '%s\n' '{"kind":"safe-tokenizer-metadata"}' \
    >"$root/gh-axi/dist/src/tokenizer.json"
  printf '%s\n' '{"kind":"safe-passwordless-metadata"}' \
    >"$root/gh-axi/dist/src/passwordless.json"
  printf '%s\n' '{"kind":"safe-secretary-metadata"}' \
    >"$root/gh-axi/dist/src/secretary.json"
  printf '%s\n' '{"kind":"safe-author-metadata"}' \
    >"$root/gh-axi/dist/src/author.json"
  printf '%s\n' \
    '{"name":"fixture-dependency","version":"1.0.0","type":"module","exports":{".":"./dist/index.js"}}' \
    >"$root/gh-axi/node_modules/fixture-dependency/package.json"
  printf '%s\n' '/**' \
    ' * Documentation-only examples are not runtime dependencies.' \
    ' * import { VERSION } from "../src/version.js";' \
    ' * const { absent } = await import("./comment-only.js");' \
    ' */' \
    '// const absent = require("./comment-only.cjs");' \
    'export function run() { return true; }' \
    >"$root/gh-axi/node_modules/fixture-dependency/dist/index.js"
}

build_bundle() {
  local root=$1 output=$2 version=${3:-1.48.0}
  local node=${4:-$root/artifacts/node}
  "$VALIDATION" build-runtime-bundle \
    --provider codex \
    --no-mistakes "$root/artifacts/no-mistakes" \
    --provider-binary "$root/artifacts/codex" \
    --provider-extra "$root/artifacts/codex-code-mode-host" \
    --gh "$root/artifacts/gh" \
    --node "$node" \
    --gh-axi-package "$root/gh-axi" \
    --no-mistakes-version "$version" \
    --output "$output"
}

make_repo() {
  local root=$1
  mkdir -p "$root/remote.git" "$root/repo"
  git -C "$root/remote.git" init -q --bare
  git -C "$root/repo" init -q -b main
  git -C "$root/repo" config user.name fixture
  git -C "$root/repo" config user.email fixture@example.invalid
  printf '# fixture\n' >"$root/repo/README.md"
  git -C "$root/repo" add README.md
  git -C "$root/repo" commit -qm initial
  git -C "$root/repo" remote add origin "file://$root/remote.git"
  git -C "$root/repo" switch -qc fm/fixture
  git -C "$root/repo" push -q -u origin fm/fixture
}

make_credentials() {
  local root=$1
  mkdir -p "$root/auth-home/.codex"
  printf 'fixture-session\n' >"$root/auth-home/.codex/auth.json"
  printf 'fixture-github-token\n' >"$root/github-token"
  chmod 600 "$root/github-token"
  printf '%s\n' \
    "{\"schema\":\"fm.azure-validation-credentials/v1\",\"provider\":\"codex\",\"auth_home\":\"$root/auth-home\",\"github_token_file\":\"$root/github-token\"}" \
    >"$root/credentials.json"
  chmod 600 "$root/credentials.json"
}

validation() {
  local home=$1
  shift
  FM_HOME="$home" FM_AZURE_DEPLOYMENT_GENERATION=gen-one \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" FM_AZURE_NAMING_PREFIX=fmtest \
    "$VALIDATION" "$@"
}

cell_from() {
  printf '%s\n' "$1" | sed -n 's/.*cell=\(azv-[a-z0-9]*\).*/\1/p'
}

mutation_path() {
  local root=$1 operation=$2 identifier
  identifier=$(printf '%s' "$operation" | cksum | awk '{print $1}')
  printf '%s/runtime-mutation-%s.tar.gz\n' "$root" "$identifier"
}

repack_mutation() {
  local source=$1 output=$2 operation=$3
  python3 - "$source" "$output" "$operation" <<'PY'
import hashlib
import io
import json
import tarfile
import sys

source, output, operation = sys.argv[1:]
with tarfile.open(source, "r:gz") as archive:
    records = []
    for member in archive.getmembers():
        handle = archive.extractfile(member)
        if handle is None:
            raise AssertionError("fixture bundle unexpectedly contains a non-file member")
        records.append([member.name, handle.read(), member.mode])

def append_regular(name, data, mode=0o644):
    for record in records:
        if record[0] == "runtime.json":
            manifest = json.loads(record[1])
            manifest["files"].append(
                {
                    "path": name,
                    "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
                }
            )
            manifest["files"].sort(key=lambda item: item["path"])
            record[1] = (
                json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode()
            break
    records.append([name, data, mode])


def replace_regular(name, data):
    for record in records:
        if record[0] == name:
            record[1] = data
            break
    for record in records:
        if record[0] == "runtime.json":
            manifest = json.loads(record[1])
            for item in manifest["files"]:
                if item["path"] == name:
                    item["digest"] = "sha256:" + hashlib.sha256(data).hexdigest()
                    break
            record[1] = (
                json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode()
            break


if operation == "tamper":
    for record in records:
        if record[0] == "bin/codex":
            record[1] += b"tampered\n"
            break
elif operation == "drop-manifest-record":
    for record in records:
        if record[0] == "runtime.json":
            manifest = json.loads(record[1])
            manifest["files"] = [item for item in manifest["files"] if item["path"] != "bin/codex-code-mode-host"]
            record[1] = (json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n").encode()
            break
elif operation == "drop-node-path":
    for record in records:
        if record[0] == "runtime.json":
            manifest = json.loads(record[1])
            manifest.pop("node_path")
            record[1] = (
                json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode()
            break
elif operation == "ambient-node-wrapper":
    replace_regular(
        "bin/gh-axi",
        b"#!/usr/bin/env bash\nexec node /runtime/gh-axi/dist/bin/gh-axi.js \"$@\"\n",
    )
elif operation == "script-node":
    replace_regular("bin/node", b"#!/bin/sh\nexec /usr/bin/node \"$@\"\n")
elif operation == "alternate-node-ambient-shim":
    node = next(record[1] for record in records if record[0] == "bin/node")
    append_regular("alternate/node", node)
    replace_regular("bin/node", b"#!/bin/sh\nexec /usr/bin/node \"$@\"\n")
    for record in records:
        if record[0] == "runtime.json":
            manifest = json.loads(record[1])
            manifest["node_path"] = "alternate/node"
            record[1] = (
                json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode()
            break
elif operation == "missing-entrypoint":
    records = [
        record for record in records
        if record[0] != "gh-axi/dist/bin/gh-axi.js"
    ]
    for record in records:
        if record[0] == "runtime.json":
            manifest = json.loads(record[1])
            manifest["files"] = [
                item for item in manifest["files"]
                if item["path"] != "gh-axi/dist/bin/gh-axi.js"
            ]
            manifest["gh_axi_closure"] = [
                item for item in manifest["gh_axi_closure"]
                if item != "gh-axi/dist/bin/gh-axi.js"
            ]
            record[1] = (
                json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode()
            break
elif operation == "missing-dependency-entry":
    missing = "gh-axi/node_modules/fixture-dependency/dist/index.js"
    records = [record for record in records if record[0] != missing]
    for record in records:
        if record[0] == "runtime.json":
            manifest = json.loads(record[1])
            manifest["files"] = [
                item for item in manifest["files"] if item["path"] != missing
            ]
            manifest["gh_axi_closure"] = [
                item for item in manifest["gh_axi_closure"] if item != missing
            ]
            record[1] = (
                json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode()
            break
elif operation == "alternate-wrapper-path":
    wrapper = next(record[1] for record in records if record[0] == "bin/gh-axi")
    append_regular("alternate/gh-axi", wrapper, 0o755)
    for record in records:
        if record[0] == "runtime.json":
            manifest = json.loads(record[1])
            manifest["gh_axi_path"] = "alternate/gh-axi"
            record[1] = (
                json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode()
            break
elif operation == "manifest-secret-field":
    for record in records:
        if record[0] == "runtime.json":
            manifest = json.loads(record[1])
            manifest["access_token"] = "hostile-fixture"
            record[1] = (
                json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode()
            break
elif operation == "record-secret-field":
    for record in records:
        if record[0] == "runtime.json":
            manifest = json.loads(record[1])
            manifest["files"][0]["client_secret"] = "hostile-fixture"
            record[1] = (
                json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode()
            break
elif operation == "duplicate-root-field":
    for record in records:
        if record[0] == "runtime.json":
            manifest = json.loads(record[1])
            encoded = json.dumps(manifest, sort_keys=True, separators=(",", ":"))
            needle = '"provider":"{}"'.format(manifest["provider"])
            record[1] = encoded.replace(needle, needle + "," + needle, 1).encode() + b"\n"
            break
elif operation == "duplicate-record-field":
    for record in records:
        if record[0] == "runtime.json":
            manifest = json.loads(record[1])
            encoded = json.dumps(manifest, sort_keys=True, separators=(",", ":"))
            path = manifest["files"][0]["path"]
            needle = '"path":{}'.format(json.dumps(path))
            record[1] = encoded.replace(needle, needle + "," + needle, 1).encode() + b"\n"
            break
elif operation in {
    "credential-member": ".config/gh/config.yml",
    "nested-credential-member": "gh-axi/cache/.config/gh/config.yml",
    "codex-home-member": "gh-axi/.codex/settings.json",
    "npmrc-member": "gh-axi/.npmrc",
    "credentials-member": "gh-axi/cache/credentials",
    "token-member": "gh-axi/cache/token",
    "secrets-member": "gh-axi/cache/secrets",
    "git-credentials-member": "gh-axi/.git-credentials",
    "ssh-key-member": "gh-axi/.ssh/id_rsa",
    "azure-token-member": "gh-axi/.azure/accessTokens.json",
    "env-member": "gh-axi/.env",
    "pypirc-member": "gh-axi/.pypirc",
    "docker-config-member": "gh-axi/.docker/config.json",
    "access-token-member": "gh-axi/cache/access_token.json",
    "refresh-token-member": "gh-axi/cache/refresh-token.yaml",
    "client-secret-member": "gh-axi/cache/client_secret",
    "private-key-member": "gh-axi/cache/private_key.pem",
    "normalized-secret-member": "gh-axi/CACHE/Client-Secret.JSON",
    "github-token-member": "gh-axi/cache/GitHub-Token.JSON",
    "openai-api-key-member": "gh-axi/cache/OpenAI_API_KEY.toml",
    "azure-client-secret-member": "gh-axi/cache/Azure.Client.Secret.yml",
    "auth-yaml-member": "gh-axi/cache/auth.yaml",
    "cookies-json-member": "gh-axi/cache/cookies.json",
    "cookie-txt-member": "gh-axi/cache/cookie.txt",
    "compact-github-token-member": "gh-axi/cache/GitHubToken.JSON",
    "compact-openai-key-member": "gh-axi/cache/OpenAIApiKey.toml",
    "compact-azure-secret-member": "gh-axi/cache/AzureClientSecret.yml",
    "password-member": "gh-axi/cache/DatabasePassword.JSON",
    "passwd-member": "gh-axi/cache/SystemPasswd.toml",
    "passphrase-member": "gh-axi/cache/SSHKeyPassphrase.yml",
    "uppercase-github-token-member": "gh-axi/cache/GITHUBTOKEN.JSON",
    "acronym-openai-key-member": "gh-axi/cache/OpenAIAPIKey.toml",
    "uppercase-aws-key-member": "gh-axi/cache/AWSAPIKey.json",
    "uppercase-azure-secret-member": "gh-axi/cache/AZURECLIENTSECRET.yml",
    "uppercase-password-member": "gh-axi/cache/DATABASEPASSWORD.JSON",
    "uppercase-passphrase-member": "gh-axi/cache/SSHPASSPHRASE.yml",
}:
    append_regular(
        {
            "credential-member": ".config/gh/config.yml",
            "nested-credential-member": "gh-axi/cache/.config/gh/config.yml",
            "codex-home-member": "gh-axi/.codex/settings.json",
            "npmrc-member": "gh-axi/.npmrc",
            "credentials-member": "gh-axi/cache/credentials",
            "token-member": "gh-axi/cache/token",
            "secrets-member": "gh-axi/cache/secrets",
            "git-credentials-member": "gh-axi/.git-credentials",
            "ssh-key-member": "gh-axi/.ssh/id_rsa",
            "azure-token-member": "gh-axi/.azure/accessTokens.json",
            "env-member": "gh-axi/.env",
            "pypirc-member": "gh-axi/.pypirc",
            "docker-config-member": "gh-axi/.docker/config.json",
            "access-token-member": "gh-axi/cache/access_token.json",
            "refresh-token-member": "gh-axi/cache/refresh-token.yaml",
            "client-secret-member": "gh-axi/cache/client_secret",
            "private-key-member": "gh-axi/cache/private_key.pem",
            "normalized-secret-member": "gh-axi/CACHE/Client-Secret.JSON",
            "github-token-member": "gh-axi/cache/GitHub-Token.JSON",
            "openai-api-key-member": "gh-axi/cache/OpenAI_API_KEY.toml",
            "azure-client-secret-member": "gh-axi/cache/Azure.Client.Secret.yml",
            "auth-yaml-member": "gh-axi/cache/auth.yaml",
            "cookies-json-member": "gh-axi/cache/cookies.json",
            "cookie-txt-member": "gh-axi/cache/cookie.txt",
            "compact-github-token-member": "gh-axi/cache/GitHubToken.JSON",
            "compact-openai-key-member": "gh-axi/cache/OpenAIApiKey.toml",
            "compact-azure-secret-member": "gh-axi/cache/AzureClientSecret.yml",
            "password-member": "gh-axi/cache/DatabasePassword.JSON",
            "passwd-member": "gh-axi/cache/SystemPasswd.toml",
            "passphrase-member": "gh-axi/cache/SSHKeyPassphrase.yml",
            "uppercase-github-token-member": "gh-axi/cache/GITHUBTOKEN.JSON",
            "acronym-openai-key-member": "gh-axi/cache/OpenAIAPIKey.toml",
            "uppercase-aws-key-member": "gh-axi/cache/AWSAPIKey.json",
            "uppercase-azure-secret-member": "gh-axi/cache/AZURECLIENTSECRET.yml",
            "uppercase-password-member": "gh-axi/cache/DATABASEPASSWORD.JSON",
            "uppercase-passphrase-member": "gh-axi/cache/SSHPASSPHRASE.yml",
        }[operation],
        b"credential-like-fixture\n",
    )
elif operation == "hardlink-member":
    pass
else:
    raise AssertionError(operation)

with tarfile.open(output, "w:gz", format=tarfile.PAX_FORMAT) as archive:
    for name, data, mode in records:
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = mode
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mtime = 0
        archive.addfile(info, io.BytesIO(data))
    if operation == "hardlink-member":
        info = tarfile.TarInfo("gh-axi/hardlink.js")
        info.type = tarfile.LNKTYPE
        info.linkname = "gh-axi/dist/src/cli.js"
        info.mode = 0o644
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mtime = 0
        archive.addfile(info)
PY
}

build_shape_and_determinism_contract() {
  local tmp first second out marker
  fm_test_tmproot_into tmp fm-azure-runtime-build
  make_inputs "$tmp"
  mkdir -p "$tmp/fakebin"
  marker=$tmp/download-attempted
  for command in curl wget npm npx; do
    printf '#!/bin/sh\ntouch %s\nexit 99\n' "$marker" >"$tmp/fakebin/$command"
    chmod +x "$tmp/fakebin/$command"
  done
  first=$tmp/runtime-one.tar.gz
  second=$tmp/runtime-two.tar.gz
  out=$(PATH="$tmp/fakebin:$PATH" build_bundle "$tmp" "$first") \
    || fail "first runtime build failed: $out"
  assert_contains "$out" "AZURE VALIDATION RUNTIME BUILT" "runtime build did not report completion"
  assert_contains "$out" "digest=sha256:" "runtime build did not print its digest"
  [ ! -e "$marker" ] || fail "runtime producer invoked a downloader or package installer"
  PATH="$tmp/fakebin:$PATH" build_bundle "$tmp" "$second" >/dev/null \
    || fail "second runtime build failed"
  cmp -s "$first" "$second" || fail "identical inputs did not produce byte-identical bundles"
  python3 - "$first" <<'PY' || fail "runtime tar shape is not deterministic and guest-safe"
import json
import pathlib
import subprocess
import tarfile
import sys

path = pathlib.Path(sys.argv[1])
raw = path.read_bytes()
assert raw[:2] == b"\x1f\x8b"
assert raw[4:8] == b"\x00\x00\x00\x00", "gzip mtime is not zero"
with tarfile.open(path, "r:gz") as archive:
    members = archive.getmembers()
    names = [member.name for member in members]
    assert names[0] == "runtime.json"
    assert names[1:] == sorted(names[1:])
    assert len(names) == len(set(names))
    assert all(member.isfile() for member in members)
    assert all(not member.isdir() for member in members)
    assert all(member.uid == 0 and member.gid == 0 for member in members)
    assert all(member.uname == "root" and member.gname == "root" for member in members)
    assert all(member.mtime == 0 for member in members)
    assert {member.mode for member in members} <= {0o644, 0o755}
    assert archive.getmember("runtime.json").mode == 0o644
    for name in ("bin/no-mistakes", "bin/codex", "bin/codex-code-mode-host", "bin/gh", "bin/node", "bin/gh-axi"):
        assert archive.getmember(name).mode == 0o755, name
    assert not any(name.endswith("/") for name in names)
    manifest = json.load(archive.extractfile("runtime.json"))
    assert set(manifest) == {
        "schema", "provider", "no_mistakes_version", "no_mistakes_path",
        "provider_path", "gh_path", "node_path", "gh_axi_path",
        "gh_axi_entrypoint", "gh_axi_closure", "files",
    }
    assert manifest["schema"] == "fm.azure-validation-runtime/v1"
    assert manifest["provider"] == "codex"
    assert manifest["no_mistakes_version"] == "1.48.0"
    assert manifest["no_mistakes_path"] == "bin/no-mistakes"
    assert manifest["provider_path"] == "bin/codex"
    assert manifest["gh_path"] == "bin/gh"
    assert manifest["node_path"] == "bin/node"
    assert manifest["gh_axi_path"] == "bin/gh-axi"
    assert manifest["gh_axi_entrypoint"] == "gh-axi/dist/bin/gh-axi.js"
    assert manifest["gh_axi_closure"] == [
        "gh-axi/dist/bin/gh-axi.js",
        "gh-axi/dist/src/cli.js",
        "gh-axi/node_modules/fixture-dependency/dist/index.js",
        "gh-axi/node_modules/fixture-dependency/package.json",
        "gh-axi/package.json",
    ]
    assert all(set(record) == {"path", "digest"} for record in manifest["files"])
    declared = [record["path"] for record in manifest["files"]]
    assert declared == sorted(declared)
    assert set(declared) == set(names) - {"runtime.json"}
    assert "gh-axi/dist/src/tokenizer.json" in declared
    assert "gh-axi/dist/src/passwordless.json" in declared
    assert "gh-axi/dist/src/secretary.json" in declared
    assert "gh-axi/dist/src/author.json" in declared
    wrapper = archive.extractfile("bin/gh-axi").read().decode()
    assert len(wrapper.splitlines()) == 5
    assert "set -euo pipefail" in wrapper
    assert 'exec "$runtime_root/bin/node" "$runtime_root/gh-axi/dist/bin/gh-axi.js" "$@"' in wrapper
    assert "exec node " not in wrapper
    subprocess.run(["bash", "-n"], input=wrapper, text=True, check=True)
    for name in ("bin/no-mistakes", "bin/codex", "bin/codex-code-mode-host", "bin/gh", "bin/node"):
        header = archive.extractfile(name).read(20)
        assert header[:6] == b"\x7fELF\x02\x01"
        assert int.from_bytes(header[18:20], "little") == 62
PY
  out=$($VALIDATION --help) || fail "validation wrapper help failed"
  assert_contains "$out" "build-runtime-bundle" "wrapper help omitted the runtime producer"
  pass "explicit local inputs produce a no-download byte-deterministic manifest-first bundle with normalized guest-safe tar and gzip metadata"
}

real_submit_and_mutation_contract() {
  local tmp bundle home repo out cell marker real_git rc
  fm_test_tmproot_into tmp fm-azure-runtime-submit
  make_inputs "$tmp"
  bundle=$tmp/runtime.tar.gz
  build_bundle "$tmp" "$bundle" >/dev/null || fail "runtime build for submit failed"
  make_repo "$tmp/project"
  repo=$tmp/project/repo
  make_credentials "$tmp"
  printf 'validate produced runtime\n' >"$tmp/intent.txt"
  home=$tmp/home
  mkdir -p "$home" "$tmp/fakebin"
  marker=$tmp/az-called
  real_git=$(command -v git)
  printf '#!/bin/sh\ntouch %s\nexit 99\n' "$marker" >"$tmp/fakebin/az"
  cat >"$tmp/fakebin/git" <<SH
#!/bin/sh
case "\$*" in
  *' remote get-url origin') printf '%s\n' 'https://github.com/fixture/repository.git' ;;
  *' bundle create '*)
    if [ -n "\${FM_TEST_RUNTIME_SWAP_TARGET:-}" ]; then
      mv -- "\$FM_TEST_RUNTIME_SWAP_TARGET" "\$FM_TEST_RUNTIME_SWAP_TARGET.before-swap"
      ln -s -- "\$FM_TEST_RUNTIME_SWAP_REPLACEMENT" "\$FM_TEST_RUNTIME_SWAP_TARGET"
    fi
    exec '$real_git' "\$@"
    ;;
  *) exec '$real_git' "\$@" ;;
esac
SH
  chmod +x "$tmp/fakebin/az" "$tmp/fakebin/git"
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-one --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$bundle" --repo "$repo") || fail "real submit rejected the produced bundle: $out"
  cell=$(cell_from "$out")
  [ -n "$cell" ] || fail "real submit returned no validation cell"
  [ ! -e "$marker" ] || fail "non-cloud submit contacted Azure"
  python3 - "$home/state/azure-validation/$cell.json" "$bundle" <<'PY' \
    || fail "real submit did not bind the produced bundle"
import hashlib
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text())
bundle = pathlib.Path(sys.argv[2]).read_bytes()
assert state["phase"] == "queued"
assert state["request"]["runtime"]["schema"] == "fm.azure-validation-runtime/v1"
assert state["request"]["runtime"]["no_mistakes_version"] == "1.48.0"
assert set(state["request"]["runtime"]) == {
    "schema", "provider", "no_mistakes_version", "no_mistakes_path",
    "provider_path", "gh_path", "node_path", "gh_axi_path",
    "gh_axi_entrypoint", "gh_axi_closure", "files",
}
assert all(set(record) == {"path", "digest"} for record in state["request"]["runtime"]["files"])
assert state["request"]["runtime_digest"] == "sha256:" + hashlib.sha256(bundle).hexdigest()
PY

  ln -s "$bundle" "$tmp/runtime-outer-link.tar.gz"
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-outer-link --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$tmp/runtime-outer-link.tar.gz" --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an outer symlink to a runtime bundle passed real submit"
  assert_contains "$out" "regular file" "outer runtime symlink refusal was not explicit"

  mkdir -p "$tmp/operator/.AZURE/submit-source"
  cp "$bundle" "$tmp/operator/.AZURE/submit-source/runtime.tar.gz"
  ln -s .AZURE/submit-source "$tmp/operator/credential-submit-alias"
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-credential-source-alias --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$tmp/operator/credential-submit-alias/runtime.tar.gz" \
    --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a submit runtime below a credential-directory alias was accepted"
  assert_contains "$out" "source has a credential-like path" \
    "submit credential-directory alias refusal did not inspect the canonical path"

  mkdir -p "$tmp/operator/safe-submit-source"
  cp "$bundle" "$tmp/operator/safe-submit-source/runtime.tar.gz"
  ln -s safe-submit-source "$tmp/operator/safe-submit-alias"
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-parent-source-alias --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$tmp/operator/safe-submit-alias/runtime.tar.gz" \
    --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a submit runtime below a symlinked parent was accepted"
  assert_contains "$out" "without symlink components" \
    "submit runtime parent-symlink refusal did not name provenance"

  cp "$bundle" "$tmp/runtime-hardlink-source.tar.gz"
  ln "$tmp/runtime-hardlink-source.tar.gz" "$tmp/runtime-hardlink.tar.gz"
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-outer-hardlink --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$tmp/runtime-hardlink.tar.gz" --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an outer hardlink to a runtime bundle passed real submit"
  assert_contains "$out" "one link" "outer runtime hardlink refusal was not explicit"

  for mutation in \
    tamper drop-manifest-record drop-node-path ambient-node-wrapper script-node \
    alternate-node-ambient-shim alternate-wrapper-path missing-entrypoint \
    missing-dependency-entry manifest-secret-field record-secret-field \
    duplicate-root-field duplicate-record-field \
    hardlink-member credential-member \
    nested-credential-member codex-home-member npmrc-member \
    credentials-member token-member secrets-member git-credentials-member \
    ssh-key-member azure-token-member env-member pypirc-member \
    docker-config-member access-token-member refresh-token-member \
    client-secret-member private-key-member normalized-secret-member \
    github-token-member openai-api-key-member azure-client-secret-member \
    auth-yaml-member cookies-json-member cookie-txt-member \
    compact-github-token-member compact-openai-key-member \
    compact-azure-secret-member password-member passwd-member \
    passphrase-member uppercase-github-token-member acronym-openai-key-member \
    uppercase-aws-key-member uppercase-azure-secret-member \
    uppercase-password-member uppercase-passphrase-member; do
    repack_mutation "$bundle" "$(mutation_path "$tmp" "$mutation")" "$mutation"
  done
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-tamper --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$(mutation_path "$tmp" tamper)" --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "post-build file tampering passed the real submit validator"
  assert_contains "$out" "runtime bundle file digest mismatch" "tamper refusal did not name the digest mismatch"
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-drop --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$(mutation_path "$tmp" drop-manifest-record)" --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a dropped manifest inventory record passed real submit"
  assert_contains "$out" "does not exactly inventory" "dropped-record refusal did not name the inventory mismatch"
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-drop-node --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$(mutation_path "$tmp" drop-node-path)" --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a runtime without an exact Node path passed real submit"
  assert_contains "$out" "exact schema" "missing Node-path refusal was not explicit"
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-ambient-node --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$(mutation_path "$tmp" ambient-node-wrapper)" --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an ambient-Node gh-axi wrapper passed real submit"
  assert_contains "$out" "exact bundled-Node wrapper" "ambient Node wrapper refusal was not explicit"
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-script-node --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$(mutation_path "$tmp" script-node)" --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an ambient-interpreter Node shim passed real submit"
  assert_contains "$out" "Linux x86-64 ELF interpreter" "Node ELF refusal was not explicit"
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-alternate-node --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$(mutation_path "$tmp" alternate-node-ambient-shim)" --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an alternate ELF node_path hiding the ambient bin/node shim passed real submit"
  assert_contains "$out" "node_path" "alternate Node-path refusal was not explicit"
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-missing-entrypoint --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$(mutation_path "$tmp" missing-entrypoint)" --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a runtime missing the fixed gh-axi entrypoint passed real submit"
  assert_contains "$out" "runtime entrypoint" "missing gh-axi entrypoint refusal was not explicit"
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-alternate-wrapper --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$(mutation_path "$tmp" alternate-wrapper-path)" --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an alternate gh_axi_path passed real submit"
  assert_contains "$out" "gh_axi_path" "alternate wrapper-path refusal was not explicit"
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-missing-dependency --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$(mutation_path "$tmp" missing-dependency-entry)" --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an incomplete gh-axi dependency closure passed real submit"
  assert_contains "$out" "package entry is absent" "missing dependency refusal was not explicit"
  for mutation in manifest-secret-field record-secret-field; do
    rc=0
    out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
      --task "task-$mutation" --task-generation generation-one --validation-generation validation-one \
      --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
      --runtime-bundle "$(mutation_path "$tmp" "$mutation")" --repo "$repo" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "$mutation persisted into request.runtime"
    assert_contains "$out" "exact schema" "$mutation refusal did not name schema closure"
  done
  for mutation in duplicate-root-field duplicate-record-field; do
    rc=0
    out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
      --task "task-$mutation" --task-generation generation-one --validation-generation validation-one \
      --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
      --runtime-bundle "$(mutation_path "$tmp" "$mutation")" --repo "$repo" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "$mutation was collapsed by the runtime JSON parser"
    assert_contains "$out" "duplicate JSON key" \
      "$mutation refusal did not name duplicate-key rejection"
  done
  rc=0
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-archive-hardlink --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$(mutation_path "$tmp" hardlink-member)" --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an archive hardlink member passed real submit"
  assert_contains "$out" "unsafe member" "archive hardlink refusal was not explicit"
  for mutation in \
    credential-member nested-credential-member codex-home-member npmrc-member \
    credentials-member token-member secrets-member git-credentials-member \
    ssh-key-member azure-token-member env-member pypirc-member \
    docker-config-member access-token-member refresh-token-member \
    client-secret-member private-key-member normalized-secret-member \
    github-token-member openai-api-key-member azure-client-secret-member \
    auth-yaml-member cookies-json-member cookie-txt-member \
    compact-github-token-member compact-openai-key-member \
    compact-azure-secret-member password-member passwd-member \
    passphrase-member uppercase-github-token-member acronym-openai-key-member \
    uppercase-aws-key-member uppercase-azure-secret-member \
    uppercase-password-member uppercase-passphrase-member; do
    rc=0
    out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
      --task "task-$mutation" --task-generation generation-one --validation-generation validation-one \
      --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
      --runtime-bundle "$(mutation_path "$tmp" "$mutation")" --repo "$repo" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "$mutation passed the real submit credential-path gate"
    assert_contains "$out" "credential-like path" "$mutation refusal was not explicit"
  done

  cp "$bundle" "$tmp/runtime-swap.tar.gz"
  out=$(FM_TEST_RUNTIME_SWAP_TARGET="$tmp/runtime-swap.tar.gz" \
    FM_TEST_RUNTIME_SWAP_REPLACEMENT="$tmp/tamper.tar.gz" \
    PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-swap --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
    --runtime-bundle "$tmp/runtime-swap.tar.gz" --repo "$repo") \
    || fail "a post-validation hostile source swap broke staged submit: $out"
  cell=$(cell_from "$out")
  python3 - \
    "$home/state/azure-validation/$cell.json" \
    "$home/state/azure-validation/payloads/$cell/runtime.tar.gz" \
    "$tmp/runtime-swap.tar.gz.before-swap" \
    "$home/state/azure-validation/payloads/$cell/input.tar.gz" <<'PY' \
    || fail "submit did not bind and copy the exact private staged runtime bytes"
import hashlib
import json
import pathlib
import sys
import tarfile

state = json.loads(pathlib.Path(sys.argv[1]).read_text())
copied = pathlib.Path(sys.argv[2]).read_bytes()
original = pathlib.Path(sys.argv[3]).read_bytes()
with tarfile.open(sys.argv[4], "r:gz") as archive:
    packed = archive.extractfile("runtime.tar.gz").read()
digest = "sha256:" + hashlib.sha256(original).hexdigest()
assert copied == original
assert packed == original
assert state["request"]["runtime_digest"] == digest
assert "sha256:" + hashlib.sha256(copied).hexdigest() == digest
assert "sha256:" + hashlib.sha256(packed).hexdigest() == digest
PY
  pass "real submit stages no-follow one-link bytes before validation, survives a hostile source swap, rehashes the payload copy, and rejects links plus credential-bearing members"
}

input_refusal_and_atomic_output_contract() {
  local tmp output original_digest out rc credential_path refusal_index
  fm_test_tmproot_into tmp fm-azure-runtime-refusals
  make_inputs "$tmp"
  output=$tmp/runtime.tar.gz
  build_bundle "$tmp" "$output" >/dev/null || fail "baseline runtime build failed"
  original_digest=$(shasum -a 256 "$output" | awk '{print $1}')
  rc=0
  out=$(build_bundle "$tmp" "$output" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a second build replaced an existing output"
  assert_contains "$out" "output already exists" "existing-output refusal was not explicit"
  [ "$(shasum -a 256 "$output" | awk '{print $1}')" = "$original_digest" ] \
    || fail "refused double-build changed the existing output"
  [ ! -e "$output.tmp" ] || fail "refused double-build left a temporary output"

  mv "$tmp/gh-axi/dist/src/cli.js" "$tmp/cli.js.saved"
  rc=0
  out=$(build_bundle "$tmp" "$tmp/missing-import.tar.gz" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a gh-axi package with an absent real entrypoint import was accepted"
  assert_contains "$out" "gh-axi import target is absent" "missing relative import refusal was not explicit"
  [ ! -e "$tmp/missing-import.tar.gz" ] \
    || fail "missing gh-axi import left a partial output"
  mv "$tmp/cli.js.saved" "$tmp/gh-axi/dist/src/cli.js"

  mv "$tmp/gh-axi/node_modules/fixture-dependency/dist/index.js" \
    "$tmp/dependency-index.js.saved"
  rc=0
  out=$(build_bundle "$tmp" "$tmp/missing-dependency-entry.tar.gz" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a gh-axi package with an incomplete production dependency was accepted"
  assert_contains "$out" "gh-axi package entry is absent" "missing dependency entry refusal was not explicit"
  [ ! -e "$tmp/missing-dependency-entry.tar.gz" ] \
    || fail "incomplete gh-axi dependency left a partial output"
  mv "$tmp/dependency-index.js.saved" \
    "$tmp/gh-axi/node_modules/fixture-dependency/dist/index.js"

  cp "$tmp/gh-axi/node_modules/fixture-dependency/package.json" \
    "$tmp/dependency-package.json.saved"
  printf '%s\n' \
    '{"name":"fixture-dependency","version":"1.0.0","type":"module","exports":{".":"./../escaped.js"}}' \
    >"$tmp/gh-axi/node_modules/fixture-dependency/package.json"
  printf '%s\n' 'export function run() { return true; }' \
    >"$tmp/gh-axi/node_modules/escaped.js"
  rc=0
  out=$(build_bundle "$tmp" "$tmp/escaping-export.tar.gz" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a dependency export escaping its package root was accepted"
  assert_contains "$out" "escapes its package root" \
    "escaping dependency export refusal was not explicit"
  [ ! -e "$tmp/escaping-export.tar.gz" ] \
    || fail "escaping dependency export left a partial output"
  mv "$tmp/dependency-package.json.saved" \
    "$tmp/gh-axi/node_modules/fixture-dependency/package.json"
  rm "$tmp/gh-axi/node_modules/escaped.js"

  rc=0
  out=$($VALIDATION build-runtime-bundle \
    --provider codex \
    --no-mistakes "$tmp/artifacts/no-mistakes" \
    --provider-binary "$tmp/artifacts/codex" \
    --gh "$tmp/artifacts/gh" \
    --node "$tmp/artifacts/node" \
    --gh-axi-package "$tmp/gh-axi" \
    --no-mistakes-version 1.48.0 \
    --output "$tmp/missing-code-mode-host.tar.gz" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a Codex runtime without codex-code-mode-host was accepted"
  assert_contains "$out" "Codex runtime requires bin/codex-code-mode-host" \
    "missing Codex code-mode host refusal was not explicit"
  [ ! -e "$tmp/missing-code-mode-host.tar.gz" ] \
    || fail "missing Codex code-mode host left a partial output"

  chmod 644 "$tmp/artifacts/no-mistakes"
  rc=0
  out=$(build_bundle "$tmp" "$tmp/non-executable.tar.gz" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-executable no-mistakes artifact was accepted"
  assert_contains "$out" "no-mistakes artifact must be executable" "non-executable refusal was not explicit"
  [ ! -e "$tmp/non-executable.tar.gz" ] && [ ! -e "$tmp/non-executable.tar.gz.tmp" ] \
    || fail "non-executable input left a partial output"
  chmod 755 "$tmp/artifacts/no-mistakes"

  ln -s package.json "$tmp/gh-axi/package-link.json"
  rc=0
  out=$(build_bundle "$tmp" "$tmp/symlink.tar.gz" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked package input was accepted"
  assert_contains "$out" "contains a symlink" "symlink refusal was not explicit"
  [ ! -e "$tmp/symlink.tar.gz" ] && [ ! -e "$tmp/symlink.tar.gz.tmp" ] \
    || fail "symlink refusal left a partial output"
  rm "$tmp/gh-axi/package-link.json"

  printf 'credential-like fixture\n' >"$tmp/gh-axi/auth.json"
  rc=0
  out=$(build_bundle "$tmp" "$tmp/credential.tar.gz" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a credential-named package input was accepted"
  assert_contains "$out" "credential-like path" "credential-named input refusal was not explicit"
  [ ! -e "$tmp/credential.tar.gz" ] && [ ! -e "$tmp/credential.tar.gz.tmp" ] \
    || fail "credential input refusal left a partial output"
  rm "$tmp/gh-axi/auth.json"

  mkdir -p "$tmp/gh-axi/cache/.config/gh"
  printf 'nested credential-like fixture\n' \
    >"$tmp/gh-axi/cache/.config/gh/config.yml"
  rc=0
  out=$(build_bundle "$tmp" "$tmp/nested-credential.tar.gz" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a nested GitHub-config package input was accepted"
  assert_contains "$out" "credential-like path" \
    "nested GitHub-config input refusal was not explicit"
  [ ! -e "$tmp/nested-credential.tar.gz" ] \
    || fail "nested GitHub-config input left a partial output"
  rm -rf "$tmp/gh-axi/cache"

  refusal_index=0
  for credential_path in \
    .codex/settings.json .npmrc .git-credentials .ssh/id_rsa \
    .AZURE/accessTokens.JSON .env .pypirc .DOCKER/config.json \
    cache/credentials cache/token cache/secrets cache/access_token.json \
    cache/refresh.token.yaml cache/Client-Secret.JSON cache/PRIVATE-KEY.PEM \
    cache/GitHub-Token.JSON cache/OpenAI_API_KEY.toml \
    cache/Azure.Client.Secret.yml cache/auth.yaml cache/cookies.json \
    cache/cookie.txt cache/GitHubToken.JSON cache/OpenAIApiKey.toml \
    cache/AzureClientSecret.yml cache/DatabasePassword.JSON \
    cache/SystemPasswd.toml cache/SSHKeyPassphrase.yml \
    cache/GITHUBTOKEN.JSON cache/OpenAIAPIKey.toml cache/AWSAPIKey.json \
    cache/AZURECLIENTSECRET.yml cache/DATABASEPASSWORD.JSON \
    cache/SSHPASSPHRASE.yml; do
    refusal_index=$((refusal_index + 1))
    mkdir -p "$(dirname "$tmp/gh-axi/$credential_path")"
    printf 'credential-like fixture\n' >"$tmp/gh-axi/$credential_path"
    rc=0
    out=$(build_bundle "$tmp" "$tmp/credential-$refusal_index.tar.gz" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "$credential_path package input was accepted"
    assert_contains "$out" "credential-like path" \
      "$credential_path input refusal was not explicit"
    [ ! -e "$tmp/credential-$refusal_index.tar.gz" ] \
      || fail "$credential_path input left a partial output"
    rm "$tmp/gh-axi/$credential_path"
  done
  rm -rf \
    "$tmp/gh-axi/.AZURE" "$tmp/gh-axi/.codex" "$tmp/gh-axi/.DOCKER" \
    "$tmp/gh-axi/.ssh" "$tmp/gh-axi/cache"

  mkdir -p "$tmp/operator/.AZURE"
  cp "$tmp/artifacts/node" "$tmp/operator/.AZURE/accessTokens.JSON"
  rc=0
  out=$(build_bundle \
    "$tmp" "$tmp/credential-source.tar.gz" 1.48.0 \
    "$tmp/operator/.AZURE/accessTokens.JSON" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a credential-like producer source path was accepted"
  assert_contains "$out" "source has a credential-like path" \
    "credential-like source-path refusal was not explicit"
  [ ! -e "$tmp/credential-source.tar.gz" ] \
    || fail "credential-like source-path refusal left a partial output"

  ln -s .AZURE "$tmp/operator/credential-alias"
  rc=0
  out=$(build_bundle \
    "$tmp" "$tmp/credential-source-alias.tar.gz" 1.48.0 \
    "$tmp/operator/credential-alias/accessTokens.JSON" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a credential-directory alias source path was accepted"
  assert_contains "$out" "source has a credential-like path" \
    "credential-directory alias refusal did not inspect the canonical path"
  [ ! -e "$tmp/credential-source-alias.tar.gz" ] \
    || fail "credential-directory alias refusal left a partial output"

  ln -s artifacts "$tmp/safe-artifact-alias"
  rc=0
  out=$(build_bundle \
    "$tmp" "$tmp/parent-symlink-source.tar.gz" 1.48.0 \
    "$tmp/safe-artifact-alias/node" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a runtime source below a symlinked parent was accepted"
  assert_contains "$out" "without symlink components" \
    "runtime source parent-symlink refusal did not name provenance"
  [ ! -e "$tmp/parent-symlink-source.tar.gz" ] \
    || fail "runtime source parent-symlink refusal left a partial output"

  mkdir -p "$tmp/operator/.AZURE"
  cp -R "$tmp/gh-axi" "$tmp/operator/.AZURE/gh-axi-package"
  ln -s "$tmp/operator/.AZURE/gh-axi-package" "$tmp/gh-axi-credential-alias"
  rc=0
  out=$($VALIDATION build-runtime-bundle \
    --provider codex \
    --no-mistakes "$tmp/artifacts/no-mistakes" \
    --provider-binary "$tmp/artifacts/codex" \
    --provider-extra "$tmp/artifacts/codex-code-mode-host" \
    --gh "$tmp/artifacts/gh" \
    --node "$tmp/artifacts/node" \
    --gh-axi-package "$tmp/gh-axi-credential-alias" \
    --no-mistakes-version 1.48.0 \
    --output "$tmp/credential-package-alias.tar.gz" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a credential-directory alias gh-axi root was accepted"
  assert_contains "$out" "source has a credential-like path" \
    "credential-directory gh-axi alias refusal did not inspect the canonical root"
  [ ! -e "$tmp/credential-package-alias.tar.gz" ] \
    || fail "credential-directory gh-axi alias refusal left a partial output"

  ln -s "$tmp/gh-axi" "$tmp/gh-axi-safe-alias"
  rc=0
  out=$($VALIDATION build-runtime-bundle \
    --provider codex \
    --no-mistakes "$tmp/artifacts/no-mistakes" \
    --provider-binary "$tmp/artifacts/codex" \
    --provider-extra "$tmp/artifacts/codex-code-mode-host" \
    --gh "$tmp/artifacts/gh" \
    --node "$tmp/artifacts/node" \
    --gh-axi-package "$tmp/gh-axi-safe-alias" \
    --no-mistakes-version 1.48.0 \
    --output "$tmp/package-parent-symlink.tar.gz" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked gh-axi root was accepted"
  assert_contains "$out" "symlink-free directory" \
    "gh-axi root symlink refusal did not name provenance"
  [ ! -e "$tmp/package-parent-symlink.tar.gz" ] \
    || fail "gh-axi root symlink refusal left a partial output"

  ln "$tmp/gh-axi/dist/src/cli.js" "$tmp/gh-axi/hardlink.js"
  rc=0
  out=$(build_bundle "$tmp" "$tmp/package-hardlink.tar.gz" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a hardlinked gh-axi package file was accepted"
  assert_contains "$out" "one link" "package hardlink refusal was not explicit"
  [ ! -e "$tmp/package-hardlink.tar.gz" ] \
    || fail "package hardlink refusal left a partial output"
  rm "$tmp/gh-axi/hardlink.js"

  ln "$tmp/artifacts/no-mistakes" "$tmp/artifacts/no-mistakes-hardlink"
  rc=0
  out=$(build_bundle "$tmp" "$tmp/artifact-hardlink.tar.gz" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a hardlinked native artifact was accepted"
  assert_contains "$out" "one link" "artifact hardlink refusal was not explicit"
  [ ! -e "$tmp/artifact-hardlink.tar.gz" ] \
    || fail "artifact hardlink refusal left a partial output"
  rm "$tmp/artifacts/no-mistakes-hardlink"

  make_elf "$tmp/artifacts/codex" 183
  rc=0
  out=$(build_bundle "$tmp" "$tmp/wrong-arch.tar.gz" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an AArch64 provider artifact was accepted"
  assert_contains "$out" "Linux x86-64 ELF executable" "wrong-architecture refusal was not explicit"
  [ ! -e "$tmp/wrong-arch.tar.gz" ] && [ ! -e "$tmp/wrong-arch.tar.gz.tmp" ] \
    || fail "wrong-architecture refusal left a partial output"
  make_elf "$tmp/artifacts/codex"

  rc=0
  out=$(build_bundle "$tmp" "$tmp/bad-version.tar.gz" latest 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-exact no-mistakes version was accepted"
  assert_contains "$out" "exact artifact version" "bad-version refusal was not explicit"
  [ ! -e "$tmp/bad-version.tar.gz" ] && [ ! -e "$tmp/bad-version.tar.gz.tmp" ] \
    || fail "bad-version refusal created any archive output"

  pass "incomplete runtime closures, missing Codex tools, existing outputs, unsafe inputs, wrong-architecture ELF files, and bad versions refuse without partial artifacts"
}

concurrent_no_clobber_contract() {
  local tmp output expected a_pid b_pid a_rc b_rc success_count loser_log
  fm_test_tmproot_into tmp fm-azure-runtime-concurrent
  make_inputs "$tmp"
  dd if=/dev/zero of="$tmp/gh-axi/concurrency-pad.bin" bs=1048576 count=16 2>/dev/null
  output=$tmp/runtime.tar.gz
  for builder in a b; do
    (
      touch "$tmp/$builder.ready"
      while [ ! -e "$tmp/start" ]; do sleep 0.01; done
      rc=0
      build_bundle "$tmp" "$output" >"$tmp/$builder.log" 2>&1 || rc=$?
      printf '%s\n' "$rc" >"$tmp/$builder.rc"
    ) &
    case "$builder" in
      a) a_pid=$! ;;
      b) b_pid=$! ;;
    esac
  done
  while [ ! -e "$tmp/a.ready" ] || [ ! -e "$tmp/b.ready" ]; do sleep 0.01; done
  touch "$tmp/start"
  wait "$a_pid" || fail "concurrent builder A harness failed"
  wait "$b_pid" || fail "concurrent builder B harness failed"
  a_rc=$(cat "$tmp/a.rc")
  b_rc=$(cat "$tmp/b.rc")
  success_count=0
  [ "$a_rc" -eq 0 ] && success_count=$((success_count + 1))
  [ "$b_rc" -eq 0 ] && success_count=$((success_count + 1))
  [ "$success_count" -eq 1 ] \
    || fail "concurrent builders did not produce exactly one winner: a=$a_rc b=$b_rc"
  [ -f "$output" ] || fail "concurrent builders produced no final runtime"
  expected=$tmp/expected.tar.gz
  build_bundle "$tmp" "$expected" >/dev/null \
    || fail "deterministic comparison build failed"
  cmp -s "$output" "$expected" \
    || fail "concurrent winner did not publish the deterministic runtime bytes"
  loser_log=$tmp/a.log
  [ "$a_rc" -ne 0 ] || loser_log=$tmp/b.log
  grep -Eq 'output already exists|output appeared during the build' "$loser_log" \
    || fail "concurrent loser did not report the no-clobber refusal"
  [ -z "$(find "$tmp" -maxdepth 1 -name '.runtime.tar.gz.tmp.*' -print -quit)" ] \
    || fail "concurrent build left a per-invocation staging file"
  pass "two concurrent producers publish exactly one deterministic runtime without clobbering output or each other's staging files"
}

guest_runtime_recheck_contract() {
  local tmp bundle
  fm_test_tmproot_into tmp fm-azure-runtime-guest-check
  make_inputs "$tmp"
  bundle=$tmp/runtime.tar.gz
  build_bundle "$tmp" "$bundle" >/dev/null \
    || fail "runtime build for the exact guest recheck failed"
  mkdir -p "$tmp/runtime"
  tar -xzf "$bundle" -C "$tmp/runtime"
  python3 - "$GUEST" "$tmp/runtime" <<'PY' \
    || fail "the exact shipped guest runtime recheck did not enforce the sealed runtime contract"
import os
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

guest = pathlib.Path(sys.argv[1]).read_text()
root = pathlib.Path(sys.argv[2])
request = root.parent / "sealed-request.json"
request.write_text(json.dumps({"runtime": json.loads((root / "runtime.json").read_text())}))
start_marker = '  python3 - "$RUNTIME" "$REQUEST" <<\'PY\'\n'
end_marker = '\nPY\n  install -m 0755 -o root -g root "$EXTRACT/shard-bridge.py"'
start = guest.index(start_marker) + len(start_marker)
end = guest.index(end_marker, start)
script = guest[start:end]


def execute(candidate, sealed_request=request):
    return subprocess.run(
        [sys.executable, "-", str(candidate), str(sealed_request)],
        input=script,
        text=True,
        capture_output=True,
        check=False,
    )


def clone(name):
    candidate = root.parent / name
    shutil.copytree(root, candidate)
    return candidate


def write_manifest(candidate, manifest):
    (candidate / "runtime.json").write_text(
        json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
    )


def seal(candidate):
    sealed = candidate.parent / (candidate.name + "-request.json")
    manifest = json.loads((candidate / "runtime.json").read_text())
    sealed.write_text(json.dumps({"runtime": manifest}))
    return sealed


def digest(value):
    return "sha256:" + hashlib.sha256(value).hexdigest()


accepted = execute(root)
assert accepted.returncode == 0, accepted.stderr

hardlink = clone("guest-hardlink")
os.link(hardlink / "bin/node", hardlink / "node-hardlink")
assert execute(hardlink).returncode != 0

alternate = clone("guest-alternate-node")
manifest = json.loads((alternate / "runtime.json").read_text())
node = (alternate / "bin/node").read_bytes()
(alternate / "alternate").mkdir()
(alternate / "alternate/node").write_bytes(node)
(alternate / "alternate/node").chmod(0o755)
shim = b"#!/bin/sh\nexec /usr/bin/node \"$@\"\n"
(alternate / "bin/node").write_bytes(shim)
for record in manifest["files"]:
    if record["path"] == "bin/node":
        record["digest"] = digest(shim)
manifest["files"].append({"path": "alternate/node", "digest": digest(node)})
manifest["files"].sort(key=lambda item: item["path"])
manifest["node_path"] = "alternate/node"
write_manifest(alternate, manifest)
assert execute(alternate).returncode != 0

for name, missing in (
    ("guest-missing-entrypoint", "gh-axi/dist/bin/gh-axi.js"),
    ("guest-missing-dependency", "gh-axi/node_modules/fixture-dependency/dist/index.js"),
):
    candidate = clone(name)
    manifest = json.loads((candidate / "runtime.json").read_text())
    (candidate / missing).unlink()
    manifest["files"] = [item for item in manifest["files"] if item["path"] != missing]
    manifest["gh_axi_closure"] = [item for item in manifest["gh_axi_closure"] if item != missing]
    write_manifest(candidate, manifest)
    assert execute(candidate).returncode != 0

for index, relative in enumerate((
    ".git-credentials", ".ssh/id_rsa", ".AZURE/accessTokens.JSON", ".env",
    ".pypirc", ".DOCKER/config.json", "cache/access_token.json",
    "cache/refresh-token.yaml", "cache/client_secret", "cache/private_key.pem",
    "cache/GitHub-Token.JSON", "cache/OpenAI_API_KEY.toml",
    "cache/Azure.Client.Secret.yml", "cache/auth.yaml", "cache/cookies.json",
    "cache/cookie.txt", "cache/GitHubToken.JSON", "cache/OpenAIApiKey.toml",
    "cache/AzureClientSecret.yml", "cache/DatabasePassword.JSON",
    "cache/SystemPasswd.toml", "cache/SSHKeyPassphrase.yml",
    "cache/GITHUBTOKEN.JSON", "cache/OpenAIAPIKey.toml", "cache/AWSAPIKey.json",
    "cache/AZURECLIENTSECRET.yml", "cache/DATABASEPASSWORD.JSON",
    "cache/SSHPASSPHRASE.yml",
)):
    credential = clone(f"guest-credential-{index}")
    target = credential / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("hostile fixture\n")
    manifest = json.loads((credential / "runtime.json").read_text())
    manifest["files"].append(
        {"path": relative, "digest": digest(target.read_bytes())}
    )
    manifest["files"].sort(key=lambda item: item["path"])
    write_manifest(credential, manifest)
    refused = execute(credential, seal(credential))
    assert refused.returncode != 0
    assert "credential-like" in refused.stderr

manifest_extra = clone("guest-manifest-extra")
manifest = json.loads((manifest_extra / "runtime.json").read_text())
manifest["access_token"] = "hostile-fixture"
write_manifest(manifest_extra, manifest)
refused = execute(manifest_extra, seal(manifest_extra))
assert refused.returncode != 0
assert "exact schema" in refused.stderr

record_extra = clone("guest-record-extra")
manifest = json.loads((record_extra / "runtime.json").read_text())
manifest["files"][0]["private_key"] = "hostile-fixture"
write_manifest(record_extra, manifest)
refused = execute(record_extra, seal(record_extra))
assert refused.returncode != 0
assert "not exact" in refused.stderr

duplicate_root = clone("guest-duplicate-root")
manifest = json.loads((duplicate_root / "runtime.json").read_text())
encoded = json.dumps(manifest, sort_keys=True, separators=(",", ":"))
needle = '"provider":"{}"'.format(manifest["provider"])
(duplicate_root / "runtime.json").write_text(
    encoded.replace(needle, needle + "," + needle, 1) + "\n"
)
refused = execute(duplicate_root)
assert refused.returncode != 0
assert "duplicate JSON key" in refused.stderr

duplicate_record = clone("guest-duplicate-record")
manifest = json.loads((duplicate_record / "runtime.json").read_text())
encoded = json.dumps(manifest, sort_keys=True, separators=(",", ":"))
path = manifest["files"][0]["path"]
needle = '"path":{}'.format(json.dumps(path))
(duplicate_record / "runtime.json").write_text(
    encoded.replace(needle, needle + "," + needle, 1) + "\n"
)
refused = execute(duplicate_record)
assert refused.returncode != 0
assert "duplicate JSON key" in refused.stderr
PY
  pass "the exact shipped guest recheck binds duplicate-free sealed schema, fixed Node and gh-axi closure, credential policy, and one-link inventory"
}

build_shape_and_determinism_contract
real_submit_and_mutation_contract
input_refusal_and_atomic_output_contract
concurrent_no_clobber_contract
guest_runtime_recheck_contract
