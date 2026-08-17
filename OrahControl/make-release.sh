#!/usr/bin/env bash
#
# Builds 4idesk and packages it into ../release/.
#
#   ./make-release.sh              # release/4idesk-1.0.0.zip
#   ./make-release.sh 1.0.1        # a different version
#
# The zip is made with ditto, not zip(1), because a .app carries symlinks and
# resource forks that plain zip quietly flattens — the result still looks like an
# app and refuses to launch.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
VERSION="${1:-1.0.0}"
OUT="$REPO/release"
APP="$HERE/build/4idesk.app"
ZIP="$OUT/4idesk-$VERSION.zip"

"$HERE/build-app.sh" --version "$VERSION" >/dev/null
[ -d "$APP" ] || { echo "no app was built"; exit 1; }

mkdir -p "$OUT"
rm -f "$OUT"/Orah-Control-*.zip "$OUT"/Orah-Live-Studio-*.zip "$OUT"/4idesk-*.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIZE="$(du -h "$ZIP" | cut -f1)"

# The checksum file is what someone downloading the zip actually needs, so it is
# written next to it rather than only printed here.
cat > "$OUT/4idesk-$VERSION.zip.sha256" <<EOF
$SHA  4idesk-$VERSION.zip
EOF

echo "  $ZIP"
echo "  version $VERSION (build $BUILD_NUMBER), $SIZE"
echo "  sha256 $SHA"
