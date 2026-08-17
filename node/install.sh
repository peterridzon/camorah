#!/usr/bin/env bash
#
# Provisions one recording node. Debian or Ubuntu, headless.
#
# Safe to run again: every step checks before acting, so re-running after a
# change or a partial failure is the normal way to use it.
#
#   sudo ./install.sh --node-id 3 --record-dir /var/lib/orah/recordings
#
# What ends up on the machine:
#   · ffmpeg, VAAPI drivers, MediaMTX
#   · orah-mediamtx.service   receives the cameras and writes them to disk
#   · orah-agent.service      status, proxy, Bonjour
#   · orah-console.service    live status on tty1, for a monitor plugged in
#
set -euo pipefail

NODE_ID=1
RECORD_DIR=/var/lib/orah/recordings
INSTALL_DIR=/opt/orah
SERVICE_USER=orah
MEDIAMTX_VERSION=v1.20.0

while [ $# -gt 0 ]; do
  case "$1" in
    --node-id)     NODE_ID="$2"; shift 2 ;;
    --record-dir)  RECORD_DIR="$2"; shift 2 ;;
    --user)        SERVICE_USER="$2"; shift 2 ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "run this with sudo"; exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say() { printf "\n\033[1m== %s\033[0m\n" "$*"; }
ok()  { printf "   ok  %s\n" "$*"; }
warn(){ printf "   !!  %s\n" "$*"; }

# ── Packages ──────────────────────────────────────────────────────────────────
say "packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# vainfo lives in vainfo on newer releases, in the va-utils package on older.
PACKAGES=(
  ffmpeg
  python3 python3-venv python3-pip
  curl ca-certificates
  vainfo
  intel-media-va-driver-non-free   # Gen9 (Skylake) and newer: HD 510 upwards
  i965-va-driver                   # fallback for older parts
  libva-drm2 libva2
)
for pkg in "${PACKAGES[@]}"; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    ok "$pkg already installed"
  else
    apt-get install -y -qq "$pkg" >/dev/null 2>&1 && ok "installed $pkg" \
      || warn "could not install $pkg (continuing)"
  fi
done

# ── Service user ──────────────────────────────────────────────────────────────
say "user and directories"

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --home "$INSTALL_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
  ok "created user $SERVICE_USER"
else
  ok "user $SERVICE_USER exists"
fi

# The GPU is what makes the proxy cheap; without these groups VAAPI silently
# refuses and the node runs degraded.
for group in video render; do
  if getent group "$group" >/dev/null; then
    usermod -aG "$group" "$SERVICE_USER"
    ok "added $SERVICE_USER to $group"
  fi
done

mkdir -p "$INSTALL_DIR" "$RECORD_DIR" /etc/orah
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" "$RECORD_DIR"
ok "record directory $RECORD_DIR"

# Recordings are the one thing an event cannot reproduce. Warn loudly if they
# are about to be written to the system disk instead of the NVMe.
RECORD_SOURCE=$(findmnt -no SOURCE --target "$RECORD_DIR" 2>/dev/null || echo "?")
ROOT_SOURCE=$(findmnt -no SOURCE --target / 2>/dev/null || echo "?")
if [ "$RECORD_SOURCE" = "$ROOT_SOURCE" ]; then
  warn "record directory is on the system disk ($RECORD_SOURCE)"
  warn "point --record-dir at the NVMe unless this is deliberate"
else
  ok "recording to $RECORD_SOURCE, separate from the system disk"
fi

# ── MediaMTX ──────────────────────────────────────────────────────────────────
say "mediamtx"

if [ -x "$INSTALL_DIR/mediamtx" ]; then
  ok "already present ($("$INSTALL_DIR/mediamtx" --version 2>/dev/null || echo unknown))"
else
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  MTX_ARCH=amd64 ;;
    aarch64) MTX_ARCH=arm64v8 ;;
    *) echo "unsupported architecture $ARCH"; exit 1 ;;
  esac
  URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_${MTX_ARCH}.tar.gz"
  curl -fsSL "$URL" -o /tmp/mediamtx.tar.gz
  tar -xzf /tmp/mediamtx.tar.gz -C "$INSTALL_DIR" mediamtx
  rm -f /tmp/mediamtx.tar.gz
  chmod +x "$INSTALL_DIR/mediamtx"
  ok "installed MediaMTX $MEDIAMTX_VERSION"
fi

# ── Agent ─────────────────────────────────────────────────────────────────────
say "agent"

install -m 0644 "$HERE/agent.py" "$INSTALL_DIR/agent.py"
sed "s#/var/lib/orah/recordings#${RECORD_DIR}#" "$HERE/mediamtx-node.yml" \
  > "$INSTALL_DIR/mediamtx.yml"
ok "agent and mediamtx config in $INSTALL_DIR"

if [ ! -d "$INSTALL_DIR/venv" ]; then
  python3 -m venv "$INSTALL_DIR/venv"
fi
"$INSTALL_DIR/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
"$INSTALL_DIR/venv/bin/pip" install -q fastapi uvicorn zeroconf >/dev/null
ok "python dependencies"

cat > /etc/orah/node.env <<EOF
# Per-node settings. Change NODE_ID on every machine.
NODE_ID=${NODE_ID}
RECORD_DIR=${RECORD_DIR}
AGENT_PORT=8000
# Cameras are normally assigned by the Mac at run time; leaving this empty is fine.
CAMERAS=
EOF
ok "/etc/orah/node.env  (node id ${NODE_ID})"

install -m 0755 "$HERE/mount-disk.sh" "$INSTALL_DIR/mount-disk.sh"

# The agent runs unprivileged. Mounting a recording disk is the only thing it
# ever needs root for, so it gets exactly that and nothing else.
cat > /etc/sudoers.d/orah <<EOF
${SERVICE_USER} ALL=(root) NOPASSWD: ${INSTALL_DIR}/mount-disk.sh
EOF
chmod 0440 /etc/sudoers.d/orah
visudo -cf /etc/sudoers.d/orah >/dev/null && ok "sudoers rule for mount-disk.sh only"

chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# ── Services ──────────────────────────────────────────────────────────────────
say "services"

for unit in orah-mediamtx.service orah-agent.service orah-console.service; do
  sed -e "s#@INSTALL_DIR@#${INSTALL_DIR}#g" \
      -e "s#@USER@#${SERVICE_USER}#g" \
      "$HERE/systemd/$unit" > "/etc/systemd/system/$unit"
  ok "$unit"
done

systemctl daemon-reload
systemctl enable --now orah-mediamtx.service >/dev/null 2>&1
systemctl enable --now orah-agent.service >/dev/null 2>&1
systemctl enable --now orah-console.service >/dev/null 2>&1
ok "enabled and started"

# ── Verify ────────────────────────────────────────────────────────────────────
say "checking hardware video"

# Listing an encoder is not the same as being able to use it: a machine can
# advertise VAAPI and still fail because the driver is missing or the user has
# no access to the render node. Finding that out during an event is not
# acceptable, so encode two frames now.
if sudo -u "$SERVICE_USER" vainfo 2>/dev/null | grep -q "VAEntrypointEncSlice"; then
  ok "VAAPI reports an encoder"
else
  warn "VAAPI reports no encoder — the node will record but serve no proxy"
fi

if sudo -u "$SERVICE_USER" ffmpeg -hide_banner -loglevel error \
     -vaapi_device /dev/dri/renderD128 \
     -f lavfi -i testsrc2=size=640x360:rate=10 -frames:v 2 \
     -vf 'format=nv12,hwupload' -c:v h264_vaapi -f null - 2>/dev/null; then
  ok "hardware encode works"
else
  warn "hardware encode FAILED"
  warn "the agent will report itself degraded and skip the proxy, by design:"
  warn "software encoding would starve the recorder on this class of machine"
fi

say "done"
echo "   status page   http://$(hostname -I | awk '{print $1}'):8000/"
echo "   console       switch to tty1 to see it on a monitor"
echo "   logs          journalctl -fu orah-agent"
