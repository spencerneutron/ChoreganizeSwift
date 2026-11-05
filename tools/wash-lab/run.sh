#!/bin/zsh
# Wash lab: compile the app's ChoreWash.metal into a compute harness and render it.
#
#   tools/wash-lab/run.sh <out-dir> [wash-lab options]
#
# Examples:
#   tools/wash-lab/run.sh /tmp/wash --times 0.3,0.6,0.9,1.3,1.7,2.1,2.4
#   tools/wash-lab/run.sh /tmp/wash --dark --fps 60          # then: ffmpeg … frame-%04d.png
#
# WASH_LAB_SRC=<path to a .metal snapshot> renders that iteration instead of the shipping file.
# Builds into $WASH_LAB_BUILD (default: a temp folder), never into the repo.
set -euo pipefail
here=${0:A:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
build=${WASH_LAB_BUILD:-${TMPDIR:-/tmp}/wash-lab-build}
mkdir -p "$build"
src=${WASH_LAB_SRC:-$here/../../Choreganize/ChoreWash.metal}
xcrun -sdk macosx metal -std=metal3.0 -O3 -DWASH_SRC="\"${src:A}\"" "$here/lab.metal" -o "$build/lab.metallib"
if [[ ! -x "$build/wash-lab" || "$here/main.swift" -nt "$build/wash-lab" ]]; then
  xcrun -sdk macosx swiftc -O -o "$build/wash-lab" "$here/main.swift"
fi
out=$1; shift
"$build/wash-lab" "$build/lab.metallib" "$out" "$@"
