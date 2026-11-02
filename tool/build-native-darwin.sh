#!/usr/bin/env bash
# Build the AsterLink download helper for macOS (the counterpart of
# tool/build-native-linux.sh and tool/build-native-windows.ps1).
#
# The helper speaks the same newline-delimited JSON protocol over inherited
# stdio pipes as the Windows and Linux builds, so the Dart side is unchanged.
# CGO stays disabled: the torrent stack falls back to its pure-Go uTP
# implementation, which keeps the binary self-contained and easy to sign.
#
#   ./tool/build-native-darwin.sh                 # host arch (arm64 on Apple silicon)
#   GOARCH=amd64 ./tool/build-native-darwin.sh     # Intel slice
set -euo pipefail

go_bin="${GO:-go}"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$project_dir/native/gopeed"
output_dir="$project_dir/native/bin"

mkdir -p "$output_dir"

export GOOS=darwin
export GOARCH="${GOARCH:-arm64}"
export CGO_ENABLED=0
export GOTOOLCHAIN="${GOTOOLCHAIN:-go1.24.7}"
if [[ -z "${GOPROXY:-}" ]]; then
  export GOPROXY='https://goproxy.cn,https://goproxy.io,direct'
fi

cd "$source_dir"
"$go_bin" build -mod=vendor -tags nosqlite -trimpath \
  -ldflags '-s -w -checklinkname=0 -X github.com/GopeedLab/gopeed/pkg/base.Version=1.8.1' \
  -o "$output_dir/asterlink_gopeed" ./cmd/asterlink

echo "Built $output_dir/asterlink_gopeed (darwin/$GOARCH)"
