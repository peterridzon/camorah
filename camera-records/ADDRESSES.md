# Fixed addresses

The cameras cannot be given a static address — their protocol has no
network commands at all. These are **DHCP reservations**: bind each MAC
to an address on the router and the camera lands there every time,
without anything changing inside it.

Two per camera. Each one is two SoCs on consecutive addresses, and the
control port lives on the lower of the pair.

| # | Serial | Reserve | For MAC | Role |
|---|---|---|---|---|
| 3 | `AQ1610012312` | `.101` | `48:65:ee:90:1:30` | control + video |
| 3 | `AQ1610012312` | `.102` | `48:65:ee:90:1:31` | video only |

## Then the roster stops guessing

With reservations in place the app does not need discovery at all: the
roster carries the address, and a camera that does not answer at its own
address is missing rather than merely unannounced. That is a much more
useful thing to be told during a rig.
