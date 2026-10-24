#!/usr/bin/env bash
# Build the complete Linux release bundle (counterpart of
# tool/build-windows.ps1).
#
#   ./tool/build-linux.sh                        # community defaults
#   ./tool/build-linux.sh --build-config .local/build-config.json
#   ./tool/build-linux.sh --config-url https://.../config.json
#   ./tool/build-linux.sh --offline              # drop remote control/update URLs
#
# Output: build/linux/x64/release/bundle/. Ship the whole folder: the
# asterlink_gopeed helper and data/ must stay beside the executable.
set -euo pipefail

flutter_bin="${FLUTTER:-flutter}"
dart_bin="${DART:-}"
go_bin="${GO:-go}"
config_url=""
build_config=""
offline=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flutter) flutter_bin="$2"; shift 2 ;;
    --dart) dart_bin="$2"; shift 2 ;;
    --go) go_bin="$2"; shift 2 ;;
    --build-config) build_config="$2"; shift 2 ;;
    --config-url) config_url="$2"; shift 2 ;;
    --offline) offline=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

if [[ -z "$build_config" ]]; then
  if [[ -f .local/build-config.json ]]; then
    build_config=.local/build-config.json
  else
    build_config=config/build.community.json
  fi
fi
[[ -f "$build_config" ]] || { echo "Missing build config: $build_config" >&2; exit 1; }
[[ -z "$dart_bin" ]] && dart_bin="$(dirname "$(command -v "$flutter_bin")")/dart"

# Keep the JSON as the single source of truth for both the PowerShell and the
# shell entry points. Only the fields the Dart build actually reads are emitted.
readarray -t settings < <(python3 - "$build_config" "$config_url" "$offline" <<'PY'
import json, sys
path, config_url, offline = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
with open(path, encoding='utf-8') as handle:
    data = json.load(handle)
required = {'controlEnabled', 'controlUrl', 'githubRepository', 'applicationId',
            'metricsAppKey', 'metricsChannel'}
missing = required - set(data)
extra = set(data) - required - {'announcementsUrl'}
if missing or extra:
    raise SystemExit(f'Build config fields mismatch: missing={sorted(missing)} extra={sorted(extra)}')
if not isinstance(data['controlEnabled'], bool):
    raise SystemExit('Build config field controlEnabled must be a JSON boolean')
for value in ('controlUrl', 'announcementsUrl', 'githubRepository'):
    data.setdefault(value, '')
if offline:
    data.update(controlEnabled=False, controlUrl='', githubRepository='',
                announcementsUrl='')
elif config_url:
    data.update(controlEnabled=True, controlUrl=config_url)
for value in ('controlUrl', 'announcementsUrl', 'githubRepository'):
    if not isinstance(data[value], str):
        raise SystemExit(f'Build config field {value} must be a string')
    if any(ch in data[value] for ch in '\r\n\x00'):
        raise SystemExit(f'Build config field {value} contains control characters')
if data['controlEnabled']:
    url = data['controlUrl']
    if not url.startswith('https://') or len(url) > 2048 or ' ' in url:
        raise SystemExit('controlUrl must be an absolute HTTPS URL without spaces')
print('true' if data['controlEnabled'] else 'false')
print(data['controlUrl'])
print(data['announcementsUrl'])
print(data['githubRepository'])
PY
)

control_enabled="${settings[0]}"
control_url="${settings[1]}"
announcements_url="${settings[2]}"
github_repository="${settings[3]}"

dart_defines=(
  "--dart-define=ASTERLINK_CONTROL_ENABLED=$control_enabled"
  "--dart-define=ASTERLINK_CONTROL_URL=$control_url"
  "--dart-define=ASTERLINK_ANNOUNCEMENTS_URL=$announcements_url"
  "--dart-define=ASTERLINK_GITHUB_REPO=$github_repository"
)
# Private build inputs stay out of the repository, exactly like on Windows.
for optional in .local/baidu-api.defines.json .local/cloud-command.defines.json; do
  [[ -f "$optional" ]] && dart_defines+=("--dart-define-from-file=$optional")
done

# The repository lock file was resolved against pub.flutter-io.cn, and the
# PowerShell scripts keep that mirror by default. Re-resolving against pub.dev
# would rewrite every hosted URL and can silently pick newer versions.
if [[ -z "${PUB_HOSTED_URL:-}" ]]; then
  export PUB_HOSTED_URL=https://pub.flutter-io.cn
fi
if [[ -z "${FLUTTER_STORAGE_BASE_URL:-}" ]]; then
  export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
fi
export PUB_CACHE="${PUB_CACHE:-$project_dir/.local/pub-cache}"
mkdir -p "$PUB_CACHE"

"$dart_bin" tool/sync_version.dart --check
"$flutter_bin" pub get --enforce-lockfile
GO="$go_bin" "$(dirname "${BASH_SOURCE[0]}")/build-native-linux.sh"
"$flutter_bin" build linux --release --no-pub "${dart_defines[@]}"

echo
echo "Bundle: $project_dir/build/linux/x64/release/bundle/"
