# Kusy, ktoré sa na sieť nedostali

`FLEET.md` sa generuje zo záznamov, a záznam vznikne až vtedy, keď sa kamera
ohlási. Kusy, ktoré sa neohlásili nikdy, by v ňom teda chýbali úplne — a to je
presne ten druh diery, po ktorej sa o pol roka počíta zle. Preto sú tu.

Zapísané ručne 2026-08-17, po testovaní celého skladu po trojiciach.

| # | sériové | čo o nej vieme |
|---|---|---|
| 01 | neznáme | nikdy sa neobjavila na sieti. Sériové číslo sa nedá prečítať, lebo to je jediné miesto, odkiaľ ho berieme — z jej vlastného ohlásenia. |
| 25 | neznáme | to isté. Skúšaná opakovane, aj s výmenou kábla a portu. Operátor ju už predtým vyradil ako hardvérovo zlú. |

Obidve majú svietiace LED, čiže napájanie aj fyzický link stoja. Zlyháva až to,
čo je nad tým — adresu si nevypýtajú a na `9989` neodpovedajú, takže ich
nevidí ani Bonjour, ani ARP sweep po OUI.

**Sériové čísla treba odpísať z nálepky na kuse**, inak sa k nim žiadny záznam
nedá priradiť.

---

## Celková inventúra

Osemnásť kusov:

| stav | # | počet |
|---|---|---|
| stream 4/4 dokázaný | 2, 3, 4, 5, 6, 7, 9, 10, 12, 20, 21, 22, 24 | **13** |
| jeden SoC z dvoch | 8 | 1 |
| na sieti, video nenabehne | 11 | 1 |
| stráca link po minúte | 23 | 1 |
| na sieť sa nedostane vôbec | 1, 25 | 2 |

Trinásť použiteľných. Podrobnosti ku každému kusu sú v [FLEET.md](FLEET.md),
výklad chybových stavov v [../docs/MEASUREMENTS.md](../docs/MEASUREMENTS.md).
