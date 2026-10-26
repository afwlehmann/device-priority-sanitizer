#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

app_name="Device Priority Sanitizer"
bundle_id="alex.device-priority-sanitizer"
program_name="device-priority-sanitizer"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/Info.plist")"

release_tag="${RELEASE_TAG:-}"
if [[ -n $release_tag && $release_tag != "v$version" ]]; then
  echo "release tag $release_tag does not match Info.plist version $version" >&2
  exit 1
fi

build_dir="${BUILD_DIR:-$root/build}"
dist_dir="${DIST_DIR:-$root/dist}"
payload="$build_dir/pkgroot"
component_pkg="$build_dir/$program_name-$version.pkg"
product_pkg="$dist_dir/DevicePrioritySanitizer-$version.pkg"

rm -rf "$build_dir" "$dist_dir"
mkdir -p "$build_dir" "$dist_dir"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
sources=("$root"/Sources/DevicePrioritySanitizer/*.swift)
xcrun swiftc -O \
  -module-name device_priority_sanitizer_module \
  -target arm64-apple-macos26.0 \
  -sdk "$sdk" \
  -o "$build_dir/$program_name" \
  "${sources[@]}"

app_bundle="$build_dir/$app_name.app"
mkdir -p "$app_bundle/Contents/MacOS"
install -m 0755 "$build_dir/$program_name" "$app_bundle/Contents/MacOS/$program_name"
install -m 0644 "$root/Info.plist" "$app_bundle/Contents/Info.plist"
printf 'APPL????' >"$app_bundle/Contents/PkgInfo"
codesign --force --sign - "$app_bundle/Contents/MacOS/$program_name"
codesign --force --sign - "$app_bundle"

mkdir -p "$payload/Applications" "$payload/usr/local/bin"
ditto "$app_bundle" "$payload/Applications/$app_name.app"
ln -s "/Applications/$app_name.app/Contents/MacOS/$program_name" "$payload/usr/local/bin/$program_name"

pkgbuild --root "$payload" \
  --component-plist "$root/packaging/component.plist" \
  --identifier "$bundle_id" \
  --version "$version" \
  --min-os-version "26.0" \
  --install-location / \
  --ownership recommended \
  "$component_pkg"

cat >"$build_dir/distribution.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<installer-gui-script minSpecVersion="2">
  <title>$app_name</title>
  <options hostArchitectures="arm64"/>
  <volume-check>
    <allowed-os-versions>
      <os-version min="26.0"/>
    </allowed-os-versions>
  </volume-check>
  <pkg-ref id="$bundle_id"/>
  <choices-outline>
    <line choice="default"/>
  </choices-outline>
  <choice id="default" title="$app_name">
    <pkg-ref id="$bundle_id"/>
  </choice>
  <pkg-ref id="$bundle_id" version="$version" onConclusion="none">$program_name-$version.pkg</pkg-ref>
</installer-gui-script>
XML

productbuild --distribution "$build_dir/distribution.xml" --package-path "$build_dir" "$product_pkg"
(cd "$dist_dir" && shasum -a 256 "$(basename "$product_pkg")" >"$(basename "$product_pkg").sha256")

echo "$product_pkg"
echo "$product_pkg.sha256"
