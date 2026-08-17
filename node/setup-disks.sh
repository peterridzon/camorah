#!/usr/bin/env bash
#
# Pools the USB-C recording disks into one directory that never fills up.
#
# Each disk stays its own filesystem — you can unplug one and carry it away with
# whole, playable files on it. They are joined with mergerfs so that MediaMTX
# writes to a single path and knows nothing about any of this: when the current
# disk drops below the free-space threshold, the next segment is simply created
# on the next disk.
#
# Because segments are 25 minutes (~3 GB), the changeover always lands on a file
# boundary. No recording is ever split across two disks.
#
#   sudo ./setup-disks.sh                 # discover and pool everything suitable
#   sudo ./setup-disks.sh --list          # just show what is attached
#   sudo ./setup-disks.sh --min-free 40G  # switch disks earlier
#
set -euo pipefail

POOL=/var/lib/orah/recordings
BRANCH_ROOT=/mnt/orah
MIN_FREE=20G
LIST_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --list)     LIST_ONLY=1; shift ;;
    --pool)     POOL="$2"; shift 2 ;;
    --min-free) MIN_FREE="$2"; shift 2 ;;
    -h|--help)  sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done

say() { printf "\n\033[1m== %s\033[0m\n" "$*"; }
ok()  { printf "   ok  %s\n" "$*"; }
warn(){ printf "   !!  %s\n" "$*"; }

# ── What is attached ──────────────────────────────────────────────────────────
# Only whole disks that are removable or on USB, and only their filesystems.
# The system disk is never touched.

ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE --target / )" 2>/dev/null || true)

mapfile -t CANDIDATES < <(
  lsblk -rno NAME,TYPE,TRAN,RM,SIZE,FSTYPE,UUID,LABEL |
  awk -v root="$ROOT_DISK" '
    $2=="part" && $6!="" && $6!="swap" {
      # NAME may be like sdb1; strip the partition number for the parent check
      parent=$1; sub(/[0-9]+$/,"",parent)
      if (parent==root) next
      print $1, $5, $6, $7, $8
    }')

say "attached disks"
if [ ${#CANDIDATES[@]} -eq 0 ]; then
  warn "no external filesystems found"
  warn "plug the USB-C disks in, or format them first (ext4 recommended)"
  exit 1
fi

for line in "${CANDIDATES[@]}"; do
  set -- $line
  printf "   /dev/%-8s %8s  %-6s  %s\n" "$1" "$2" "$3" "${5:-unlabelled}"
done

[ "$LIST_ONLY" -eq 1 ] && exit 0

# ── Mount each one ────────────────────────────────────────────────────────────
say "mounting"

mkdir -p "$BRANCH_ROOT"
BRANCHES=()
index=0

for line in "${CANDIDATES[@]}"; do
  set -- $line
  device="/dev/$1"; uuid="$4"; label="${5:-}"
  index=$((index + 1))

  name="${label:-disk$index}"
  mount_point="$BRANCH_ROOT/$name"
  mkdir -p "$mount_point"

  if mountpoint -q "$mount_point"; then
    ok "$name already mounted"
  else
    if mount UUID="$uuid" "$mount_point" 2>/dev/null; then
      ok "mounted $device at $mount_point"
    else
      warn "could not mount $device — skipping"
      continue
    fi
  fi

  # Persist by UUID so the pool survives a reboot and does not care which port
  # a disk is plugged into.
  if ! grep -q "$uuid" /etc/fstab; then
    echo "UUID=$uuid  $mount_point  auto  nofail,noatime,x-systemd.device-timeout=10  0  2" >> /etc/fstab
    ok "added $name to fstab (nofail — a missing disk never blocks boot)"
  fi

  mkdir -p "$mount_point/recordings"
  BRANCHES+=("$mount_point/recordings")
done

if [ ${#BRANCHES[@]} -eq 0 ]; then
  warn "nothing was mounted"; exit 1
fi

# ── Pool them ─────────────────────────────────────────────────────────────────
say "pooling"

if ! command -v mergerfs >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mergerfs >/dev/null 2>&1 \
    && ok "installed mergerfs" || { warn "could not install mergerfs"; exit 1; }
fi

BRANCH_SPEC=$(IFS=:; echo "${BRANCHES[*]}")
mkdir -p "$POOL"

# category.create=ff  — fill the first disk that has room, then move to the next,
#                       which is the behaviour a recordist expects: one disk
#                       fills, the next takes over.
# minfreespace        — a branch with less than this is skipped for NEW files.
#                       Segments are ~3 GB, so the margin is generous.
# moveonenospc=false  — never shuffle a recording between disks mid-write.
OPTIONS="defaults,allow_other,use_ino,category.create=ff,minfreespace=${MIN_FREE},moveonenospc=false,dropcacheonclose=true"

if mountpoint -q "$POOL"; then
  umount "$POOL" || warn "pool busy — stop orah-mediamtx first"
fi

mergerfs -o "$OPTIONS" "$BRANCH_SPEC" "$POOL"
ok "pooled ${#BRANCHES[@]} disk(s) at $POOL"

if ! grep -q "mergerfs.*$POOL" /etc/fstab; then
  echo "$BRANCH_SPEC  $POOL  fuse.mergerfs  $OPTIONS  0  0" >> /etc/fstab
  ok "pool added to fstab"
fi

# ── Report ────────────────────────────────────────────────────────────────────
say "result"
df -h "$POOL" | tail -1 | awk '{printf "   pool      %s total, %s free\n", $2, $4}'
for branch in "${BRANCHES[@]}"; do
  df -h "$branch" | tail -1 | awk -v b="$branch" '{printf "   %-28s %6s free of %s\n", b, $4, $2}'
done

echo ""
echo "   MediaMTX writes to $POOL and never sees the individual disks."
echo "   When one drops below $MIN_FREE free, the next segment lands on the next disk."
echo "   Any disk can be unplugged and carried away with whole files on it."
