#!/bin/sh
# Xcode Cloud: make sure the Metal Toolchain is present before the build.
#
# Since Xcode 26 the Metal compiler is a separately downloaded component, and
# Xcode Cloud's images don't always include it. Without it the archive dies at
# CompileMetalFile for PerfectDayGlow.metal ("cannot execute tool 'metal' due to
# missing Metal Toolchain"). Runs after the clone, before dependencies and the
# xcodebuild action. Safe to run when the toolchain is already installed.
set -u

echo "ci_post_clone: checking Metal Toolchain"
if xcodebuild -showComponent metalToolchain >/dev/null 2>&1; then
  echo "ci_post_clone: Metal Toolchain already installed"
  xcodebuild -showComponent metalToolchain 2>/dev/null || true
  exit 0
fi

echo "ci_post_clone: downloading Metal Toolchain"
if ! xcodebuild -downloadComponent metalToolchain; then
  echo "ci_post_clone: Metal Toolchain download FAILED — the build will fail at CompileMetalFile" >&2
  exit 1
fi
xcodebuild -showComponent metalToolchain 2>/dev/null || true
echo "ci_post_clone: Metal Toolchain ready"
