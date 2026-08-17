# Firmvér — čo máme a čo sa s tým dá

Orah skončil, `s3.video-stitch.com` aj `vdstt.ch` sú mŕtve. Toto je jediná kópia,
ktorá existuje, a je kompletná — vrátane zrkadiel tých stránok.

Archív je odložený offline. Do repozitára nepatrí a nie je v ňom.

---

## Čo v archíve je

Archív **nie je v tomto repozitári a nikdy v ňom nebude** — má okolo 3,8 GB a
GitHub nie je miesto na zálohu. Je odložený u operátora offline. Ak ho niekto
potrebuje, nech napíše.

Súbory, ktoré v ňom sú:

    Orah_v1.1.0.fw + .sign
    Orah_v1.1.1.fw + .sign
    Orah_1_1_2.fw  + .sign
    Orah_1.2.0.fw  + .sign
    Orah_1.2.0.fw.iso        (variant _C)
    orah4i_1.2.0.zip
    ORAH 4i/Manuals/         Orah-User-Guide-1.2.0.pdf a ďalšie
    ORAH 4i/HACK Pics/       fotografie rozobratej kamery, tri série

**1.2.0 je posledná verzia, ktorá kedy vyšla.** Manuál k nej uvádza firmvér
kamery `01A/1.50.23` — presne to, čo hlási celý náš fleet. Nie je čo doháňať.

---

## Obrazy sa nedajú rozbaliť

Zmerané: entropia **8,00 bitov na bajt** cez všetky štyri verzie. To znamená
šifrované alebo už komprimované dáta, bez rozpoznateľnej hlavičky. Žiadny ISO
podpis na 32 KB, žiadne `gzip`, `xz`, `squashfs`.

Podpis je 64 bajtov vedľa každého obrazu — box si ho pred inštaláciou overuje.

**Dôsledok:** firmvér kamery sa z obrazu vytiahnuť nedá. A keďže box overuje
podpis, nedá sa ani podstrčiť vlastný obraz.

---

## Ako sa teda kamera flashuje

Z manuálu, kapitola *Updating the Orah 4i camera*:

> Any given version of the Stitching Box embeds an approved and validated Camera
> firmware. Each time the Orah 4i camera is connected to a stitching box, the
> stitching box will check the camera's firmware version.

Firmvér kamery je teda **zabalený vnútri obrazu boxu** a box ho kamere nahrá sám,
tlačidlom *UPGRADE CAMERA* vo webovom rozhraní. Sú dva prípady:

| hláška | čo sa stalo |
|---|---|
| *Outdated camera firmware version* | kamera funguje, len je staršia |
| *Incompatible camera firmware version* | kameru nemožno použiť, kým sa nepreflashuje |

**Stitching box je teda jediný nástroj, ktorý vie kameru preflashovať.** Náš
protokol síce `Cam.FW_UP` má, ale očakáva obraz firmvéru kamery — a ten máme len
zapečený vnútri obrazu boxu, ku ktorému sa nedostaneme.

### Postup pre box

USB kľúč vo formáte FAT32, aspoň 1 GB. Na koreň skopírovať `.fw` aj `.sign`,
nič iné z Orahu. Box vypnutý, kamera odpojená, webová aplikácia zavretá. Kľúč do
USB 2.0 portu, box zapnúť — aktualizuje sa sám, trvá to dve až tri minúty a na
konci pípne. Po úspechu sa súbor na kľúči premenuje na `..._done.fw`.

Potom kameru pripojiť a box ju ponúkne preflashovať.

---

## Čo z toho platí pre nás

**Aktualizovať netreba.** Fleet je na poslednej verzii, ktorá kedy vyšla.

**Archív treba zálohovať.** Je nenahraditeľný a je na jednom notebooku v
`~/Downloads`. Keby o neho niekto prišiel, nedá sa už stiahnuť odnikiaľ.

**Na oživenie zaseknutej kamery firmvér nepotrebujeme** — a ani by nepomohol,
lebo `FW_UP` chodí po tom istom WebSockete, ktorý taká kamera odmieta. Pomáha
odpojenie od napájania, a keď ani to nie, tak stitching box.

**Kamerám bez kalibrácie firmvér nepomôže.** Kalibrácia nie je jeho súčasť, je
to meranie konkrétneho kusa — viď [CALIBRATION.md](CALIBRATION.md).

---

## Ešte v archíve

Fotografie rozobratej kamery sú jediná dokumentácia vnútra, aká existuje — ak
sa bude niektorý kus otvárať, sú v archíve. Väčšina toho, čo je na tejto stránke
napísané, pochádza z `Orah-User-Guide-1.2.0.pdf`.
