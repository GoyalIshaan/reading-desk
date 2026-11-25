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
# The CLI, bundled so the palette's "Sort … with Claude" command can run its `organize`.
cp "$project_dir/hooks/reading-desk" "$bundle/Contents/Resources/reading-desk"
cp -R "$project_dir/Resources/Fonts" "$project_dir/Resources/web" "$bundle/Contents/Resources/"
swiftc -target "$(uname -m)-apple-macosx14.0" -O -whole-module-optimization -module-name ReadingDesk \
    "$project_dir"/Sources/*.swift -o "$bundle/Contents/MacOS/ReadingDesk"
# Ad-hoc signatures change every build, which makes macOS forget the Automation
# (control Helium) permission. Pinning the designated requirement to the bundle ID keeps it.
codesign --force --sign - --requirements '=designated => identifier "dev.readingdesk.mac"' "$bundle"
ditto "$bundle" "$output_dir/Reading Desk.app"
printf '%s\n' "$output_dir/Reading Desk.app"
