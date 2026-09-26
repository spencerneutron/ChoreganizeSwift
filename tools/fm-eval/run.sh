#!/bin/zsh
# Builds and runs the room-vision eval harness (see main.swift) on this Mac's
# on-device Foundation Models. Needs macOS 27 with Apple Intelligence turned on.
#
#   tools/fm-eval/run.sh <photos-dir> [out-dir] [--only suggest|check] [--stream]
set -euo pipefail

here=${0:A:h}
repo=${here:h:h}
photos=${1:?usage: run.sh <photos-dir> [out-dir] [--only suggest|check] [--stream]}
out=${2:-${TMPDIR:-/tmp}/fm-eval}
mkdir -p "$out"

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos27.0" \
    -o "$out/fm-eval" "$repo/Choreganize/RoomVision.swift" "$here/main.swift"

"$out/fm-eval" "$photos" "$out" "${@:3}"
