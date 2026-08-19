# The core, and the rules it runs by

Written after an evening in which a change to the multiview broke the colour
panel, a change to the colour panel broke the programme monitor, and a change to
the decoder broke every camera on the network at once. None of those were hard
bugs. They were the same bug: **the desk had no core.** Each window reached into
the machinery and set something, and the last window to touch it won.

This is the core those windows are supposed to be looking at. It has five parts.
Each part owns exactly one fact, publishes it, and is the only thing allowed to
change it. A window renders. A window never decides.

```
FLEET  ──▶  STREAMS  ──▶  DECODE  ──▶  PICTURES  ──▶  MIX  ──▶  output
who is      what is        what is       who sees      what goes
out there   publishing     decoded       what          to air
```

Data flows one way. A window sits at the end of it and draws. When a window wants
something — this camera, that lens, this size — it *asks* the core, and the core
decides what that costs and whether it changes anything upstream.

---

## 1. FLEET — who is out there

**Owns:** the list of cameras, their identity, their address, their control
session, their state.

**Rules**

1. A camera is identified by its serial. Never by slot, never by address, never
   by discovery order. Slots are a label on a serial.
2. One control session per camera, opened once, held for the show. The camera
   allows exactly one; a session that is not closed cleanly locks the unit out
   until its power is pulled.
3. Knocking on a camera has a floor under it — at most one attempt per camera
   per ten seconds, and never at all against a camera that is `busy`, because
   `busy` means somebody already holds the session and knocking cannot help.
4. Presence is decided by ARP, not by an open port. A DHCP lease gets reused and
   the previous tenant answers for the new one.
5. **A camera whose streams are arriving is on the network.** Whatever presence
   thinks. A picture is proof; a missed ping is an opinion.

**Way back:** `swift test --filter FleetRules`, and the fleet is the one part
that is allowed to be conservative — when it is unsure, it does nothing.

---

## 2. STREAMS — what is actually publishing

**Owns:** for every camera, *which* of its four lenses are live in MediaMTX.

**Rules**

1. The unit is a set of lenses, never a count. A camera is two SoCs; it
   routinely publishes `1_0` and `1_1` while `0_0` never appears, and a count
   cannot say which.
2. One fact, one field. `lensesArriving` is `lensesReady.count`, derived, never
   stored — the evening's rig check drew a camera as *gone* with four lenses lit
   under it because the count was cleared in three places and the set in one.
3. What the camera *said* is not what is publishing. `state == .streaming` is
   the camera's claim; a ready path in MediaMTX is the evidence.
4. A path that stops being ready is not immediately gone. MediaMTX drops a path
   for a moment whenever a publisher reconnects.

---

## 3. DECODE — what is decoded, and at what cost

**Owns:** the ffmpeg readers and the hardware decoders. One `CameraSource` per
camera, holding one reader per lens.

**Rules**

1. **Never attach a reader to a lens that is not in STREAMS.** A reader with
   nothing to read relaunches a process for ever. Twelve of those brought the
   whole desk to its knees, flooded MediaMTX, and made the buttons lag.
2. Retries back off: 1.5 s while a camera is expected, then 4 s, then 10 s. A
   retry that never slows down is a spin loop wearing a costume.
3. **Lenses are added and removed in place. A source is never rebuilt to change
   them.** Rebuilding blacked out a picture for three seconds — and the moment
   that happens is the moment somebody presses a programme key.
4. Built on evidence, torn down on sustained absence: eight seconds of nothing,
   not one poll.
5. **Where a picture is read from is a switch, not a decision in the source.**
   On the Mac every thumbnail is a full stream decoded here — instant, exact,
   one hardware decode per camera. On the nodes each machine transcodes its own
   cameras to 480×270 at ten frames and the Mac decodes those instead. Six
   cameras do not need the nodes; twenty-four probably do, and the machine
   running the mix is the wrong one to find that out on. Programme and preview
   are never proxied: focus cannot be judged on a 480-pixel picture. A node that
   is not answering falls back to the camera, because a picture at full cost
   beats an empty wall.
6. Cost is explicit. Programme and preview decode every lens because the mix
   sends four lanes out. Every other camera decodes exactly one — the lens its
   tile is set to, or the first one that exists if that half of the camera never
   came up. Twenty-four thumbnails is twenty-four decodes, not ninety-six.

---

## 4. PICTURES — who sees what

This is the part that did not exist, and its absence is what broke the evening.

**Owns:** one sink per camera, and the demand for them.

Today a view calls `watch(...)` and the switcher's single "who am I inspecting"
setting is overwritten by whichever view ran last. Open the colour panel and the
multiview goes black; open the multiview and the colour columns go black. Both
views were written correctly. The core let them fight.

**How it must work**

```
window ──▶ Pictures.subscribe(camera:, lens:)  ──▶  Ticket
                       │
                       ├── refcounted: N windows, one decode
                       ├── raises demand in DECODE if that lens is not decoded
                       └── returns the camera's sink — the same one, every time

window closes ──▶ ticket.cancel() ──▶ demand falls ──▶ DECODE releases what
                                                       nobody is watching
```

**Rules**

1. One sink per camera, handed out, never owned by a view.
2. Demand is counted, not set. Two windows watching camera 6 is one decode and
   two tickets; closing one window must not blank the other.
3. A sink is cleared when its camera's source goes away — a stale last frame
   under the words "not on the network" is a lie the desk tells about itself.
4. Programme and preview are *monitors*, not cameras: they show the mix and what
   is next, at the monitor's lens. A tile showing camera 6 shows camera 6 — never
   the programme monitor's picture, which during a dissolve is two cameras at
   once and at a lens the tile did not choose.
5. Grading is per camera and applies to every picture of that camera. Bypass is a
   view's question about *display*; it never changes what is decoded.

---

## 5. MIX — what goes to air

**Owns:** programme, preview, the transition, the four output lanes.

**Rules**

1. Programme and preview are one state with one setter. Assigning the slot
   directly draws the change without performing it.
2. **The tick never depends on the programme bus having a picture.** It used to
   return early when programme was empty, which took the preview monitor, the
   multiview and the colour pictures down with it — everything went black
   because one thing was missing.
3. One clock drives a dissolve, and the switcher follows it. Two clocks drift.
4. The T-bar's handle position and the mix are different numbers. The handle is
   never moved by the machine while a hand is on it.
5. Colour is applied per camera *before* the dissolve, never after — grading the
   composite smears one camera's correction across the other for the length of
   every transition.

---

## 6. UI — renders, decides nothing

**Rules**

1. A window reads the core and draws. It holds no video state of its own.
2. Anything a window wants is a request to the core: `subscribe`, `selectPreview`,
   `takeToAir`, `setLens`. Never a direct assignment to a published fact.
3. The same core drives every window. The multiview, the colour panel, the
   monitors and the output window are four *designs* of one truth — that is the
   whole point of the split, and the reason the same camera cannot be live in one
   window and black in another.
4. A window may be closed at any moment. Closing it releases its tickets and
   nothing else.

---

## Working on this

**Each part has its own rules and its own way back.**

- Change one part at a time. A change that needs two parts is a change to the
  boundary between them, and that is a design change, not a patch.
- Every rule above came from a real failure. Deleting a rule requires knowing
  which failure it prevented.
- Before touching a part, tag what works: `git tag good/decode/2026-08-18`. The
  way back from a broken part is `git restore --source=good/decode/... -- <path>`
  — one part, not the whole tree.
- A rule that can be tested is tested. Decode policy in particular is a pure
  function — given the fleet and the streams, what should be decoded — and it is
  where the evening's worst bugs lived.
