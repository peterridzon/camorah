# 4i Studio

### Multicam 360°, cut live, out in 4K.

A vision mixer for immersive shows: twenty-four cameras on one desk, cut and
shaded in real time, stitched to a full 4K sphere on the way out. Resolution is
not baked in — the desk scales with the cameras you put in front of it, to 8K
and beyond.

🌐 **[4istudio.tv](https://4istudio.tv)** — every design on that site is live,
not a screenshot: click the buses, drag the T-bar, switch layouts.

![The console](docs/ui/console.png)

---

## The desk does not know what resolution it is running

Nothing in the signal path is written for a picture size. Nodes record by
**stream copy**, so they are indifferent by construction. The Mac decodes
exactly two cameras — programme and preview — and hands the same four lanes
onward in whatever shape they arrived. The sphere is assembled at the far end,
and it is the stitcher that decides how big it comes out.

| | | |
|---|---|---|
| **Today** | 4K sphere | Twenty-four Orah 4i, four lenses each at 1920×1440. Proven end to end |
| **Tomorrow** | 8K and 16K | The ceiling is the hardware decoder and the stitcher, never the application |
| **Any camera** | Not an Orah tool | Orah is what it was built against because that fleet exists and its maker does not. Anything that publishes RTMP fits |

---

## The whole show, from the truss to the audience

![Signal flow](docs/ui/signalflow.png)

```
Orah 4i ×24 ──RTMP──▶ PoE switch ──▶ HP mini ×4 ──┬──▶ ISO on disk  (stream copy)
                                                  └──▶ proxy ──fibre──▶ Mac
                     Mac ──▶ colour ──▶ Metal dissolve ──4×RTMP──▶ Vahana ──▶ 4K
                     Mac ◀──────────── control · 9989 ────────────▶ cameras
```

The two paths that leave a node never meet again: one carries the show, the
other carries the recording, and nothing on the desk can reach the second one.

---

## The camera outlived its company

The **Orah 4i** is a four-lens 360° camera. Each unit carries two SoCs on
consecutive addresses and publishes four RTMP streams at 1920×1440, which a
stitching box used to assemble into a 4K sphere. Orah is gone: the update
servers are dead, the boxes were unstable, and there is no way to buy a
replacement for either.

There is, however, a shelf of cameras that still work. So the software was
rebuilt around them — from the wire up, with no vendor library and nothing to
phone home to.

| | |
|---|---|
| **Finds them** | ARP sweep by Orah's own MAC prefix. Bonjour is multicast, and multicast from a wireless client to wired cameras is exactly what access points drop |
| **Keeps them** | Presence decided by the burned-in MAC, never by an open port — a recycled DHCP lease can never make one camera look like another |
| **Runs them** | CamAPI protobuf over WebSocket, implemented from the wire up and paced so the firmware survives it |

---

## Everything here was measured, not assumed

- **Only pictures prove anything.** The camera reports success the moment it
  accepts a command, long before a packet moves. Every state in this
  application is decided by streams arriving, never by a return code.
- **Never send what it cannot come back from.** This firmware can be wedged by
  talking to it too fast. Commands are paced, START is asked once, and a camera
  being worked on is left completely alone.
- **The recording is sacred.** Nodes record ISO by stream copy. Colour, mixing
  and effects ride the live path only — there is no setting that can
  contaminate the master.
- **Say which of the two problems it is.** "Camera is not there" and "camera is
  there but silent" send different people to different places. The interface
  never merges them.
- **One state, one place.** There used to be four sources for "is it working".
  They disagreed, and the desk showed a camera on air beside a button offering
  to start it.

---

## Colour: per camera, on the live path only

![Colour correction](docs/ui/colour.png)

The cameras do not match each other, so correction is per unit and never
global. An exposure lever and a two-axis puck — gamma across, master black up
and down — carry most of the work, exactly as on a remote control panel.

None of it reaches the camera: the Orah protocol has no exposure or gamma
control, so all of it happens in the Metal pass. **The ISO recording never sees
any of it.**

---

## Getting started

```bash
brew install ffmpeg mediamtx      # the only two dependencies
cd OrahControl && ./build-app.sh  # builds the .app — no Xcode needed
open "build/4i Studio.app"
```

There is nothing to configure. Power the cameras, open the app, and it finds
them.

```bash
orahctl discover           # what is on the network
orahctl checkout <host>    # survey one camera and archive its calibration
orahctl fleet              # rebuild the fleet sheet from the records
```

---

## From a box of cameras to a show

1. **Power the cameras and open the app.** It sweeps the subnet by MAC prefix
   and adopts anything answering on 9989, announced or not.
2. **Run the rig check.** Each camera reads *not on the network*, *still
   booting*, *ready — press Start*, or a count of lenses arriving. A unit
   someone is working on gets **FIX** and is left alone.
3. **Number them once.** **INSTALL** binds a serial to a position, and the
   number follows the hardware from then on.
4. **Press Start All.** About twenty seconds to all four lenses. A `START`
   answered `UNKNOWN_ERROR` means a SoC did not come up — pull that camera's
   power rather than trying again.
5. **Lay out the multiview**, send any source to a box with its amber keys, and
   undock it onto the second display.
6. **Match the cameras** in the colour corrector. The recording is unaffected.
7. **Assign the keys** left to right in the order they stand on site.
8. **Cut the show.** Programme leaves for Vahana; the nodes go on recording
   every camera clean, whatever happens on the desk.

---

## Status

A working beta. **Thirteen cameras proven end to end at four lenses each** —
the fleet survey, every fault and what fixed it are in
[`camera-records/`](camera-records/).

Not yet proven: the output consumed by Vahana, and the nodes on real hardware.
Both are architecture rather than guesswork, but neither has been run for real,
and this file will say so until it has.

---

## Documentation

| | |
|---|---|
| [`docs/MEASUREMENTS.md`](docs/MEASUREMENTS.md) | what the hardware actually does, measured. **The one worth reading** |
| [`docs/SPECIFICATION.md`](docs/SPECIFICATION.md) | what it is meant to do |
| [`docs/CALIBRATION.md`](docs/CALIBRATION.md) | the `.ptv` rig presets and what they mean |
| [`docs/FIRMWARE.md`](docs/FIRMWARE.md) | why a camera cannot be flashed from here |
| [`camera-records/FLEET.md`](camera-records/FLEET.md) | every unit, what it reported, what it did |
| [`docs/ux/`](docs/ux/) | the designs — open them in a browser, they are interactive |
| [`site/`](site/) | the website, as plain static HTML you can copy anywhere |

Every rule this application follows is in `MEASUREMENTS.md`, with the camera
behaviour that forced it:

> **M8** — Eight STARTs in sixteen seconds put a camera into a state where even
> a file fetch that had just worked came back `UNKNOWN_ERROR`.

> **M10** — A START answered `UNKNOWN_ERROR` means at least one of the two SoCs
> did not bring up video. Retrying never once helped, and made one camera
> worse. It means pull the power, not try again.

---

## Firmware

The complete Orah firmware archive — every released version, the manuals, and
photographs of a disassembled unit — exists offline. It is about 3.8 GB and is
**deliberately not in this repository**; GitHub is not a backup. The file names
are listed in [`docs/FIRMWARE.md`](docs/FIRMWARE.md). If you need it, open an
issue.

It would not let you flash a camera anyway: the camera firmware is sealed
inside the signed stitching-box image, and the box is the only thing that can
write it.

---

The original Camorah project this repository grew out of is preserved as
[`CAMORAH_ORIGINAL.md`](CAMORAH_ORIGINAL.md).
