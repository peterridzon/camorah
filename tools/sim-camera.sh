#!/usr/bin/env bash
#
# Camera simulator — stands in for an Orah 4i while no hardware is available.
#
# Publishes the same shape the real camera does: four independent RTMP streams
# named 0_0, 0_1, 1_0, 1_1 under a camNN application, each carrying H.264 video
# and one channel of audio.
#
# The clips are rendered ONCE to disk and then looped with `-c copy`, so running
# the simulator costs no encoding at all. This matters more than it sounds: an
# earlier version encoded live with h264_videotoolbox, and eight of those
# saturated the very media engine the switcher was being measured on — a single
# 1080p encode dropped from 185 fps to 22 fps, and hours went into hunting a bug
# that was the test harness all along.
#
# Usage:
#   ./sim-camera.sh 1                       # cam01 → rtmp://127.0.0.1:1935
#   ./sim-camera.sh 7 rtmp://192.168.0.20:1935
#
set -euo pipefail

SLOT="${1:?usage: sim-camera.sh <slot> [rtmp-base]}"
BASE="${2:-rtmp://127.0.0.1:1935}"
CAM=$(printf "cam%02d" "$SLOT")

LENSES=(0_0 0_1 1_0 1_1)
PATTERNS=(testsrc2 smptebars rgbtestsrc testsrc)
TONES=(220 330 440 550)

# The real camera is 1920×1440 at 30 fps (measured, MEASUREMENTS M2).
SIZE=1920x1440
FPS=30
GOP=30
VBITRATE=8M
LOOP_SECONDS=20

CACHE="${TMPDIR:-/tmp}/orah-sim-clips"
mkdir -p "$CACHE"

# ── Render the loops once ─────────────────────────────────────────────────────
for i in "${!LENSES[@]}"; do
  clip="$CACHE/${LENSES[$i]}_${SIZE}_${FPS}.mp4"
  if [ ! -s "$clip" ]; then
    echo "rendering ${LENSES[$i]} (one time, cached)..."
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "${PATTERNS[$i]}=size=${SIZE}:rate=${FPS}" \
      -f lavfi -i "sine=frequency=${TONES[$i]}:sample_rate=48000" \
      -t "$LOOP_SECONDS" \
      -c:v h264_videotoolbox -b:v "$VBITRATE" -g "$GOP" -pix_fmt yuv420p \
      -c:a aac -ac 1 -ar 48000 -b:a 128k \
      "$clip"
  fi
done

pids=()
cleanup() {
  echo ""
  echo "stopping ${CAM}..."
  for pid in "${pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "${CAM} → ${BASE}/${CAM}/{0_0,0_1,1_0,1_1}   (looped, no encoding)"

for i in "${!LENSES[@]}"; do
  lens="${LENSES[$i]}"
  clip="$CACHE/${lens}_${SIZE}_${FPS}.mp4"

  # -re paces at real time, -stream_loop -1 repeats forever, -c copy means the
  # simulator touches neither CPU nor the media engine.
  ffmpeg -hide_banner -loglevel error \
    -re -stream_loop -1 -i "$clip" \
    -c copy \
    -f flv "${BASE}/${CAM}/${lens}" &

  pids+=($!)
  echo "  ${lens}  ${PATTERNS[$i]}  ${TONES[$i]} Hz  pid $!"
done

echo ""
echo "publishing. ctrl-c to stop."
wait
