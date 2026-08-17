# Čo kamera vie

Kompletná inventúra protokolu `proto/CamAPI.proto`, roztriedená podľa toho, či je
bezpečné príkaz poslať.

Referenčný nástroj od človeka z Orahu používa **päť príkazov z pätnástich**. Zvyšok
existuje a je zdokumentovaný, ale nie je ním preverený.

---

## 1. Overená cesta — čo používa referenčný nástroj

Toto je jediná postupnosť, o ktorej vieme, že je odskúšaná z výroby:

```
getFile(factoryPresetsProject.ptv)  →  getFile(rigParameters.json)
       →  START(url)  →  AUDIO_SYNC
```

| Príkaz | Čo robí |
|---|---|
| `Fs.GET` | stiahne súbor z kamery |
| `Video.START` | spustí streamovanie na zadanú RTMP adresu |
| `Cam.AUDIO_SYNC` | zvukové klapky na zarovnanie streamov v postprodukcii |
| `Cam.GET_CAMERA_MODE` | v kóde je, ale nevolá sa |
| `Cam.GET_CAMERA_INFO` | **zámerne zakomentované** — ale funguje, viď nižšie |

To zakomentovanie stojí za pozornosť. Autor ho nahradil stiahnutím súboru — vyzerá
to ako obídenie niečoho, čo mu nefungovalo. Identitu kamery preto berieme z mena
Bonjour služby (`Atlas360@AQ1720000102`), kde sériové číslo aj tak je, a pri štarte
streamu tento príkaz neposielame.

**Overené 2026-08-16: `GET_CAMERA_INFO` na zdravej kamere odpovie normálne.**

```
Model:      Atlas360        Serial:     AQ1702006522
Hardware:   01A             Firmware:   1.50.23
Sensors:    4               SoCs:       2
```

Je to jediné miesto, kde sa dá zistiť **verzia firmvéru**, a je čisto čítacie —
správa nenesie žiadne polia na zápis. Používa ho `orahctl checkout`. Do štartovacej
sekvencie sa napriek tomu nepridáva: tá je 1:1 s referenciou a nie je dôvod ju
meniť, keď sa dá verzia prečítať pri kontrole kamery.

---

## 2. Bezpečné na čítanie — nemenia nič

Overené ako bezpečné z textu protokolu. Implementované, testované na bajty
(`orahctl selftest`), spustiteľné cez `orahctl inspect`.

| Príkaz | Čo vráti | Prečo je to bezpečné |
|---|---|---|
| `Video.GET_STREAM_URL` | zoznam adries, kam kamera práve streamuje | dotaz bez vstupu |
| `Cam.AUDIO_GAIN` *(prázdny)* | zosilnenie na každý kanál v dB | *„current value returned if input is not set"* |
| `Cam.CAMERA_TIME` *(prázdny)* | hodiny kamery ako UNIX čas | to isté pravidlo |
| `Cam.GET_CAMERA_MODE` | `IDLE` / `LIVE` / `USB` / `FW_UPGRADE` | dotaz bez vstupu |
| `Fs.GET` | adresa súboru, alebo `FILE_NOT_FOUND` | čítanie; neexistujúci súbor nič nepokazí |

**Kľúčová vlastnosť dvoch z nich:** `AUDIO_GAIN` a `CAMERA_TIME` sú zápisové príkazy,
ktoré sa **stanú čítaním, keď sa pošlú prázdne**. Preto je v testoch overené na bajt
presne, že naša správa žiadne hodnoty nenesie:

```
getAudioGain    8a01020814      ← len op, žiadne gain_db
getCameraTime   8a01020809      ← len op, žiadny time
```

Keby tam hodnoty boli, prepísali by sa nastavenia kamery.

### `GET_STREAM_URL` rieši reálny problém

Kamera si po výpadku prúdu **sama obnoví streamovanie** (viď MEASUREMENTS M2). Tento
príkaz je jediný spôsob, ako sa jej spýtať *kam* streamuje, bez toho, aby sme ju
zastavovali a spúšťali nanovo.

### `CAMERA_TIME` je použiteľný na synchronizáciu

Vieme prečítať hodiny každej kamery a porovnať ich s Macom. Pri 24 kamerách to dá
obraz o tom, ako sa ich hodiny rozchádzajú — čo je presne otázka z §6 špecifikácie.

---

## 3. Užitočné, ale menia stav — až po rozhodnutí

| Príkaz | Čo robí | Riziko |
|---|---|---|
| `Video.STOP` | zastaví streamovanie | **nízke** — otestované, kamera prejde do `IDLE` |
| `Cam.SET_CAMERA_NAME` | premenuje kameru, mení sa aj Bonjour meno | stredné — rozbije väzbu slotu na meno |
| `Cam.AUDIO_GAIN` *(s hodnotami)* | nastaví zosilnenie, rozsah −12 až +20 dB | stredné — vratné, ale treba poznať pôvodné |
| `Cam.CAMERA_TIME` *(s hodnotou)* | prestaví hodiny kamery | stredné |
| `Cam.RESTART` | reštart | nízke, ale zbytočné |
| `Fs.PUT` | **nahrá súbor do kamery** | vysoké — netušíme, čo sa dá prepísať |

`Video.STOP` je jediný z tejto skupiny, ktorý používame. Bez neho sa kamera nedá
zastaviť inak než odpojením napájania, čo pri 24 kusoch nie je cesta.

---

## 4. Nikdy neposielať

| Príkaz | Prečo |
|---|---|
| `Cam.FW_UP` | nahrá a nainštaluje firmvér zo zadanej adresy — viď nižšie |
| `Cam.FW_RESET` | **reset na továrenské nastavenia** — stratí sa kalibrácia |
| `Cam.SHUTDOWN` | vypne kameru; späť sa dostaneš len fyzicky |
| `Cam.SET_USER_INFO` | mení autorizačné údaje klienta — riziko zamknutia prístupu |
| `TestMode` | prinúti kameru odpovedať falošnými stavmi |

`FW_RESET` je najhoršia: kalibrácia je to, čo robí zo štyroch obrazov jeden 360°
obraz, a `factoryPresetsProject.ptv` je jediná kópia, ktorú by sme mali.

**Preto sa kalibračné súbory sťahujú pri každom štarte** a odkladajú podľa sériového
čísla — aby existovali aj mimo kamery.

### Ako by prebehla aktualizácia firmvéru — a prečo ju nerobíme

Protokol to vie. `Cam.FW_UP` berie tri polia:

| pole | |
|---|---|
| `fw_url` | adresa, z ktorej si kamera obraz stiahne sama (HTTP) |
| `checksum_type` | `SKIP_CHECK`, `MD5SUM` alebo `SHA1SUM` |
| `checksum` | očakávaná hodnota |

Priebeh sa dá sledovať: kamera prejde do režimu `FW_UPGRADE` (`GET_CAMERA_MODE`)
a pošle jednu z udalostí `FW_UPGRADED`, `FW_BROKEN_LINK` alebo
`FW_CHECKSUM_MISMATCH`. Obraz teda stačí položiť na ľubovoľný HTTP server v sieti
a poslať naň odkaz s kontrolným súčtom.

**Neposielame to a zatiaľ ani nemáme čo.** Orah skončil, oficiálny zdroj obrazov
neexistuje a nemáme overený obraz ani cestu späť. Aktualizácia firmvéru bez
možnosti vrátiť predchádzajúcu verziu je jediný príkaz v tomto protokole, ktorý
vie kameru nenávratne položiť.

Čo sa dá spraviť teraz a má zmysel: **zaznamenať verziu na každom kuse**
(`orahctl checkout`, stĺpec vo `FLEET.md`). Keď sa ukáže, že kamery nemajú
rovnaký firmvér, je to informácia pred akciou — a ak by sa niekedy obraz našiel,
bude jasné, ktoré kusy sa líšia.

### `TestMode` — zaujímavý, ale nedotknutý

Protokol má vstavané testovacie rozhranie: donúti kamere vracať zvolený chybový stav
na všetky príkazy, alebo poslať vybranú udalosť. Na testovanie ošetrenia chýb bez
čakania na skutočnú poruchu je to výborné.

Nepoužívame ho, lebo mení stav kamery a nie je zrejmé, ako sa vracia späť. Ak sa
niekedy ukáže potrebným, testovať sa má na kamere, ktorá práve nie je nasadená.

---

## 5. Čo protokol vôbec neponúka

**Žiadne parametre streamu.** Správa `Video` má len `op` a `url`.

Rozlíšenie (1920×1440), snímková frekvencia (30) ani bitrate (~15 Mbit/s na šošovku)
sa **cez toto rozhranie nastaviť nedajú**. Ak sa dajú vôbec, tak inde — cez webové
rozhranie kamery alebo nahratím súboru cez `Fs.PUT`, čo je zatiaľ nepreskúmané
a rizikové.

---

## 5A. Zvuk — z oficiálneho manuálu

Zdroj: Orah 4i User Guide v1.2.0 (VideoStitch, 2017), sekcie *Audio sources*
a *Ambisonic audio*.

| Vec | Hodnota |
|---|---|
| Formát | **AmbiX**, prvý rád, 4 kanály |
| Poradie kanálov | **ACN** — teda W, Y, Z, X |
| Normalizácia | **SN3D** |
| Zosilnenie vo web rozhraní | −12 až +67,5 |
| Zosilnenie v protokole `AUDIO_GAIN` | −12 až +20 |

Tie dva rozsahy zosilnenia sú **rôzne stupne** — protokol ovláda iný než webové
rozhranie. Namerané kamery hlásia +20, čo je maximum protokolového rozsahu.

**Natočenie a stabilizácia obrazu sa na zvukové pole neaplikujú.** Zvuk zostáva
v sústave kamery.

Stitchovací box mal aj **posúvač oneskorenia zvuku −1 s až +1 s** na dorovnanie voči
obrazu — rovnaká potreba, akú riešime vo výstupnom delayi (§8A.4 špecifikácie).

Box tiež poskytoval **HLS náhľad** na `http://{box-ip}/hls/preview/index.m3u8`.

## 6. Ešte nezistené

- **Čo je vnútri kalibračných súborov** — stiahnu sa cez `orahctl inspect`, obsah
  zatiaľ nemáme
- **Aké ďalšie súbory kamera pozná** — `inspect` skúša zoznam pravdepodobných mien
- **Čo beží na webovom serveri kamery** — `fs_reply` vracia HTTP adresu, takže tam
  nejaký je
- **Či kamera echoval `cookie`** z `Api` — ak áno, dajú sa odpovede párovať spoľahlivo
  namiesto párovania podľa typu správy

---

## Ako to spustiť

```
orahctl inspect 192.168.0.128
```

Prejde všetko zo sekcie 2 a vypíše, čo kamera vie. **Nepošle jediný zápisový príkaz.**
Kvôli povinnému časovaniu (sekunda medzi príkazmi) to trvá asi pol minúty.
