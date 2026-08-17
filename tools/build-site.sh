#!/usr/bin/env bash
#
# Assembles the public site into ../site/, ready to be uploaded anywhere that
# serves static files.
#
#   ./tools/build-site.sh
#
# The result is committed to the repository on purpose. It is a handful of HTML
# files with no build step of their own, and having them in git means the site
# can be uploaded from any machine that has a checkout — no toolchain, no node
# modules, nothing to install on a show day.
#
# Sources:
#   docs/web/*.html   the site itself
#   docs/ux/*.html    the live mockups, embedded as iframes
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="$REPO/site"

rm -rf "$OUT"
mkdir -p "$OUT/ux"

# The page refers to the mockups as ../ux/… because in the repository they live
# one level up. On the site they sit beside it, so the path is rewritten rather
# than the repository being reshaped to suit a web server.
sed 's|\.\./ux/|ux/|g' "$REPO/docs/web/index.html" > "$OUT/index.html"
cp "$REPO/docs/web/signalflow.html" "$OUT/signalflow.html"
cp "$REPO/docs/ux/"*.html "$OUT/ux/"

# A favicon that does not cost a request: the 4i wedge, inline.
cat > "$OUT/favicon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="14" fill="#0a0a0b"/>
  <path d="M14 22q-1-5 4-6l24-5q5-1 5 4v22q0 5-5 4l-24-5q-5-1-4-6z"
        fill="none" stroke="#e8a33d" stroke-width="3" stroke-linejoin="round"/>
  <circle cx="27" cy="32" r="8" fill="none" stroke="#e8a33d" stroke-width="3"/>
  <circle cx="27" cy="32" r="2.6" fill="#e8a33d"/>
</svg>
SVG

# Every page gets the icon and a description without having to carry them.
# Relative, never rooted. The folder has to work when it is opened from disk,
# dropped in the root of a domain, or copied into a subdirectory of one — and a
# path starting with / only works in the middle case.
for f in "$OUT/index.html" "$OUT/signalflow.html"; do
  /usr/bin/sed -i '' $'1a\\\n<link rel="icon" href="favicon.svg" type="image/svg+xml">' "$f"
done
for f in "$OUT/ux/"*.html; do
  /usr/bin/sed -i '' $'1a\\\n<link rel="icon" href="../favicon.svg" type="image/svg+xml">' "$f"
done

cat > "$OUT/robots.txt" <<'TXT'
User-agent: *
Allow: /
TXT

# Stamped so it is possible to tell which build is on the server.
STAMP="$(date -u +%Y-%m-%dT%H:%MZ)"
COMMIT="$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || echo local)"
printf '%s\n%s\n' "$STAMP" "$COMMIT" > "$OUT/VERSION"

echo "  site → $OUT"
echo "  $(find "$OUT" -type f | wc -l | tr -d ' ') files, $(du -sh "$OUT" | cut -f1)"
echo "  built $STAMP from $COMMIT"
echo
echo "  preview:  open \"$OUT/index.html\""
echo "  upload :  ./tools/deploy-site.sh --push"
