# Orah Live Studio — 1.2.0 beta 3

Second build. Beta 1 could find cameras and draw the desk. This one gets a
picture from a real camera onto that desk, and stops doing several things that
were quietly breaking the cameras.

Rebuild this folder with `OrahControl/make-release.sh`.

---

## What changed since beta 2

### The picture is the right way up

The sensors are mounted portrait, so every frame arrives on its side — and the
two SoCs face opposite ways, so `0_0` and `0_1` arrive upside down relative to
`1_0` and `1_1`. Each lens is now turned by its own amount and the monitors are
portrait.

Display only. What leaves for the stitcher stays exactly as the camera sent it:
the calibration describes the lenses in the orientation they arrive in, and
turning the pixels would turn the seams with them.

### Output monitor

`Cmd-Shift-M`, or the **OUTPUT** button. A separate window with all four lanes
at full size, after the dissolve and the encoder — the only place the encoded
result can actually be judged. It belongs on the second screen, next to the
stitcher.

### Cameras are found without Bonjour

Bonjour is multicast, and multicast from a wireless client to wired devices is
what access points drop. Measured here: three cameras on the network, all three
answering on port 9989, **one** of them advertised.

The app now also sweeps for Orah's MAC prefix and reports hardware that is
present but silent — a different problem from a camera that is not there, and
one that sends somebody to a different place.

### It survives this Mac changing address

A new lease, a different network, a switch to the 5 GHz side: the cameras keep
publishing to the address they were given, which now belongs to nobody, and all
they report is `VIDEO_FAIL`. The app now notices its own address changing and
re-aims every camera it started. On connect it also says when a camera is
pointed somewhere else entirely.

### Named Orah Live Studio

Settings and logs moved with it. The bundle identifier deliberately did not:
macOS ties the Local Network permission to it, and losing that means the app
silently finds no cameras at all.

---

## What changed in beta 2

Everything below was found on real hardware over one day. The reasoning is in
[docs/MEASUREMENTS.md](../docs/MEASUREMENTS.md), M8 and M9.

### The camera has one control session, and does not take it back

This is the important one. A client that disappears without closing leaves the
session reserved, and the camera then answers every later attempt with `HTTP
503` — which surfaces as a start that returns `unknownError`, files that return
`unknownError`, and a camera that looks broken. Only a power cycle clears it.

Fixed in three places: the app closes its sockets on Quit, on `SIGTERM`, and the
command line tool closes them on every exit path including failures. The error
message now says what is actually wrong instead of "bad response from the
server".

### `STOP` before `START`

Cameras resume streaming to their last destination on their own, and a camera
that is already streaming answers `START` with `unknownError`. That single
misreading accounted for most of a night. Every start now stops first;
`NO_VIDEO_RUNNING` is the good case.

### `START` is sent once, not in a loop

The reference tool appears to retry, but it does not: it misreads its own reply
(it compares an opcode against a return code, and both are `1`), so every reply
looks like success. Retrying for real is worse than useless — eight starts in
sixteen seconds put a camera into a state where a file fetch that had just
worked came back `unknownError`.

### MediaMTX 1.20 shut down RTMP when launched from Finder

Its MoQ listener writes a TLS keypair into the working directory. From Finder
that is `/`, the write fails, and MediaMTX stops **every** listener including
RTMP. The app worked from a terminal and not from the Dock. MoQ is now off — in
the node configuration too, where it would have stopped recording.

### The camera opens its RTMP connections long before it publishes

Measured at over 30 seconds. Anything still silent when `readTimeout` expires is
cut, and the camera answers by tearing down and restarting the whole set — which
looks exactly like broken hardware. Now 120 seconds.

### Smaller ones

- Bonjour resolution no longer opens a TCP connection to the control port.
- A resolve that fails is retried, instead of losing the camera for the session.
- Stream readers wait for the camera to publish instead of giving up first.
- The monitor shows the first lens that has a picture; it was pinned to `0_0`,
  which is routinely one of the two a half-started camera does not send.
- The video layer is owned properly, so frames actually reach the screen. This
  was the last thing standing between a working pipeline and a black window.
- A camera whose streams are already arriving is adopted rather than ignored.
- A dropped control connection reconnects, with a backoff that only resets after
  the connection has survived long enough to have been useful.
- Everything is logged to `~/Library/Logs/Orah Live Studio/orah.log`.

---

## Install

1. Unzip and put **Orah Live Studio.app** in `/Applications`.
2. `brew install ffmpeg mediamtx`
3. First launch needs **right-click → Open**; the app is signed ad-hoc.
4. Allow **local network access** when asked. Without it Bonjour returns nothing
   and no camera is ever found.

Requires macOS 14 or later.

---

## Put the Mac on cable

Four streams per camera is about 60 Mbit/s, and twelve streams from three
cameras is about 180. Measured here on 802.11n at 2.4 GHz the link negotiated
between 43 and 86 Mbit/s, and every reader failed with `Error during demuxing`.

Nothing in software fixes that. The Mac belongs on the same switch as the
cameras, on copper.

---

## Checking cameras

Read-only, one control session, writes to `camera-records/`:

```bash
orahctl checkout --number 12
```

It works through the network first — reachable at all, packet loss against the
router in the same check — and only then touches the protocol. That order is
deliberate: a switch dropping a quarter of its packets fails every protocol step
after it in ways that read as firmware faults.

`orahctl fleet` redraws the summary without touching a camera.
`orahctl renumber` works out the numbering and writes the label sheet.

---

## What is not in this build

- **The rig-check screen is designed, not built** — see
  [docs/ux/rig-check.html](../docs/ux/rig-check.html).
- Vahana has not been fed the output end to end.
- MIDI is not implemented.
- Recording is started from the node, not from the app's matrix.
- Audio routing is specified but not wired.
- Not notarised, so the first launch always needs right-click → Open.

---

## Checksum

```bash
shasum -a 256 -c Orah-Live-Studio-1.2.0.zip.sha256
```
