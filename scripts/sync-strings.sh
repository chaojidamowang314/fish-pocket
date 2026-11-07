#!/usr/bin/env bash
# Sync the UI strings in the Swift sources into app/Shared/Localizable.xcstrings without
# opening Xcode: build for the simulator (the compiler writes *.stringsdata), then merge them.
# New strings arrive untranslated; strings no longer in the code are marked stale.
# Run scripts/run-sim.sh (or the vendor scripts and build-engine.sh) once first.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/app"
xcodegen generate --quiet
xcodebuild -project DshIOS.xcodeproj -scheme DshIOS -sdk iphonesimulator -destination "generic/platform=iOS Simulator" \
  -derivedDataPath build/DerivedData -skipPackagePluginValidation ARCHS=arm64 build -quiet
data=()
while IFS= read -r file; do data+=(--stringsdata "$file"); done < <(
  find build/DerivedData/Build/Intermediates.noindex/DshIOS.build -name '*.stringsdata' \
    -path '*/Objects-normal/*' ! -name 'ExtractedAppShortcutsMetadata.stringsdata')
xcrun xcstringstool sync Shared/Localizable.xcstrings "${data[@]}"
# The source language's own entries (positional forms) come in as "new"; only "translated" ones
# compile, and without them the bundle has no zh-Hans.lproj and Chinese readers would get English.
perl -0pi -e 's/("zh-Hans" : \{\s*"stringUnit" : \{\s*"state" : )"new"/$1"translated"/g' Shared/Localizable.xcstrings
node "$root/scripts/strings-coverage.mjs"
