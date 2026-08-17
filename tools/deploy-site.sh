#!/usr/bin/env bash
#
# Uploads ../site/ to an FTP host.
#
#   ./tools/deploy-site.sh            what would happen, and nothing else
#   ./tools/deploy-site.sh --push     actually upload
#
# Dry run is the default deliberately. This mirrors with --delete, which means
# anything on the server that is not in site/ goes away — and a mistyped remote
# directory would take the rest of the domain with it. Seeing the list first
# costs two seconds; getting it wrong costs an evening.
#
# Credentials live in .deploy.env beside the repository root and are never
# committed. Copy .deploy.env.example and fill it in.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="$REPO/site"
ENVFILE="$REPO/.deploy.env"

PUSH=0
[ "${1:-}" = "--push" ] && PUSH=1

[ -d "$OUT" ] || { echo "no site/ — run ./tools/build-site.sh first"; exit 1; }

if [ ! -f "$ENVFILE" ]; then
  echo "missing $ENVFILE"
  echo "copy .deploy.env.example to .deploy.env and fill in the host details."
  exit 1
fi
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a

for v in FTP_HOST FTP_USER FTP_PASS FTP_DIR; do
  [ -n "${!v:-}" ] || { echo "$v is not set in $ENVFILE"; exit 1; }
done

command -v lftp >/dev/null || {
  echo "lftp is not installed:  brew install lftp"
  exit 1
}

PROTO="${FTP_PROTO:-ftps}"       # ftps by default; plain ftp sends the password in clear
echo "  from   $OUT"
echo "  to     $PROTO://$FTP_USER@$FTP_HOST$FTP_DIR"
echo "  files  $(find "$OUT" -type f | wc -l | tr -d ' ')"
echo

if [ "$PUSH" -eq 0 ]; then
  echo "  DRY RUN — nothing will be uploaded or deleted."
  echo "  Run again with --push when the list above is right."
  echo
fi

MIRROR="mirror --reverse --delete --verbose --parallel=4"
[ "$PUSH" -eq 0 ] && MIRROR="$MIRROR --dry-run"

lftp -u "$FTP_USER","$FTP_PASS" "$PROTO://$FTP_HOST" <<EOF
set ssl:verify-certificate ${FTP_VERIFY:-true}
set ftp:ssl-force ${FTP_SSL_FORCE:-true}
set net:max-retries 2
set net:timeout 20
$MIRROR "$OUT" "$FTP_DIR"
bye
EOF

if [ "$PUSH" -eq 1 ]; then
  echo
  echo "  uploaded — $(cat "$OUT/VERSION" | tr '\n' ' ')"
fi
