#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:-$project_dir/build}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
stage_dir="$(mktemp -d "$output_dir/.reading-desk.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
bundle="$stage_dir/Reading Desk.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$project_dir/Resources/Info.plist" "$bundle/Contents/Info.plist"
cp "$project_dir/Resources/helium.js" "$project_dir/Resources/DeskIcon.icns" "$bundle/Contents/Resources/"
swiftc -target "$(uname -m)-apple-macosx14.0" -O -whole-module-optimization -module-name ReadingDesk \
    "$project_dir"/Sources/*.swift -o "$bundle/Contents/MacOS/ReadingDesk"
codesign --force --sign - "$bundle"
ditto "$bundle" "$output_dir/Reading Desk.app"
printf '%s\n' "$output_dir/Reading Desk.app"
