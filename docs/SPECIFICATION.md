# Orah Live Studio — špecifikácia

Stav: **na odsúhlasenie**. Vznikla z rozhovoru nad pôvodným návrhom v tomto repozitári.
Všetko, čo je tu napísané ako rozhodnutie, má uvedený dôvod. Čo nie je overené, je
označené ako **zmerať**.

---

## 1. Čo to je

Ovládacia aplikácia pre macOS na živú réžiu poľa 360° kamier Orah 4i.

Operátor pri nej sedí počas akcie a robí tri veci: sleduje, čo sa deje na kamerách,
prepína medzi nimi mäkkým prechodom, a dohliada na to, že sa všetko nahráva. Nastavenia
sú v samostatnom okne a počas akcie do cesty nelezú.

**Rozsah jednej akcie: až 24 kamier.**

---

## 2. Hardvér a topológia

| Prvok | Úloha |
|---|---|
| Orah 4i × N | 4 snímače, 2 SoC, štyri nezávislé RTMP streamy (`0_0`, `0_1`, `1_0`, `1_1`) |
| Mac (M4) | ovládanie, prepínanie, multiview — **beží na ňom aplikácia** |
| Intel nody | príjem streamov, nahrávanie na disk, generovanie proxy |
| Stitching PC | Vahana VR — zošíva 4 vstupy do 360° obrazu |

Kamery sú napájané cez PoE a adresu dostávajú z DHCP. Ohlasujú sa cez Bonjour ako
`_vscamera._tcp`.

---

## 3. Signálová cesta

```
                    ┌─────────── node 1 ────────────┐
Kamera 01..06 ──4×RTMP──► MediaMTX ──► FFmpeg copy ──► disk
                          │        └──► proxy (malé) ──┐
                    └───────────────────────────────┘  │
                    ┌─────────── node 2 ────────────┐  │
Kamera 07..12 ──4×RTMP──► MediaMTX ──► FFmpeg copy ──► disk
                          │        └──► proxy ─────────┤
                    └───────────────────────────────┘  │
                            ...                        │
                                                       │
        program + preview (2 kamery, plná kvalita)     │ multiview (všetky, malé)
                            │                          │
                            ▼                          ▼
                    ┌──────────────── Mac ─────────────────┐
                    │   prepínač: dekód → prelínačka →     │
                    │   enkód → 4× RTMP                    │
                    └──────────────────┬───────────────────┘
                                       ▼
                              MediaMTX (Mac)
                                       ▼
                          Vahana si stream vyzdvihne
                                       ▼
                              stitching PC → 360°
```

### 3.1 Kamery publikujú na svoj node, nie na Mac

**Toto je najväčšia zmena oproti pôvodnému návrhu.**

Pôvodne všetky kamery publikovali na Mac a nody si streamy ťahali z Macu. Pri 24
kamerách je to 96 streamov, rádovo 1–2 Gbit/s — a cez Mac by to tieklo **dvakrát**,
dnu aj von. Neprejde to ani cez 10GbE.

Mac tie dáta nepotrebuje. Na prepínanie mu stačia dve kamery, program a preview —
osem streamov, rádovo 150 Mbit/s.

Adresu, kam má kamera publikovať, jej posielame my v príkaze `START`. Takže každá
kamera dostane adresu **svojho nodu**, stream prejde sieťou raz, a pridávanie kamier
je pridávanie nodov. Cez Mac netečie pri 24 kamerách viac dát než pri dvoch.

---

## 4. Protokol kamery

Overené proti `proto/CamAPI.proto`, implementácia otestovaná na zhodu bajt po bajte
s referenčnou Google protobuf implementáciou (18/18 testov, `orahctl selftest`).

| Vec | Hodnota |
|---|---|
| Objavovanie | Bonjour `_vscamera._tcp` |
| Riadenie | WebSocket `/control`, subprotokol `camctrl-protobuf/1.0` |
| Formát | proto2, binárne |
| Štart | `Api.video.op = START`, `url` = základ RTMP adresy |
| Stop | `Api.video.op = STOP` |
| Identita | `GET_CAMERA_INFO` → sériové číslo, model, firmvér |
| Kalibrácia | `factoryPresetsProject.ptv`, `rigParameters.json` |

### 4.1 Adresa streamu určuje meno cesty

Kamera si k zadanej adrese **sama pridá** `0_0`, `0_1`, `1_0`, `1_1`.

Preto dostane adresu `rtmp://node:1935/cam07/` a publikuje na `cam07/0_0` až
`cam07/1_1`. V pôvodnom kóde dostávala adresu bez mena kamery, takže všetky kamery
publikovali na tie isté štyri cesty a nahrávanie, ktoré čakalo `camNN/...`,
nezachytilo nič.

### 4.2 Číslovanie kamier je viazané na hardvér

Slot kamery (`NN` v `camNN`) sa určuje podľa **sériového čísla**, nie podľa poradia,
v akom sa kamery objavili. Poradie objavenia sa medzi spusteniami mení — `cam01`
a `cam02` by si ticho vymenili miesto, scény by ukazovali iný záber a včerajšie
nahrávky by nesedeli s dnešnými.

### 4.3 `AUDIO_SYNC` je klapka pre postprodukciu

Posiela sa raz, hneď po štarte streamu. Zarovnáva **štyri streamy vnútri jednej
kamery** v strižni. Naprieč kamerami nefunguje — každá si pípne, keď jej dorazí
príkaz, a tie príkazy posielame po sieti postupne.

---

## 5. Prepínanie

### 5.1 Prepína sa štvorica, nie štyri veci

Nikdy sa neprepína jedna šošovka. Vždy „kamera N a jej štyri šošovky“ — jedna
nedeliteľná štvorica, ktorá musí prejsť v ten istý okamih. Ak jedna dráha nabehne
o pár snímok neskôr, Vahana počas prechodu zošíva starú šošovku s novou a prejaví
sa to na švíkoch.

### 5.2 Prelínačka je požiadavka, nie ozdoba

Tvrdý strih vo VR360 diváka v headsete dezorientuje. Mäkký prechod je preto povinný,
a to je dôvod, prečo sa prepínanie nedá spraviť len prepnutím cesty v MediaMTX —
prepnutie cesty je tvrdý strih a k tomu zlom v streame.

### 5.3 Preview + Take

Cieľová kamera sa najprv nahrá do **preview**, kde si stihne nabehnúť, a až potom
sa jedným povelom prepne. Dôvody sú dva a oba sú technické:

- prechod začína z už bežiaceho obrazu, takže nevzniká čierna diera na začiatku
- dekódujú sa vždy **len dve kamery** bez ohľadu na to, či ich je 2 alebo 24

Na MIDI pulte: pady vyberajú do preview, samostatný veľký gombík je Take.

### 5.3.1 T-páčka — prelínačka vedená rukou

Vedľa tlačidla Take je **T-páčka**. Take vedie prelínačku časom, páčka ju vedie rukou —
dá sa pribrzdiť, zastaviť v polovici, dotiahnuť podľa toho, čo sa deje na scéne.
Časovaný prechod na to odpoveď nemá.

Implementačne to nič nepridáva: prelínačka je aj tak jedno číslo 0–1, ktoré ide do
Metal blendu. **Take ho ženie časovačom, páčka ho ženie polohou úchytu.** Rovnaká
cesta, iný pohon.

Páčka je **obojsmerná** — po dotiahnutí zostane na druhom konci a nasledujúci prechod
ide opačne, ako na skutočnom pulte. Musí byť **naviazateľná na fyzický fader** na MIDI
pulte (APC mini ich má deväť); až tým sa z toho stane pult a nie obrazovka.

### 5.3.2 Kalibrácia je na kus — otvorená otázka prepínania

Kalibračný súbor `factoryPresetsProject.ptv` obsahuje **namerané** hodnoty pre
konkrétny kus: yaw, pitch, roll, ohnisko a skreslenie na každú šošovku (viď M3).
Nie sú to ideálne čísla — každá kamera je zložená s vlastnými odchýlkami.

**Ak Vahana zošíva kalibráciou kamery A a prepneme na kameru B, švíky sa rozídu.**

Knižnica `libvideostitch` má `updatePanorama()`, označený ako *„thread safe
resetPanorama"*, takže výmena za behu je možná. Dokumentácia ale varuje, že sa to
nemá volať počas stitchingu — a prechod je presne ten okamih. A či to vôbec vie
aplikácia Vahana VR cez svoje rozhranie, nevieme.

**Tri možnosti, medzi ktorými sa nedá rozhodnúť bez merania:**

1. Vahana prepne kalibráciu súčasne so zdrojom
2. Kamery sa prekalibrujú na spoločnú sadu hodnôt
3. Odchýlka medzi kusmi je dosť malá, aby sa dala zniesť

**Zmerané (M4):** odchýlka medzi dvomi kusmi je najviac **0,56°**, čo je na panoráme
4096 px asi **6 pixelov** posunu na švíku. Mierne mäkký švík, nie roztrhnutý obraz —
**prepínanie kamier teda nie je blokované kalibráciou.**

Väčšie riziko je **orez**, ktorý sa líši až o 47 vstupných pixelov. Ak sa ide
s jednou spoločnou kalibráciou, orez sa musí nastaviť na **prienik** hodnôt zo
všetkých kamier, aby sa nikdy nezatiahol okraj šošovky.

### 5.4 Vlastný prepínač

Reťaz: príjem → hardvérový dekód → prelínačka → hardvérový enkód → výstup.

| Časť | Čím |
|---|---|
| Príjem a výstup RTMP | `ffmpeg -c copy` cez rúru — len prebalenie kontajnera |
| Dekód | VTDecompressionSession (hardvér) |
| Prelínačka, multiview | Metal |
| Enkód | VTCompressionSession (hardvér) |
| Delay | kruhový buffer snímok |

RTMP sa nepíše, FFmpeg ho vie a použije sa ako tenká redukcia protokolu — streamcopy,
zlomok jadra, desiatky milisekúnd. Zvyšok sú systémové frameworky.

**Pravidlo pre celý obrazový reťazec: dekodér → GPU textúra → obrazovka alebo enkodér.
Snímka nikdy neprechádza cez CPU.** Toto je dôvod, prečo je multiview v OBS zadarmo,
a rovnaká cesta je dostupná aj nám.

### 5.5 Čo musí spĺňať výstup do Vahany

Prečítané z [IO/src/rtmp README](https://github.com/stitchEm/stitchEm/blob/master/IO/src/rtmp/README.md)
projektu stitchEm — Vahana je open source, takže to nie je odhad.

| Požiadavka | Dôsledok pre nás |
|---|---|
| Vahana je vždy **klient**, tlačiť jej stream nejde | medzi nás a Vahanu patrí RTMP server → MediaMTX na Macu |
| **Konštantný frame rate**, VFR nepodporuje | enkodér to musí vynútiť, samo sa to nestane |
| Len **H.264** | VideoToolbox to enkóduje hardvérovo |
| Zvuk 44,1 alebo 48 kHz, mono/stereo, `s16`/`s32`/`flt` | |

Na vstupe žiadne obmedzenie profilu ani levelu — čítačka stojí na `libavformat`.

Vahana vie RTMP aj von, takže zošitý obraz je kedykoľvek dostupný späť. Do strihového
prostredia ho netreba, ale možnosť je otvorená.

---

## 6. Delay a synchronizácia

### 6.1 Kamery nie sú medzi sebou synchronizované

Orah 4i nemá genlock, sníma podľa vlastného kryštálu. Existencia príkazu `AUDIO_SYNC`
je toho dôkazom — nikto nerobí zvukovú klapku na zarovnávanie niečoho, čo je už
zarovnané.

**Kryštály sa navyše rozchádzajú.** Rozdiel 10 ppm je asi 36 ms za hodinu, takže
delay nie je hodnota „nastav raz a zabudni“ — počas dlhej akcie ju treba vedieť
dorovnať.

### 6.2 Meranie

Primárne podľa **času príchodu snímok na node**. Kamery sú rovnaký model na rovnakej
sieti, takže rozdiel v ceste je malý a nameraný rozdiel je zhruba skutočný posun.

Aplikácia hodnotu navrhne, operátor ju potvrdí alebo prepíše, a uloží sa ku kamere.
Premerať sa dá kedykoľvek jedným povelom.

**Akustická korelácia sa ako primárne meranie nepoužije.** Zvuk letí ~3 ms na meter,
takže kamera 30 m od zdroja počuje tlesknutie o 90 ms neskôr. Pri kamerách roztiahnutých
po hale to nie je chyba merania, ale chyba, ktorá sa zavedie do obrazu.

### 6.3 Delay vie len pridávať

Referenciou je najoneskorenejšia kamera, ostatné sa k nej dobrzďujú. Celkové
oneskorenie systému je teda rovné rozptylu medzi kamerami.

### 6.4 Vnútri kamery

Štyri snímače na jednej doske zdieľajú hodinový signál, takže **snímanie** je
genlocknuté — inak by sa pohybujúci objekt nedal zošiť cez švík. **Doručenie**
synchronizované nie je, streamy idú cez dva nezávislé SoC.

Ovládanie je preto na úrovni kamery, ale **dátový model podporuje delay aj na
šošovku**. Doplniť to teraz nestojí nič, prerábať neskôr je zásah do celej cesty.

**Zmerať:** či sa rozdiel prejaví medzi dvojicami šošoviek (podľa SoC) alebo náhodne
medzi štyrmi. Ak podľa dvojíc, je to vlastnosť hardvéru, nie siete.

---

## 7. Multiview

Operátor musí vidieť všetky kamery naraz. Pri 24 kamerách to nesmie znamenať 24
plných dekódov.

### 7.1 Proxy na nodoch

Node z každej kamery vyrobí druhý, malý stream — rádovo 480×270 pri 10 fps,
150–250 kbit/s. Intel to spraví cez QuickSync hardvérovo. Publikuje sa vedľa
originálu ako `camNN/proxy`.

Mac potom dekóduje 24 **maličkých** streamov namiesto 24 plných. Sieťou k Macu ide
na celý multiview asi 5 Mbit/s.

### 7.2 Výber šošovky

Multiview ukazuje jednu šošovku na kameru; prepínačom sa mení, **ktorá zo štyroch**
to je — pre všetky kamery naraz tá istá.

**Node prekóduje len práve zvolenú šošovku, nie všetky štyri.** Pri šiestich kamerách
je to rozdiel medzi 6 a 24 súčasnými dekódmi 1080p — a 24 je za hranicou bežného
QuickSync. Cena je asi sekunda nábehu pri prepnutí šošovky, čo je úkon robený
zriedka, nie počas strihu.

### 7.2.1 Dimenzovanie nodu

Nody sú lacné HP mini PC, k dispozícii je ich 60. Počítané pri 1080p a ~15 Mbit/s
na šošovku, teda 60 Mbit/s na kameru.

| | Node s 2 kamerami |
|---|---|
| Sieť dnu | ~120 Mbit/s |
| Zápis na NVMe | ~15 MB/s |
| Miesto na 3 hodiny | ~165 GB |
| Transkód pre proxy | 2 × (dekód 1080p + malý enkód) |
| Proxy von | ~0,5 Mbit/s |

**Dve kamery na node, 12 nodov na 24 kamier, zvyšok ako náhrady.**

Dôvodom pre takú nízku hustotu nie je výkon — stroj beží na zlomku svojich možností —
ale **veľkosť škody pri poruche**. Node so šiestimi kamerami odoberie pri páde šesť
kamier, node s dvomi odoberie dve. Pri 60 strojoch v zálohe nie je dôvod tlačiť na
jeden.

Priepustnosť NVMe nie je obmedzením ani zďaleka. Obmedzením je **kapacita** (preto
aplikácia ukazuje voľné miesto a odhad zostávajúceho času) a **transkódovacia
kapacita** iGPU.

### 7.2.3 Referenčný najslabší node

**HP ProDesk 600 G2 DM, Celeron G3900T** (Skylake, 2 jadrá bez HT, 2,6 GHz,
Intel HD 510, 8 GB RAM). Najslabší dostupný kus určuje pravidlá pre všetky.

HD 510 je Gen9, takže má QuickSync s hardvérovým H.264 dekódom aj enkódom vo fixnej
funkcii — tá je do veľkej miery nezávislá od počtu EU jednotiek. **Dva transkódy proxy
zvládne pohodlne.**

Osem súčasných transkódov (všetky štyri šošovky pri dvoch kamerách) **nezvládne**.
Prekódovanie len zvolenej šošovky teda nie je optimalizácia, ale požiadavka.

### 7.2.4 Proxy nikdy nesmie spadnúť na softvérový enkodér

> Ak hardvérový enkodér nie je k dispozícii, proxy sa **odmietne spustiť**.

Na dvoch jadrách Celeronu zožerie jediný softvérový transkód 1080p celý stroj — a na
tom istom stroji beží zápis nahrávky. FFmpeg pritom na `libx264` prepne sám a bez
varovania, keď sa hardvérová akcelerácia nepodarí. Je to chyba, ktorá sa pri teste
s jednou kamerou neprejaví a položí akciu.

Agent pri štarte overí, že enkodér existuje (`vainfo` musí ukázať H.264 encode profil).
Ak nie, ohlási sa ako **degradovaný**: nahráva, proxy neposkytuje. Multiview príde
o dlaždicu, nahrávka o nič.

### 7.2.2 Nody sa ohlasujú samy

Pri 12 a viac nodoch je ručné vypisovanie IP adries neprípustné. Agent sa ohlasuje
cez Bonjour rovnako ako kamery — po zapnutí sa objaví v aplikácii. Priradenie kamier
navrhne aplikácia, operátor ho môže prepísať.

### 7.3 Program a preview z plnej kvality

Proxy je dobrý na „čo sa kde deje“. Na posúdenie ostrosti a záberu pred strihom nie.

### 7.4 Nahrávanie má prednosť

Proxy je **postrádateľný**. Keď node nestíha, prvé, čo sa vypne, je proxy — nikdy
nie zápis na disk. Radšej slepý multiview než diera v nahrávke.

---

## 8. Nahrávanie

Nezávislé od prepínania, a to zámerne: keď spadne čokoľvek v réžii, súbory sa píšu ďalej.

- FFmpeg **streamcopy**, žiadne prekódovanie
- kontajner **MKV** — prežije náhle vypnutie bez finalizácie
- beží od momentu, keď kamera začne streamovať
- node zapisuje **lokálne**, stream neprechádza cez Mac

### 8.0 Nahráva MediaMTX, nie FFmpeg

Kamery publikujú na node a **ten istý proces ich zapisuje na disk** — žiadny FFmpeg,
žiadny skok späť cez localhost, žiadne prekódovanie. Namerané: **3,1 % CPU** za príjem
aj zápis štyroch streamov (M7).

Rovnako to robil pôvodný Orah setup cez nginx-rtmp (`recorder` blok
v `nginx_file/nginx.conf`); toto je tá istá myšlienka so softvérom, ktorý sa udržiava.

Formát je **fMP4 s jednosekundovými časťami**, takže výpadok napájania stojí najviac
sekundu, nie celý súbor. Segmenty sú **25-minútové**, čo pri nameraných 15 Mbit/s dá
asi **2,8 GB na súbor** — pod hranicou 3 GB, aby sa dali kopírovať kamkoľvek.

### 8.0.1 Disky sa zlievajú do jedného priečinka

Na node môže byť viac USB-C diskov. Sú spojené cez **mergerfs** do jednej cesty, do
ktorej MediaMTX zapisuje a o diskoch nevie.

| Vlastnosť | Prečo tak |
|---|---|
| Každý disk zostáva vlastný súborový systém | dá sa odpojiť a odniesť s celými súbormi |
| `category.create=ff` | plní sa prvý, potom ďalší — ako to robí nahrávač |
| `minfreespace` | pod hranicou sa nový súbor založí na ďalšom disku |
| `moveonenospc=false` | rozpísaná nahrávka sa nikdy nepresúva medzi diskami |

Keďže segment má 25 minút, **prechod na ďalší disk vždy padne na hranicu súboru** —
žiadna nahrávka nie je rozpolená medzi dva disky.

**Disk sa dá pridať počas akcie.** Operátor ho zapojí a stlačí tlačidlo na stavovej
stránke nodu; vetva sa pridá do bežiaceho mergerfs, nahrávanie sa nepreruší a nič sa
nereštartuje. Odpojenie ide rovnako a **odmietne sa, kým sa na disk ešte zapisuje**.

Agent je bez oprávnení; pripojenie disku je jediná vec, na ktorú potrebuje root,
a dostane ju cez jedno úzke pravidlo v `sudoers` obmedzené na ten jeden skript.

Aplikácia zobrazuje na každom node **voľné miesto a odhad zostávajúceho času**.
Mid-show je „koľko ešte nahrá“ užitočnejšia otázka než „je online“.

### 8.1 Nahrávacia matica

Pri 24 kamerách sa zapisuje **96 súborov**. Zoznam nevie na jeden pohľad povedať, že
je všetkých 96 v poriadku — mriežka áno.

Samostatné okno: **jedna bunka na stream**, zoskupené podľa nodu, ktorý ich vlastní.
Štyri bunky na kameru (`0_0`, `0_1`, `1_0`, `1_1`), dve kamery na node.

| Stav bunky | Význam |
|---|---|
| Plná červená | zapisuje |
| Šrafovaná | zlyhala, treba zásah |
| Prázdna | nečinná |

**Ovládanie je po nodoch**, nie po kamerách: klikneš node, potom Record. Každý node má
navyše vlastné **SOLO** a **STOP**, aby sa dal zastaviť alebo osamostatniť jeden bez
zásahu do ostatných.

Tým sa zodpovedá otvorená otázka „nahrávanie po kamerách alebo všetko naraz“ —
**po nodoch**, čo je zároveň hranica poruchy aj hranica disku.

---

## 8A. Zvuk

Kamery nesú zvuk vo svojich streamoch. Treba ho na dve veci: **počúvať** a **poslať
ďalej na spracovanie**.

### 8A.1 Odkiaľ ho Mac berie

**Proxy z nodu nesie aj zvuk** — video zmenšené, ale zvuk pretečený streamcopy
v pôvodnej kvalite. Nestojí to prakticky nič (rádovo 128 kbit/s na kameru) a Mac tým
má zvuk zo **všetkých 24 kamier** bez toho, aby ťahal plné streamy.

Dekódovanie 24 AAC streamov je zanedbateľné — zvuk nemá s obrazovým rozpočtom nič
spoločné.

### 8A.2 Zvuk je ambisonický

Orah 4i má **štyri mikrofóny a produkuje 4-kanálový ambisonický zvuk** (prvý rád,
W/X/Y/Z). Nie je to stereo a nesmie sa tak s ním zaobchádzať.

Vahana ambisonic vie natívne — `lib/include/libvideostitch/audio.hpp` definuje
`AMBISONICS_WXY`, `AMBISONICS_WXYZ`, `AMBISONICS_2ND`, `AMBISONICS_3RD`,
`MAX_AUDIO_CHANNELS` je 35.

**Zmerané na hardvéri (M2): zvuk je na `0_0` a `1_0`, LPCM 44,1 kHz, 2 kanály.**
Teda **dve stereo dvojice, jedna z každého SoC** — spolu štyri kanály. Nie po jednom
kanáli na štyroch streamoch, ako sa pôvodne predpokladalo. Sedí to aj na obmedzenie
RTMP pluginu (1–2 kanály na vstup).

### 8A.2.1 Formát je AmbiX — ACN poradie, SN3D normalizácia

Podľa oficiálneho manuálu Orah 4i (User Guide v1.2.0, VideoStitch 2017) kamera
dodáva priestorový zvuk **prvého rádu v AmbiX formáte: ACN poradie kanálov a SN3D
normalizácia**.

Pre prvý rád to znamená poradie kanálov **W, Y, Z, X** (ACN 0 až 3) — nie W, X, Y, Z,
ako by sa dalo čakať. Toto poradie je pri miešaní a smerovaní zvuku záväzné.

Zmerané rozloženie (M2, M3) sedí: štyri kanály, po dvoch na SoC, na streamoch `0_0`
a `1_0`. **Zostáva overiť, ktorá dvojica nesie ktoré kanály ACN** — teda či `0_0`
nesie W+Y a `1_0` nesie Z+X, alebo naopak.

### 8A.2.2 Natočenie obrazu sa na zvuk neaplikuje

Manuál to hovorí priamo: úpravy orientácie a stabilizácia aplikované na obraz sa
**neaplikujú na zvukové pole**.

Pre prepínač je to dobrá správa. Zvukové pole zostáva v sústave svojej kamery, takže
pri prepnutí sa otočí spolu s obrazovým hľadiskom — divák sa „presunie“ na iné miesto
aj zvukom aj obrazom naraz, čo je konzistentné.

Znamená to zároveň, že **yaw na kameru zo špecifikácie §8A.2.1 nie je automatický** —
ak by sa mal zvuk zarovnať do spoločnej sústavy, musíme to spraviť my.

Ak to tak je, má to zásadný dôsledok: **zvuk nie je samostatná vec, vezie sa v tých
istých štyroch streamoch.** Prepínač musí prelínať štyri zvukové kanály v tom istom
rytme ako štyri obrazové.

### 8A.2.1 Prelínanie a natočenie

Ambisonic je **lineárna reprezentácia**, takže sa prelína kanál po kanáli rovnako ako
obraz. Matematicky bez problému.

Pribúda ale **natočenie**: dve kamery mieria inam, takže ich osi X/Y nie sú v tom
istom rámci. Ak stitching dáva primárnu šošovku dopredu, musí sa rovnako pootočiť aj
zvukové pole — je to matica 3×3 na X/Y/Z, W ostáva. **Yaw na kameru je preto
v dátovom modeli**, rovnakou logikou ako delay na šošovku.

### 8A.3 Routing von a späť — cez CoreAudio, bez výrobcu

Aplikácia má **výber výstupného a vstupného CoreAudio zariadenia**, nič viac. Či za
ním bude MADI, Dante Virtual Soundcard, Ravenna, AES67, Blackhole alebo pult
Blackmagic Fairlight, sa rozhodne pri nasadení — appka o žiadnom z nich nemusí vedieť
a nepotrebuje žiadne SDK ani licenciu. ASIO na macOS neexistuje; CoreAudio je jeho
ekvivalent.

Zvuk ide von **po štvoriciach** (W X Y Z na kameru), spracuje sa externe a vráti sa
späť; vrátený signál sa enkóduje do výstupu do Vahany namiesto pôvodného.

**Kanálový rozpočet:** 24 kamier × 4 kanály = **96 kanálov**, čo sa do bežných 64
nezmestí. Von preto ide **výber** — štandardne program, preview a čokoľvek v sóle.

### 8A.3 Monitoring

Úrovne na kameru, sólo na počúvanie jednej. Zdroj monitoringu je štandardne kamera
na programe.

**Klip sa signalizuje blikajúcou jantárovou, nie červenou** — červená je vyhradená
pre živé stavy (na programe, nahráva sa) a to pravidlo sa neporušuje ani pri zvuku.

### 8A.4 Výstupný delay — a prečo je to iná vec

Zvuk poslaný von na spracovanie sa vracia neskôr, než odišiel. Ak obraz medzitým beží
ďalej, rozíde sa to.

Preto má výstup **vlastný nastaviteľný delay, zvlášť na obraz a zvlášť na zvuk**.

V systéme sú tým pádom **dva rôzne delaye na dvoch rôznych miestach** a nesmú sa
zlepiť do jedného:

| | Kde | Čo zarovnáva |
|---|---|---|
| **Vstupný** (6.) | na kameru | kamery voči sebe — rozptyl, rozchádzanie kryštálov |
| **Výstupný** (8A.4) | na programe | obraz voči zvuku na konci reťaze |

Obraz aj tak drží v kruhovom bufferi kvôli vstupnému delayu, takže výstupný nič
nového nestojí — ale musí byť v návrhu od začiatku.

Proxy nesie oneskorenie celej svojej cesty, takže je dobrý na monitoring. Zvuk pre
**živé mixovanie na pulte** musí ísť z programovej cesty, nie z proxy.

---

## 9. Čo aplikácia robí

| Oblasť | Rozsah |
|---|---|
| Objavovanie | Bonjour, priradenie slotu podľa sériového čísla |
| Kamery | štart/stop streamovania, stav, kalibračné súbory |
| Prepínanie | preview, take, prelínačka, delay |
| Multiview | mriežka podľa počtu nájdených kamier, výber šošovky |
| Nahrávanie | štart/stop, stav nodov, voľné miesto |
| MIDI | učenie väzieb (stlač pad), nie ručné čísla nôt |
| Nody | pridávanie, priradenie kamier, zdravie |
| Diagnostika | stav celej cesty — kde to viazne |

### 9.1 Farba znamená stav

Žiadna dekoratívna akcentová farba. Červená je vysielané, zelená pripravené, jantárová
vyžaduje pozornosť, sivá nečinné. Rovnaká disciplína ako tally svetlá na réžijnom pulte
— práve preto môže červený rám znamenať **na programe** a nič iné.

---

## 10. Čo treba zmerať, keď bude hardvér

1. Skutočný dátový tok na kameru (odhad 40–80 Mbit/s) → potvrdiť dimenzovanie siete
2. Posun medzi kamerami — jednotky ms alebo stovky? Rozhoduje, či je delay drobnosť
3. Posun medzi šošovkami a či kopíruje rozdelenie na dva SoC
4. Koľko proxy streamov utiahne node súčasne
5. Réžia FFmpeg streamcopy rúry tam aj späť
6. Že Vahana prijme náš enkódovaný stream (riziko nízke, cesta je zdokumentovaná)

---

## 11. Rozhodnutia a prečo

| Rozhodnutie | Dôvod |
|---|---|
| Kamery publikujú na node | cez Mac by pri 24 kamerách tieklo 2–4 Gbit/s |
| Slot podľa sériového čísla | poradie objavenia sa medzi spusteniami mení |
| Preview + Take | tesnejší sync prechodu a stále len 2 dekódy |
| Vlastný prepínač namiesto OBS | prepína sa štvorica; štyri procesy sa nedohodnú na okamihu |
| FFmpeg len ako streamcopy rúra | odpadá písanie RTMP, cena je zlomok jadra |
| Proxy na nodoch | 24 plných dekódov na Macu je zbytočných |
| MKV na nahrávky | prežije výpadok napájania |
| Delay v modeli aj na šošovku | doplniť teraz nestojí nič, dorábať neskôr veľa |

### Prečo nakoniec nie OBS

OBS bolo dobrou voľbou a dlho vyzeralo ako správna odpoveď — má preview, prelínačku
aj delay na vstupy. Rozhodli tri veci:

1. Prepína sa **štvorica**, a štyri samostatné procesy s vlastnými hodinami sa na
   spoločnom okamihu nedohodnú. Nie je to chyba nastavenia, je to štrukturálne.
2. Prepínaciu logiku píšeme tak či tak — OBS ju len vykonáva.
3. 24 kamier × 4 inštancie = **96 scén** na ručnú správu.

OBS zostáva ako záloha, kým vlastný prepínač nie je overený. Nič sa ním nezatvára.

---

## 12. Postup

| Fáza | Obsah | Stav |
|---|---|---|
| 0 | Protokol kamery, objavovanie, riadenie | **hotové, otestované** |
| 1 | Špecifikácia | tento dokument |
| 2 | UX — návrh na odsúhlasenie | prekresliť podľa tejto špecifikácie |
| 3 | Prototyp: FFmpeg streamcopy rúra | čaká na hardvér |
| 4 | Nody: proxy + dynamické priradenie kamier | |
| 5 | Prepínač: dekód, prelínačka, enkód | |
| 6 | Aplikácia | |

---

## 13. Zber nahrávok po akcii

Pri 12 nodoch sú nahrávky roztrúsené po dvanástich strojoch. Bez riešenia to znamená
obchádzať ich po akcii s diskom v ruke.

Aplikácia musí aspoň **ukázať, čo kde leží** — ktorá kamera, ktorý node, aké súbory,
aká veľkosť. Ďalším krokom je spustiť zber na jedno miesto. Nebolí to počas akcie,
bolí to deň po nej.

**Otvorené:** kam sa zbiera a kto to sťahuje.

---

## 14. Otvorené

- Zvuk do Vahany — z kamery na programe, alebo si to rieši pult sám? (viď 8A.4)
- Pomenovanie kamier podľa pozície, alebo stačia čísla?
- Druhá obrazovka — má na nej niečo bývať natrvalo?
- Generácia HP mini (procesor, NVMe) — určuje transkódovaciu kapacitu
- Zber nahrávok po akcii — cieľové úložisko
