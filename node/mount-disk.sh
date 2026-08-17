#!/usr/bin/env bash
#
# Privileged helper: attaches one more disk to the recording pool, live.
#
# The agent runs unprivileged and calls this through a narrow sudoers rule, so
# the only privileged operation on the node is exactly this one.
#
# Adding a branch to a running mergerfs takes effect immediately — recording is
# not interrupted, no process is restarted, and MediaMTX never learns that
# anything changed. Plug a disk in mid-show, press the button, carry on.
#
#   mount-disk.sh list
#   mount-disk.sh mount <UUID>
#   mount-disk.sh eject <UUID>
#
set -euo pipefail

POOL=${ORAH_POOL:-/var/lib/orah/recordings}
BRANCH_ROOT=${ORAH_BRANCH_ROOT:-/mnt/orah}

action="${1:-list}"

# Disks belonging to the system are never candidates.
root_disk() {
  lsblk -no PKNAME "$(findmnt -no SOURCE --target /)" 2>/dev/null || true
}

pool_branches() {
  # mergerfs reports its current branches through an extended attribute.
  getfattr --only-values -n user.mergerfs.branches "$POOL" 2>/dev/null || true
}

case "$action" in

  list)
    # JSON so the agent does not have to parse a table.
    root=$(root_disk)
    branches=$(pool_branches)
    printf '['
    first=1
    while read -r name size fstype uuid label mountpoint; do
      [ -z "${uuid:-}" ] && continue
      parent="${name%%[0-9]*}"
      [ "$parent" = "$root" ] && continue
      case "$fstype" in ""|swap|LVM2_member) continue ;; esac

      in_pool=false
      if [ -n "$mountpoint" ] && echo "$branches" | grep -q "$mountpoint"; then
        in_pool=true
      fi

      free_bytes=0
      if [ -n "$mountpoint" ]; then
        free_bytes=$(df -B1 --output=avail "$mountpoint" 2>/dev/null | tail -1 | tr -d ' ')
      fi

      [ $first -eq 1 ] || printf ','
      first=0
      printf '{"device":"/dev/%s","size":"%s","fstype":"%s","uuid":"%s","label":"%s","mountpoint":"%s","in_pool":%s,"free_bytes":%s}' \
        "$name" "$size" "$fstype" "$uuid" "${label:-}" "${mountpoint:-}" "$in_pool" "${free_bytes:-0}"
    done < <(lsblk -rno NAME,SIZE,FSTYPE,UUID,LABEL,MOUNTPOINT | awk '$3!=""')
    printf ']\n'
    ;;

  mount)
    uuid="${2:?usage: mount-disk.sh mount <UUID>}"
    label=$(lsblk -rno UUID,LABEL | awk -v u="$uuid" '$1==u {print $2}' | head -1)
    name="${label:-$(echo "$uuid" | cut -c1-8)}"
    mount_point="$BRANCH_ROOT/$name"

    mkdir -p "$mount_point"
    if ! mountpoint -q "$mount_point"; then
      mount UUID="$uuid" "$mount_point"
    fi
    mkdir -p "$mount_point/recordings"

    # `+<` appends a branch to a live mergerfs. Recording continues untouched;
    # the next segment that needs space can use it straight away.
    if setfattr -n user.mergerfs.branches -v "+<$mount_point/recordings" "$POOL" 2>/dev/null; then
      echo "added $mount_point/recordings to the live pool"
    else
      echo "WARNING: pool not running — disk mounted but not pooled" >&2
    fi

    # Survive a reboot, but never block one: nofail means a disk left at home
    # does not stop the node coming up.
    if ! grep -q "$uuid" /etc/fstab; then
      echo "UUID=$uuid  $mount_point  auto  nofail,noatime,x-systemd.device-timeout=10  0  2" >> /etc/fstab
    fi
    ;;

  eject)
    uuid="${2:?usage: mount-disk.sh eject <UUID>}"
    mount_point=$(lsblk -rno UUID,MOUNTPOINT | awk -v u="$uuid" '$1==u {print $2}' | head -1)
    [ -z "$mount_point" ] && { echo "not mounted" >&2; exit 1; }

    # Take it out of the pool first, so nothing new is written to it, then let
    # any in-flight write finish before unmounting.
    setfattr -n user.mergerfs.branches -v "-$mount_point/recordings" "$POOL" 2>/dev/null || true
    sync
    sleep 2
    if umount "$mount_point"; then
      echo "ejected $mount_point — safe to unplug"
    else
      echo "still busy; a file is being written. Try again in a moment." >&2
      exit 1
    fi
    ;;

  *)
    echo "usage: mount-disk.sh [list|mount <UUID>|eject <UUID>]" >&2
    exit 2
    ;;
esac
