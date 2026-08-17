# Merania

Namerané hodnoty, o ktoré sa opiera špecifikácia. Každý záznam hovorí, čím sa meralo
a za akých podmienok — aby sa dalo zopakovať a aby bolo jasné, čo ešte overené nie je.

---

## M1 · FFmpeg streamcopy rúra

**Dátum:** 2026-08-15 · **Stav:** overené, bez kamier (simulátor)

Overuje predpoklad zo špecifikácie 5.4: že FFmpeg vie slúžiť ako tenká redukcia
protokolu — RTMP dnu, RTMP von, len prebalenie kontajnera — za zanedbateľnú cenu.

**Zostava**

```
sim-camera.sh ──► MediaMTX ──► ffmpeg -c copy ──► mpegts rúra ──► ffmpeg -c copy ──► MediaMTX
```

Zdroj: 1920×1080, 30 fps, H.264 (`h264_videotoolbox`), GOP 30, 8 Mbit/s, + AAC mono.
Meria sa `tools/pipe-bench.py`, párovaním časových značiek medzi zdrojom a výstupom.

**Výsledok**

| | |
|---|---|
| Pridaná latencia, medián | **100,3 ms** |
| 5. až 95. percentil | 96,1 – 104,6 ms |
| CPU, obe nohy spolu | **0,7 % priemer, 1,0 % špička** |
| Snímková frekvencia | 30,0 fps na oboch stranách |

**Záver:** predpoklad platí. Rúra je z hľadiska CPU zadarmo a 100 ms je v rozpočte.
Číslo zahŕňa aj spiatočnú cestu cez MediaMTX, takže samotné dve nohy stoja menej.

### Dva nálezy, ktoré platia aj pre ostrú implementáciu

**1. `mpegts` muxer posúva časové značky o 1,2 s.** Predvolené `muxdelay` (0,7 s)
a `muxpreload` (0,5 s) sa sčítajú. Dáta sa nezdržia, posunú sa len *značky* — ale
čokoľvek, čo im ďalej v reťazi verí, dostane nesprávny čas. **V rúre preto musí byť
`-muxdelay 0 -muxpreload 0`.**

Prejavilo sa to tak, že meranie hlásilo latenciu −1270 ms, teda že výstup prišiel skôr
než zdroj. Párovali sa snímky vzdialené 1,2 s.

**2. Meranie cez `ffprobe` treba čítať cez pseudoterminál.** Do bežnej rúry si ffprobe
bufferuje výstup po 4 KB — pri desiatich bajtoch na riadok je to stovky snímok, teda
sekundy. Časová značka prečítania potom meria buffer, nie stream.

### Čo tým overené nie je

- Správanie pri **výpadku a obnove** streamu
- Rúra so **skutočným streamom z kamery** (iné GOP, iný profil, ambisonický zvuk)
- Latencia pri **záťaži viacerých súčasných rúr**

---

## M2 · Skutočná kamera Atlas360

**Dátum:** 2026-08-15 · **Stav:** overené na hardvéri

Prvý kontakt so skutočnou kamerou. Discovery, protokol aj štart streamovania fungujú.

### Identita

| | |
|---|---|
| Model | Atlas360 |
| Sériové číslo | AQ1720000102 |
| Firmvér | 1.50.23, hardvér 01A |
| Snímače / SoC | **4 / 2** |
| Bonjour | `Atlas360@AQ1720000102`, `_vscamera._tcp` |

Sériové číslo je **v mene Bonjour služby**, takže slot kamery sa dá určiť ešte pred
pripojením.

### Kamera má dve IP adresy

**Každý SoC má vlastnú adresu.** Riadenie beží len na prvej.

| Stream | Publikuje | Zvuk |
|---|---|---|
| `0_0` | .128 (SoC 1, aj riadenie) | LPCM |
| `0_1` | .128 | — |
| `1_0` | .129 (SoC 2) | LPCM |
| `1_1` | .129 | — |

Port 9989 je otvorený len na prvej adrese. **Riadiaci port je 9989, nie 80**, ako
predpokladal pôvodný kód.

### Formát

| | |
|---|---|
| Video | H.264 **Main**, level 5.0, **1920×1440**, 30 fps, yuv420p |
| Zvuk | **LPCM `pcm_s16le`, 44,1 kHz, 2 kanály** — len na `0_0` a `1_0` |
| Tok | **~15 Mbit/s na stream** |

**Rozlíšenie je 1920×1440, nie 1080p** — o tretinu viac pixelov, než sa odhadovalo.

**Zvuk: 2 SoC × 2 kanály = 4 kanály.** To je ten ambisonic — nie po jednom kanáli na
štyroch streamoch, ako predpokladala špecifikácia, ale **dve stereo dvojice na prvom
streame každého SoC**.

**Tok na kameru: ~60 Mbit/s.** Pri 24 kamerách **~1,4 Gbit/s**, čo potvrdzuje
rozhodnutie z §3.1 posielať kamery na vlastné nody a nie na Mac.

### Cesty sedia

Kamera dostala `rtmp://mac:1935/cam01/` a publikovala na `cam01/0_0` až `cam01/1_1`.
**Kľúčová oprava zo špecifikácie §4.1 je potvrdená na hardvéri.**

### Tri veci, ktoré položia nasadenie, ak sa nevedia

**1. SoC 1 potrebuje na publikovanie viac než 10 sekúnd.** Otvorí RTMP spojenie
a chvíľu mlčí. Predvolený `readTimeout` MediaMTX je 10 s, takže ho **ticho zahodí
a prídeš o polovicu kamery** — druhý SoC pritom streamuje normálne, takže to vyzerá,
že všetko beží. Treba `readTimeout: 30s`.

**2. Kamera sa musí ovládať pomaly.** Referenčný nástroj od človeka z Orahu
(`wsock.py`) čaká **5 sekúnd po otvorení spojenia** a **1 sekundu medzi príkazmi**.
Nie je to štýl. Riadenie bez týchto pauz — a súčasne otvorené druhé riadiace
spojenie — kameru **zaseklo**: prestala odpovedať na riadiacom sokete aj sa ohlasovať
cez Bonjour, zatiaľ čo druhý SoC ďalej streamoval. Pomohol až reštart napájania.

**3. Naraz len jedno riadiace spojenie.** Druhé pripojenie počas aktívneho prvého
neodpovedá.

### Protokol nemá parametre streamu

Správa `Video` má len `op` a `url`. **Rozlíšenie, bitrate ani snímková frekvencia sa
cez toto rozhranie nastaviť nedajú.** Nastaviteľné je: `AUDIO_GAIN` (pole hodnôt
v dB), `CAMERA_TIME` (UNIX čas — použiteľné na spoločnú časovú základňu),
`SET_CAMERA_NAME`, `RESTART`, `SHUTDOWN` a `Fs.PUT` na nahranie súboru.

Pôvodný nástroj **žiadny STOP neposiela** — príkaz `Video.STOP` v protokole existuje,
ale referenčná implementácia ho nepoužíva.

### `Video.STOP` funguje — po oprave časovania

Overené po reštarte napájania, s jedným spojením a novým časovaním:

```
STOP acknowledged
camera mode is now idle
```

Všetky štyri cesty zmizli zo servera. Prvý pokus zlyhal **nie preto, že by príkaz
nefungoval**, ale preto, že kamera bola dovtedy zaseknutá.

### Kamera si obnoví streamovanie sama

Po odpojení a zapojení napájania **nabehla rovno do stavu `live`** a bez akéhokoľvek
príkazu začala publikovať na tú istú RTMP adresu ako predtým. Cieľ aj stav si pamätá
cez reštart.

Prevádzkovo to znamená dve veci: kamera po výpadku prúdu nabehne sama, ale zároveň
**začne streamovať aj vtedy, keď to nikto nečaká** — aplikácia s tým musí rátať pri
štarte a stav si zistiť, nie predpokladať.

S `readTimeout: 30s` prešli po reštarte **všetky štyri streamy** vrátane oboch
z `.128`, ktoré predtým vypadávali.

---

## M3 · Prieskum kamery (len čítanie)

**Dátum:** 2026-08-15 · **Kamera:** Atlas360 `AQ1718000039` (192.168.0.159)
**Stav:** overené · žiadny zápisový príkaz nebol odoslaný

Spustené cez `orahctl inspect`. Zistenia sú z príkazov, ktoré nič nemenia.

### Kamera si pamätá starý cieľ streamovania

`GET_STREAM_URL` vrátil adresy z **úplne inej siete**:

```
rtmp://10.41.0.1:1935/cam02/0_0 … /1_1
```

Kamera si teda drží poslednú nastavenú adresu naprieč sieťami aj reštartmi — vrátane
mena aplikácie (`cam02`). Spolu s tým, že po zapnutí sama začne streamovať (M2), to
znamená: **kamera môže po pripojení začať posielať dáta niekam, kde ich nikto nečaká.**

`GET_STREAM_URL` je jediný spôsob, ako sa jej na to spýtať bez zásahu.

### Zvuk má štyri kanály

`AUDIO_GAIN` (čítanie) vrátil **štyri hodnoty**: `20.0, 20.0, 20.0, 20.0 dB`.

Definitívne potvrdenie ambisonicu: štyri mikrofóny, štyri kanály, po dvoch na SoC
(viď M2). Všetky sú na **hornej hranici** rozsahu −12 až +20 dB.

### Kamera nemá hodiny

`CAMERA_TIME` vrátil `1970-01-01 00:01:50` — teda 110 sekúnd od štartu.

**Kamery nemajú reálny čas a začínajú od nuly pri každom zapnutí.** Ich časové značky
sa preto nedajú použiť ako spoločná referencia medzi kamerami. Potvrdzuje to
rozhodnutie z §6.2 merať posun podľa času príchodu, nie podľa značiek.

`CAMERA_TIME` sa dá aj nastaviť, takže spoločná časová základňa je dosiahnuteľná —
ale je to zápis a zatiaľ sme sa ho nedotkli.

### Súbory sa medzi kusmi líšia

| Súbor | `AQ1718000039` |
|---|---|
| `factoryPresetsProject.ptv` | **je** |
| `rigParameters.json` | **nie je** |

Referenčný nástroj sťahuje oba bezpodmienečne — na tomto kuse by mu druhý zlyhal.
Naša implementácia to znáša (chyby sa logujú, nie sú fatálne).

Kamera má **HTTP server na tom istom porte 9989**, súbory sú pod `/calib/`.

### Čo je v kalibračnom súbore

`factoryPresetsProject.ptv` je **projekt VideoStitch vo formáte JSON** — presne to,
čím sa riadi stitching.

**Výstup:** 4096×2048, equirektangulárna projekcia, hfov 360, `spherescale` 1,75,
merger `gradient` s feather 50.

**Štyri vstupy s geometriou na šošovku:**

| Šošovka | `reader_config` | Yaw | Pitch | Roll | Focal |
|---|---|---|---|---|---|
| 0 | `0_0.mp4` | 0,00° | −18,00° | −90,00° | 1059,18 |
| 1 | `0_1.mp4` | 179,88° | −17,85° | −89,72° | 1058,09 |
| 2 | `1_0.mp4` | −89,87° | +17,94° | +90,33° | 1052,32 |
| 3 | `1_1.mp4` | 90,00° | +18,01° | +90,19° | 1057,67 |

Plus orezanie kruhového obrazu a koeficienty skreslenia šošovky na každý vstup.

**Názvy streamov zodpovedajú poradiu vstupov v kalibrácii** — `0_0` je vstup 0 atď.

`audio_enabled` je na všetkých štyroch vstupoch `false`; zvuk sa v tomto súbore
nerieši.

### Kalibrácia je na kus — a to má dôsledok pre prepínanie

Hodnoty ako `179,88°`, `−17,85°` či `+90,33°` nie sú ideálne, ale **namerané pri
výrobe toho konkrétneho kusu**.

**Ak Vahana zošíva kamerou A a prepneme na kameru B, zošije ju kalibráciou A.** Švíky
sa rozídu — a práve pri prechode, kde je stitching najcitlivejší.

Možnosti:
1. Vahana prepne kalibráciu súčasne so zdrojom (treba zistiť, či a ako rýchlo)
2. Kamery sa prekalibrujú na spoločnú sadu
3. Odchýlka medzi kusmi je dosť malá, aby sa dala zniesť

**Zmerať:** porovnať kalibračné súbory oboch kamier a zistiť veľkosť odchýlky. Bez
toho sa nedá rozhodnúť, ktorá z troch možností platí.

---

## M4 · Porovnanie kalibrácií dvoch kusov

**Dátum:** 2026-08-15 · **Kamery:** #2 `AQ1718000039`, #9 `AQ1723000245`
**Stav:** overené · obe kalibrácie sú v `docs/`

Odpovedá na otázku otvorenú v §5.3.2: **ako veľmi sa líšia kalibrácie medzi kusmi
a či sa dá prepínať kamery bez výmeny kalibrácie.**

Panoráma je na oboch rovnaká: 4096×2048, `spherescale` 1,75. Pri šírke 4096 px
zodpovedá **1° uhla 11,4 pixelom** na rovníku panorámy.

| Šošovka | Najväčšia uhlová odchýlka | Posun na švíku | Rozdiel orezu |
|---|---|---|---|
| 0 | **0,00°** (identická) | 0 px | 47 px |
| 1 | 0,33° (pitch) | 3,8 px | 27 px |
| 2 | **0,56°** (pitch) | 6,4 px | 16 px |
| 3 | 0,22° (yaw) | 2,5 px | 24 px |

Ohniská sa líšia o 1 až 4 jednotky z ~1055, teda o 0,1–0,35 %.

### Šošovka 0 je referenčná

Na oboch kusoch má presne `yaw 0,00 / pitch −18,00 / roll −90,00`. Kalibrácia
z výroby zjavne drží nultú šošovku na nominálnych hodnotách a zvyšné tri meria
voči nej.

### Záver: nie je to blokujúci problém

**Najhorší prípad je ~6 px posunu** na 4096 px širokej panoráme, ak sa kamera zošíva
cudzou kalibráciou. To je mierne mäkký švík, nie roztrhnutý obraz.

**Väčšie riziko je orez**, ktorý sa líši až o 47 vstupných pixelov. Určuje hranicu
použiteľnej časti rybieho oka, takže cudzí orez môže zatiahnuť do obrazu okraj
šošovky alebo odrezať prekryv potrebný na zošitie.

**Odporúčanie:**

1. Ak Vahana vie prepnúť kalibráciu so zdrojom, spraviť to
2. Ak nie, ísť s jednou kalibráciou — ale **orez nastaviť na prienik** hodnôt zo
   všetkých kamier, nie prevziať ho z jednej. Prienik nikdy nezatiahne okraj šošovky.

Tým prestáva byť kalibrácia prekážkou pre vlastný prepínač.

---

## M5 · Kamery zlyhávajú na enkódovaní, keď sú pripojené tri

**Dátum:** 2026-08-15 · **Stav:** pozorovanie, príčina nepotvrdená

### Čo bolo pozorované

S **jednou** kamerou na PoE streamovanie bežalo minúty bez problému (M2).

Po pripojení **troch** kamier:

```
20:05:43  streaming to rtmp://.../cam02/
20:06:11  event: videoFail            ← kamera sama hlási zlyhanie enkódovania
20:06:13  RTMP spojenia sa zatvárajú
```

a neskôr už ani to:

```
20:32:11  štyri RTMP spojenia sa otvoria (oba SoC)
20:32:23  zatvárajú sa, bez toho aby čokoľvek poslali
```

**Kamera otvorí spojenia, ale nikdy nezačne publikovať.** Riadenie prestane odpovedať,
kamera ale zostáva na sieti a odpovedá na ping. `STOP` prejde alebo vyprší podľa stavu.

### Hypotéza — a jej vyvrátenie

Prvá domnienka bola **napájanie**: tri kamery na jednom PoE. Test s dvomi kamerami,
každá na **vlastnom PoE**, to ale nepotvrdil — zlyhali rovnako.

### Skutočná príčina: opakované pripájanie a odpájanie riadenia

Vzorec sa zopakoval na **štyroch rôznych kamerách**: najprv fungujú, po čase prestanú
prijímať riadenie, hoci sa stále hlásia cez Bonjour a odpovedajú na ping. Pomôže len
reštart napájania.

Spoločný menovateľ nie je hardvér, ale **spôsob, akým sme k nim pristupovali**:

| Referenčný nástroj | Naše CLI |
|---|---|
| otvorí **jedno** spojenie a drží ho navždy (`while True: sleep(5)`) | každý príkaz otvorí nové a zavrie ho |
| nikdy neposiela WebSocket `close` | `probe`, `inspect`, `checkout`, `stream`, `stop` — cyklus zakaždým |

Za jeden deň to boli desiatky cyklov pripoj–odpoj na kameru. Ak firmvér pri zatvorení
relácie neuvoľní jej slot, po niekoľkých cykloch mu dôjdu a prestane prijímať nové
spojenia — presne to pozorované správanie.

**Vysvetľuje to aj nekonečnú slučku v referenčnom nástroji.** Nemusela vzniknúť
z pohodlnosti, ale preto, že inak sa kamera ovládať nedá.

### Pravidlo, ktoré z toho platí pre aplikáciu

> Aplikácia otvorí na každú kameru **jedno riadiace spojenie a drží ho po celý čas
> behu**. Nikdy sa neodpája a nepripája znovu — iba ak spojenie samo spadne.

Nástroje príkazového riadka sú postavené opačne (každý príkaz je samostatný proces)
a treba ich prerobiť na zdieľanú reláciu, inak nie sú použiteľné na ladenie
skutočného hardvéru.

**Zostáva overiť:** po reštarte napájania pripojiť **raz** a spraviť všetko cez jednu
reláciu. Ak kamera vydrží, hypotéza je potvrdená.

### `VIDEO_FAIL` je očakávaný stav, nie výnimka

Referenčný nástroj naň reaguje návratom `'retry'` a zopakuje štart. **Autor s tým
počítal.** Naša implementácia to zatiaľ nerobí — doplniť (úloha #16).

To zároveň znamená, že `VIDEO_FAIL` nemá byť v aplikácii chybou, ale stavom, ktorý sa
rieši opakovaním — a až po niekoľkých neúspechoch sa má operátorovi ohlásiť ako
**pravdepodobný problém s napájaním**, nie ako všeobecná chyba.

---

## M6 · Prepínač — štyri dráhy naraz

**Dátum:** 2026-08-15 · **Stav:** overené proti simulátoru · Apple M1 Pro

Kompletná cesta: príjem RTMP → hardvérový dekód → Metal prelínačka → hardvérový
enkód → RTMP von, štyri dráhy riadené jedným časovačom a jedným mixom.

### Výsledok

| | |
|---|---|
| Čas na tik, celkovo | **1,8 ms** |
| z toho prelínačka (4 dráhy) | 1,7 ms |
| z toho enkód (4 dráhy, súbežne) | 3,4 ms súčet, ~1 ms reálne |
| Oneskorené tiky | **2 z 505** |
| Výstupná frekvencia | **30 fps** |

Pri 33 ms na snímku je to asi **18× rezerva**. Prelínačka aj T-páčka fungujú
synchronne na všetkých štyroch dráhach, program a preview sa po prechode vymenia.

### Poučenie: merací prípravok si žral to, čo meral

Prvé merania hlásili 60 ms na tik a 7 fps. Hľadanie príčiny prešlo cez zápis do
rúry, tvrdý strop dátového toku, ladiaci build aj tempo enkodéra — **všetko slepé
uličky**.

Skutočná príčina: **simulátor kamier enkódoval naživo cez `h264_videotoolbox`.**
Dve simulované kamery po štyroch šošovkách = osem hardvérových enkódov, ktoré
vyťažili ten istý media engine, na ktorom sa meral prepínač.

Rozdiel na jednom 1080p30 enkóde:

| | fps |
|---|---|
| So spusteným simulátorom | 22 |
| Bez neho | **185** |

Simulátor je preto prepísaný tak, že klipy **raz vyrenderuje na disk** a potom ich
donekonečna prehráva cez `-c copy`. Osem streamov teraz stojí **3,1 % CPU** a media
engine nechá na pokoji.

**Pravidlo:** merací prípravok nesmie súťažiť o zdroj, ktorý sa meria. Pri video
pipeline to znamená, že zdroj testovacích dát nesmie enkódovať.

### Dve chyby súbežnosti, ktoré to odhalilo

Pri prechode na súbežné dráhy spadol proces dvakrát, a obe príčiny stoja za zápis:

1. **Štyri vlákna zapisovali do toho istého poľa enkodérov.** Swift pole nie je
   bezpečné na súbežný zápis ani pri rôznych indexoch. Enkodéry sa teraz vytvárajú
   sériovo, pred súbežnou časťou.
2. **Jeden `MetalCompositor` zdieľaný štyrmi dráhami.** Drží zásobník snímok
   a počítadlá. Každá dráha má teraz vlastný.

---

## M7 · Node — príjem a zápis v jednom procese

**Dátum:** 2026-08-15 · **Stav:** overené proti simulátoru (Apple M1 Pro)

Pôvodný návrh mal na každý stream vlastný FFmpeg, ktorý si stream ťahal späť
z MediaMTX cez localhost a zapisoval ho. To je skok navyše a štyri procesy na
kameru. **MediaMTX vie prijať a zapísať v jednom procese** — presne ako to robil
pôvodný Orah setup cez nginx-rtmp (`recorder` blok v `nginx_file/nginx.conf`).

### Spotreba na node

| Proces | CPU | Pamäť |
|---|---|---|
| MediaMTX — príjem **a zápis** 4 streamov | **3,1 %** | 49 MB |
| Proxy transkód (1 kamera) | 9,4 % | 110 MB |
| Agent | 0,7 % | 49 MB |

Nahrávanie teda stojí prakticky nič. **Jediná skutočná práca na node je proxy** —
a tá je nutná, lebo zmenšenie obrazu sa bez prekódovania spraviť nedá.

### Formát a delenie súborov

| | |
|---|---|
| Formát | fMP4 (`recordFormat: fmp4`) |
| Časť | 1 s — pri páde napájania sa stratí najviac sekunda |
| Segment | **25 minút ≈ 2,8 GB** |

Delenie je počítané tak, aby sa súbory zmestili **pod 3 GB** a dali sa kopírovať
kamkoľvek. MediaMTX delí podľa času, nie veľkosti, takže:

```
15 Mbit/s = 1,875 MB/s        (M2)
3 GB ÷ 1,875 MB/s ≈ 28,6 min  →  nastavené 25 min s rezervou
```

### Proxy sa nenahráva

Pravidlo v konfigurácii (`~^.*/proxy$` s `record: no`) vylučuje náhľadové streamy
zo zápisu. Bez neho sa na disk píše aj zmenšená kópia záberu, ktorý sa vedľa toho
už nahráva v plnej kvalite.

### Stavová stránka

Agent servuje živý stav na `http://<node>:8000/` a textovú verziu na `/status.txt`
pre konzolu bez prehliadača. Ukazuje počet prichádzajúcich streamov, voľné miesto
a **odhad zostávajúceho času nahrávania** — číslo, ktoré počas akcie rozhoduje,
či treba zasiahnuť.

---

## M8 · Pult od RTMP po okno — a osem chýb po ceste

**Dátum:** 2026-08-16 · **Stav:** cesta overená proti simulátoru; obraz zo
skutočnej kamery zatiaľ nepotvrdený

Aplikácia bola dovtedy poskladaná z hotových dielov, ktoré neboli spojené:
protokol, prepínač a rozhranie existovali každý zvlášť. Toto meranie je o ich
spojení a o ôsmich chybách, ktoré sa pri tom našli. Sedem z nich bolo v našom
kóde alebo konfigurácii, jedna v sieti.

### Ako sa to meralo

Reťaz sa dala rozdeliť na kusy a merať po častiach:

    ./orahctl deskcheck rtmp://127.0.0.1:1935/cam09/ 16

Vypisuje dve čísla — koľko snímok sa prečítalo z RTMP a koľko ich vyšlo z
monitorového odbočníka prepínača. Tým sa čierny monitor rozdelí na tri rôzne
poruchy: nič neprišlo, prišlo ale neprekomponovalo sa, alebo došlo až k oknu a
chyba je v zobrazení.

Proti simulátoru (`tools/sim-camera.sh`) cesta funguje:

| | |
|---|---|
| Prečítané z RTMP za 16 s | 1592 snímok |
| Vyšlo z monitorového odbočníka | 378 snímok |
| Rozmer | 1920×1440 |

Rozdiel medzi tými číslami nie je chyba: **výstup ide podľa hodín, nie podľa
príchodu snímok.** Keď snímka nepríde načas, tik zopakuje poslednú. Vahana
premenlivú snímkovú frekvenciu odmieta, takže je to zámer.

V aplikácii to isté hovorí riadok v logu, každých päť sekúnd:

    [desk] cam2 read 1592 · monitor program 919 preview 919

### Chyba 1 · MoQ v MediaMTX 1.20 zhasne aj RTMP

Verzia 1.20 štartuje MoQ listener, ktorý si generuje TLS kľúč **do aktuálneho
adresára**. Spustené z terminálu je to priečinok projektu a prejde to; spustené
z Findera je to `/`, zápis zlyhá — a MediaMTX vypne **všetky** listenery vrátane
RTMP. Aplikácia teda fungovala z príkazového riadku a z Docku nie.

Rieši sa `moq: no` v konfigurácii. **Platí to aj pre nody** — tam by to zhaslo
nahrávanie.

Odtiaľ pochádzali aj súbory `tools/auto.key` a `auto.crt`.

### Chyba 2 · `readTimeout` podreže kamere spojenia

Orah otvorí **všetky štyri RTMP spojenia naraz** a príkaz `publish` na nich pošle
až o poriadny kus neskôr. Namerané: spojenia otvorené v čase `T` boli zabité v
`T+30 s` bez toho, aby na nich čokoľvek prišlo.

    02:03:36  conn 253:54778 opened
    02:03:36  conn 254:43468 opened
    02:04:06  closed: i/o timeout      ← presne o 30 sekúnd

Kamera na to odpovie tým, že zhodí a reštartuje celý set — čo vyzerá ako
pokazený hardvér. Pôvodný Orah setup bežal na nginx-rtmp, ktorý je zhovievavejší.

`readTimeout` aj `writeTimeout` sú preto **120 s**, na Macu aj na nodoch.

### Chyba 3 · Rozlíšenie adresy siahalo na riadiaci port

Bonjour vráti endpoint, nie adresu. Rozlíšenie bolo urobené otvorením **TCP**
spojenia — teda na port 9989, riadiaci. Pri každom hľadaní kamery.

Rieši sa rozlíšením cez **UDP**: adresa sa dozvie z mDNS rovnako, ale UDP
spojenie dosiahne `.ready` bez handshaku, takže kamera o ňom nevie.

### Chyba 4 · Jedno zlyhané rozlíšenie stratilo kameru na celý beh

`browseResultsChangedHandler` sa ozve len pri **zmene** zoznamu výsledkov. Kamera,
ktorá sa práve nedala rozlíšiť, sa zahodila — a keďže sa ďalej hlásila, zoznam sa
už nezmenil a nikdy sa to neskúsilo znova.

Rieši sa opakovaním, kým sa kamera hlási.

### Chyba 5 · Čítačky sa vzdali skôr, než kamera začala vysielať

Od príkazu `START` po prvý paket ubehne asi pätnásť sekúnd. Čítačky sa pripojili
okamžite, MediaMTX odpovedal `no stream is available on path 'cam02/0_1'` a
všetky štyri ffmpegy hneď skončili. Keď stream nabehol, už ho nikto nečítal.

Rieši sa tým, že čítačka skúša ďalej, kým je kamera na pulte.

### Chyba 6 · Monitor sa pozeral na šošovku, ktorá neprišla

Monitor bol natvrdo pripojený na šošovku `0_0`. Kamera bežne nabehne len s
časťou šošoviek — sú to dva SoC-y a jeden môže zlyhať. Namerané: publikovala
`0_1` a `1_0`, `0_0` nie. Dáta teda tiekli, prepínač ich mixoval a monitor držal
čiernu.

Rieši sa tým, že monitor ukáže **prvú šošovku, ktorá má obraz**, a `0_0`
uprednostní, keď je.

### Chyba 7 · AppKit vymenil vrstvu aj s obrazom

```swift
wantsLayer = true      // AppKit si vyrobí vlastnú vrstvu
layer = CALayer()      // túto mu podstrčíme
```

V tomto poradí je view iba *layer-backed* a AppKit môže vrstvu kedykoľvek
vymeniť — a zahodí s ňou podvrstvu s obrazom. Správne je najprv priradiť vrstvu
a **až potom** si vypýtať layer-backing; vtedy je view jej vlastníkom.

Toto je chyba typu „snímky chodia, vidieť nič" a nedá sa nájsť inak než delením
reťaze na kusy.

### Chyba 8 · Ukončenie procesu nechávalo riadiacu session visieť

Toto je najdôležitejšia položka celého dokumentu a je to skutočná príčina toho,
čo M5 popisuje ako „zaseknuté kamery".

**Kamera má jednu riadiacu session a sama si ju späť nevezme.** Keď klient
zmizne bez zavretia, session zostane obsadená a kamera odpovie na ďalší pokus:

    HTTP/1.1 503 Service Unavailable

`URLSession` to ukáže ako `There was a bad response from the server`, čo
nepovie nič. Rovnaký `503` sa potom prejaví ako `START returned unknownError` aj
ako `GET factoryPresetsProject.ptv returned unknownError` — a vyzerá to ako
pokazená kamera.

Čo to spôsobuje:

- aplikácia zabitá cez `pkill` (SIGTERM) — sokety sa nezavreli
- `orahctl`, ktorý po chybe zavolal `exit()`
- a aj `atexit`, ktorý session zavrel, ale proces skončil skôr, než ukončovací
  rámec stihol odísť z počítača

Rieši sa na troch miestach: `applicationWillTerminate`, obsluha `SIGTERM`, a
`atexit` s **čakaním 400 ms**, aby rámec stihol odísť. Session sa zatvára
synchrónne, mimo aktora — pri ukončení nie je čas na `await`.

Chybová hláška to odteraz povie priamo:

    ERROR [cam] 192.168.0.179 is busy: it already has a control session open
    (HTTP 503). It will not accept another until that one is closed, or the
    camera is power cycled.

**Prevádzkové pravidlo:** jedna session na kameru, držaná po celú akciu, a vždy
vrátená. Nič iné sa riadiaceho portu nesmie dotýkať.

### Chyba mimo kódu · Cisco switch strácal každý tretí paket

Kamera cez switch, oproti routeru z toho istého Macu v tej istej chvíli:

| | strata paketov |
|---|---|
| kamera cez Cisco switch | **28,6 %** |
| router | 0,0 % |
| kamera po obídení switcha | **0,0 %** |

Pri 28 % strate sa WebSocket handshake nedokončí — pôvodný nástroj `camorah.py`
na tej istej kamere zlyhal presne tak isto:

    WebSocket opening handshake timeout
    (peer did not finish the opening handshake in time)

**To je užitočný test sám o sebe:** keď zlyhá aj referenčný nástroj, chyba nie je
v našom kóde. Pôvodný nástroj sa dá spustiť po obídení jeho discovery, ktorú
rozbili zmeny v knižnici `zeroconf` (`info.address` už neexistuje) — jeho
protokolová časť je použiteľná.

### Kamera má dva SoC-y na susedných adresách

    192.168.0.179   48:65:ee:90:09:60   riadenie + publikovanie
    192.168.0.180   48:65:ee:90:09:61   iba publikovanie

Riadiaci port má otvorený len prvý. Druhý odpovedá na ARP a ping, ale na 9989
nepočúva. Susedné MAC adresy sú spoľahlivý spôsob, ako spárovať dve adresy s
jedným kusom — použiteľné pre úlohu #15, keď Bonjour mlčí.

### Referenčný nástroj nikdy neopakoval `START` — a nevedel o tom

V `cameracommand.py`, funkcia `transReply`:

```python
elif api.HasField('video_reply'):
    if api.video_reply.op == CamAPI_pb2.Video.Reply.RetCode.Value('SUCCESS'):
        return 'video_ok'
```

Porovnáva **`op`** (kód operácie) proti **`RetCode`** (návratový kód).
`Video.OpCode.START` je `1` a `Video.Reply.RetCode.SUCCESS` je tiež `1`, takže
každá odpoveď na `START` mu vyjde ako úspech — **nech kamera vráti čokoľvek**.
Skutočné `ret` sa nikdy nečíta.

Dôsledky sú dva a oba sú podstatné:

1. **`UNKNOWN_ERROR` z `START` nikdy nikoho nezastavilo.** Nástroj, ktorý je
   „otestovaný od výroby", ho dostával a nevšimol si to. Nedá sa z neho teda
   usudzovať, že úspešný štart znamená `SUCCESS`.
2. **Referenčný nástroj `START` neopakuje.** Pošle ho raz a ide na `AUDIO_SYNC`.
   Opakovanie, ktoré sme z neho odvodili (úloha #16), v ňom nikdy nebolo —
   opakuje sa iba po udalosti `VIDEO_FAIL`, čo je niečo iné.

**Opakovanie `START` kameru poškodzuje.** Osem pokusov za šestnásť sekúnd ju
dostalo do stavu, v ktorom aj sťahovanie súboru, ktoré o minútu skôr fungovalo,
vrátilo `UNKNOWN_ERROR`. Štyri série po ôsmich (test tvarov adresy) ju položili
úplne.

Správny postup je preto: **`START` raz, návratový kód zapísať, a o úspechu
rozhodnúť podľa toho, či prídu streamy** — nie podľa odpovede.

### `unknownError` zo `START` znamená „už vysielam"

Rozhodnuté na kamere `AQ1702006522`, ktorá deň predtým vysielala a potom už len
odmietala `START`:

```
09:50:05  STOP first: success
09:50:15  streaming to rtmp://192.168.0.192:1935/cam02/
```

`STOP` vrátil `success` — kamera teda **vysielala**, ostala v tom stave z
predchádzajúceho behu. A kamera, ktorá už vysiela, odpovie na `START`
`UNKNOWN_ERROR`. To bolo celé to `unknownError`.

**Pravidlo: vždy `STOP` pred `START`.** Kamery si obnovujú vysielanie samy a
prežije to reštart aplikácie aj výpadok prúdu, takže stav „už vysielam" je
bežný, nie výnimočný. `NO_VIDEO_RUNNING` zo `STOP` je dobrý výsledok, nie chyba.

Prvý obraz zo skutočnej kamery na pulte prišiel týmto — 1920×1440, šošovka
`1_0`, so zvukovou stopou (`H264`, `LPCM`).

Na kuse `AQ1720000160` to nepomohlo: tam `STOP` hlási `noVideoRunning` a `START`
zlyháva ďalej. Ten je v inom stave a zostáva otvorený.

### Tvar cieľovej adresy na tom nič nemení

V jednej session boli vyskúšané štyri tvary (`orahctl starttest`):

| adresa | výsledok |
|---|---|
| `rtmp://IP:1935/inputs/` — presný reťazec referenčného nástroja | `unknownError` |
| `rtmp://IP:1935/cam01/` — náš tvar | `unknownError` |
| `rtmp://IP:1935/inputs` — bez lomky na konci | `unknownError` |
| `rtmp://IP:1935/` — bez aplikácie | `unknownError` |

Adresa teda nie je príčinou.

### Zvuk

MediaMTX hlási na jednej ceste dve stopy:

    [path cam02/0_0] stream is available and online, 2 tracks (H264, LPCM)

Zvuk teda ide s jedným z videostreamov, nie zvlášť.

### Čo tým overené nie je

1. **Obraz zo skutočnej kamery na pulte.** Overený je simulátor. Kamera
   `AQ1720000160` odpovedá na všetko okrem `START`, na ktorý vracia
   `unknownError` aj potom, čo `STOP` ohlási `noVideoRunning`. Tvar adresy to
   nie je (vyskúšané štyri). Neoverené zostáva, či kamera napriek tomu
   **začne vysielať** — referenčný nástroj to nikdy nezisťoval, lebo si
   odpoveď zle prečítal, a my sme namiesto čakania opakovali `START` a kameru
   tým položili. Ďalší pokus preto: `START` raz a čakať dve minúty na streamy.
   Ostáva aj podozrenie na napájanie: kamera, ktorá naposledy vysielala, bola
   iný kus a na inej ceste napájania.
2. Že Vahana prijme náš výstup.
3. Koľko proxy streamov utiahne node.

---

## M9 · Kalibrácia naprieč dvanástimi kusmi — M4 neplatí

**Dátum:** 2026-08-16 · **Stav:** zmerané na 12 kamerách

M4 porovnávalo dva kusy a neskôr päť, a vyšlo z toho **8,9 px** s záverom
„nie je to blokujúci problém". Po prejdení fleetu je k dispozícii dvanásť
kalibračných súborov a ten záver **neplatí**.

    ./tools/fleet-report.py camera-records

| | M4 (5 kusov) | M9 (12 kusov) |
|---|---|---|
| najhorší uhlový rozptyl | 8,9 px | **53,8 px** |
| ktorá šošovka | — | `0_1`, naklonenie |
| v stupňoch | — | 4,73° |

Na 4096 px panoráme je 1° rovných 11,4 px. Podrobne:

| šošovka | uhol | rozptyl | px |
|---|---|---|---|
| `0_1` | roll | 4,73° | **53,8** |
| `1_0` | pitch | 4,51° | 51,3 |
| `1_0` | roll | 4,33° | 49,3 |
| `0_1` | pitch | 3,65° | 41,5 |
| `1_0` | yaw | 1,15° | 13,1 |
| `1_1` | pitch | 0,65° | 7,4 |
| `0_0` | všetky | 0,00° | 0,0 |

Šošovka `0_0` je referenčná a je na všetkých kusoch totožná — to sedí s M4.
Rozdiely sú v ostatných troch, a rastú s počtom porovnaných kusov: čím väčšia
vzorka, tým väčší rozptyl. Pri piatich kusoch sa tie krajné jednoducho netrafili.

### Čo to mení

**Jedna spoločná kalibrácia pre celý fleet nestačí.** Pri prepnutí kamery
zostáva vo Vahane kalibrácia predchádzajúcej a chyba až 4,7° v naklonení sa
prejaví na švíkoch. Na vzdialených záberoch to prejde, na blízkych nie.

Z toho plynú tri možnosti, žiadna zadarmo:

1. **Kalibrácia sleduje zdroj** — pri prepnutí kamery sa mení aj kalibrácia vo
   Vahane. Čisté riešenie, ale Vahana ju nemení za behu.
2. **Spoločný orez prieniku** — použiť jednu kalibráciu a orezať tak, aby sa do
   záberu nikdy nedostal nepoužiteľný okraj žiadneho kusa. `fleet-report.py`
   ten orez počíta. Stojí to zorné pole.
3. **Kamery zoradiť do skupín** podľa toho, ako blízko k sebe majú kalibráciu, a
   prepínať len v rámci skupiny.

### Kamera bez kalibrácie

Kus `AQ1721000175` (kamera 22) **nemá `factoryPresetsProject.ptv` vôbec** —
ani žiadny iný súbor. Pôvodný Orah nástroj ju podľa operátora nevie ani
prekalibrovať, iba ohlási chybu.

Streamuje pritom bezchybne: ako jediná z fleetu nahodila všetky štyri streamy
naraz, 1920×1440, so zvukom. Firmvér aj hardvér má rovnaké ako zvyšok.

Vzhľadom na rozptyl vyššie je to horšie, než to vyzeralo: požičaná kalibrácia
z iného kusa na nej môže byť vedľa o desiatky pixelov. Použiteľná je, ale
patrí na zábery, kde na švíkoch nezáleží.

---

## M10 — `UNKNOWN_ERROR` na START znamená „vytiahni jej prúd", nie „skús znova"

*2026-08-16, šestnásť kamier, testované po trojiciach.*

Doteraz sa návratový kód zo `START` ignoroval — referenčný nástroj porovnáva
*operačný kód* proti *návratovému kódu* (`op == SUCCESS`, kde START je 1 a
SUCCESS je 1), takže mu každá odpoveď vyjde ako úspech a nikdy neopakuje. Preto
sme ho brali ako nič nehovoriaci. Nehovorí, či sa kamera rozbehla — to povie len
obraz — ale hovorí, či sa ešte niekedy rozbehne.

| kamera | odpoveď na 1. START | obraz | čo pomohlo |
|---|---|---|---|
| 02, 04, 05, 06, 07, 09, 10, 12, 20, 21, 24 | `SUCCESS` | 4/4 | — |
| 03 `AQ1610012312` | `UNKNOWN_ERROR` | nič | odpojenie od napájania |
| 22 `AQ1721000175` | `UNKNOWN_ERROR` | nič | odpojenie od napájania |
| 08 `DVT2AQ16080040` | `UNKNOWN_ERROR` | **2/4** (`1_0`, `1_1`) | — |
| 11 `AQ1720000160` | `UNKNOWN_ERROR` | nič | ani power cycle, ani `Cam.RESTART` |

Kamera 3 dostala tri STARTy po tridsiatich sekundách, zakaždým
`UNKNOWN_ERROR` a zakaždým ticho. Po vytiahnutí zo zásuvky jej **hneď prvý**
START odpovedal `SUCCESS` a poslala 4/4.

Kamera 11 sa opakovaním **zhoršovala**. Pri prvom pokuse ešte stiahla
`factoryPresetsProject.ptv`; pri druhom už aj to vrátilo `UNKNOWN_ERROR`. To je
presne degradovaný stav z M8, len sa doň tentoraz dostala tromi príkazmi za
minútu namiesto ôsmich za šestnásť sekúnd.

**Žiadna kamera, ktorá poslala celé štyri šošovky, neodpovedala na svoj prvý
START inak ako `SUCCESS`** — pätnásť z pätnástich.

### Čo `UNKNOWN_ERROR` pravdepodobne znamená

Kamera 8 to spresnila. Odpovedala `UNKNOWN_ERROR` a napriek tomu poslala
**dve šošovky — `1_0` a `1_1`**. Prvá pôvodná formulácia („nikdy neposlala
obraz") teda neplatí a opravujem ju.

Sedí to na všetko, čo sme videli, ak návratový kód znamená *„aspoň jeden SoC
nerozbehol video"*:

| kamera | odpoveď | šošovky | výklad |
|---|---|---|---|
| zdravé kusy | `SUCCESS` | 4/4 | oba SoC nabehli |
| 08 | `UNKNOWN_ERROR` | 2/4 | jeden SoC nenabehol |
| 11, 22, 03 | `UNKNOWN_ERROR` | 0/4 | nenabehol ani jeden |

Kamera má dva SoC na susedných adresách a `START` ide na jeden riadiaci kanál za
oba. Kód je teda spoločná odpoveď za obidva — a `UNKNOWN_ERROR` nie je „skús
znova", ale „časť videoreťazca nenabehla". Preto sa oplatí ho ukázať v rig
checku: hovorí, že kus treba odpojiť od prúdu, a ak to nepomôže, že je pokazený.

Dôsledok pre aplikáciu: pri `UNKNOWN_ERROR` sa počká na obraz (lebo kód sám o
sebe nie je dôkaz), ale **nepýta sa druhýkrát** — rovno povie, že kamera
potrebuje odpojiť od prúdu. Opakovanie nikdy nič nezachránilo a stálo dve minúty,
počas ktorých sa kamera zhoršovala. Keď START odpovie `SUCCESS` a obraz
nepríde, opakuje sa raz — tam má opakovanie zmysel.

Vedľajší nález: kamera 3 po zapnutí sama nabehla a streamovala 4/4 do cesty
`cam01`, ktorú si pamätala z minulého číslovania. Vysielala celý čas — len tam,
kam sa nikto nepozeral. Kontrola zapamätaného cieľa preto porovnáva celú adresu
vrátane cesty, nielen IP.

---

## Čaká na hardvér

Zo špecifikácie, sekcia 10:

1. ~~Skutočný dátový tok na kameru~~ — **hotovo, ~60 Mbit/s** (M2)
2. Posun medzi kamerami — potrebné dve kamery naraz
3. Posun medzi šošovkami a či kopíruje rozdelenie na dva SoC
4. Koľko proxy streamov utiahne node
5. Že Vahana prijme náš enkódovaný stream
6. ~~Ako je zvuk rozložený~~ — **hotovo, 2×2 kanály** (M2); zostáva overiť, ako si
   ich Vahana mapuje na W/X/Y/Z
7. ~~Či `Video.STOP` kameru zastaví~~ — **hotovo, zastaví** (M2)
