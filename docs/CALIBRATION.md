# Kalibrácia — čo to je a ako sa počíta

Zistené čítaním zdrojov [stitchEm](https://github.com/stitchEm/stitchEm),
`lib/src/calibration/`. Otázka vznikla preto, že dva kusy z fleetu nemajú
`factoryPresetsProject.ptv` a staršia Vahana ich vraj spustila, novšia nie.

---

## Čo v tom súbore je

`factoryPresetsProject.ptv` je meranie **konkrétneho kusa** — ako presne sedia
jeho štyri šošovky voči sebe. Na kameru sa zapisuje pri výrobe. Pre každú
šošovku obsahuje:

| | |
|---|---|
| `yaw`, `pitch`, `roll` | natočenie šošovky voči referenčnej |
| `crop_left/right/top/bottom` | použiteľný kruh obrazu |
| ohnisko, stred, skreslenie | optika šošovky |

Šošovka `0_0` je referenčná — na všetkých dvanástich porovnaných kusoch má
presne rovnaké uhly (0, −18, −90). Rozdiely medzi kusmi sú v ostatných troch,
a sú väčšie, než sa zdalo — [M9](MEASUREMENTS.md) meria rozptyl **53,8 px**
na 4096 px panoráme.

---

## Ako sa počíta

`Calibration::process` v `lib/src/calibration/calibration.cpp`:

```
extractAndMatchControlPoints   nájde významné body v každom obraze a spáruje
                               ich medzi šošovkami, ktoré sa prekrývajú
calculateFOV                   dopočíta zorný uhol, ak nie je zadaný
filterControlPoints            vyhodí páry, ktoré nesedia
estimateExtrinsics             z párov odhadne natočenie každej šošovky
optimize                       bundle adjustment — zjemní všetko naraz
```

Počíta sa teda **z obrazu**, nie z čohokoľvek uloženého v kamere. Kamera bez
kalibračného súboru sa dá odmerať rovnako dobre ako ktorákoľvek iná — potrebuje
len obraz, z ktorého sa dá merať.

### Dve podmienky, bez ktorých to skončí chybou

**1. Rig preset ako východiskový odhad.** V kóde je to tvrdá podmienka:

```cpp
if (calibConfig.getRigPreset()->getRigCameraDefinitionCount() != (size_t)pano->numVideoInputs()) {
  return {..., "Calibration camera presets not matching the number of video inputs"};
}
```

Bez presetu sa algoritmus ani nespustí. Preset je hrubá geometria rigu — štyri
šošovky, kde asi ktorá je. Pre Orah 4i je mechanika u všetkých kusov rovnaká,
takže **ako preset poslúži `.ptv` z ktoréhokoľvek zdravého kusa**; v
`camera-records/` ich je štrnásť.

**2. Textúra v prekryvoch.** Celá metóda stojí na nájdení a spárovaní bodov
medzi susednými šošovkami. Holá stena, prázdna miestnosť alebo vnútro boxu
nedajú žiadne body — a algoritmus vráti chybu.

To je najpravdepodobnejšie vysvetlenie toho, prečo tie dva kusy „hodili error":
nekalibrovali sa v scéne, ktorá má na čom merať.

---

## Postup pre kameru bez kalibrácie

1. Kameru spustiť normálne — `orahctl start`, alebo aplikáciou. Streamuje aj bez
   kalibračného súboru; kamera 22 nahodila ako jediná z fleetu všetky štyri
   streamy naraz.
2. Vo VideoStitch Studiu otvoriť tie štyri vstupy.
3. Ako rig preset načítať `.ptv` z ktoréhokoľvek zdravého kusa
   (`camera-records/*.ptv`).
4. Kalibrovať **v scéne s textúrou** — nie holá stena, nie prázdny box.
   Členitý priestor, nábytok, ľudia, čokoľvek s hranami vo všetkých smeroch.
5. Výsledok exportovať algoritmom `calibration_presets_maker`, ktorý z
   kalibrovanej panorámy spraví preset — presne to, čo je obsahom `.ptv`.

Z príkazového riadku to nejde: v stitchEm sú len GUI aplikácie
(`videostitch-studio-gui`, `videostitch-live-gui`) a `batchstitcher`. Algoritmy
sú registrované pod menami `"calibration"` a `"calibration_presets_maker"`, takže
volateľné z knižnice sú — nástroj na to ale nikto nenapísal.

### Späť do kamery

Protokol vie súbor aj zapísať — `Fs.PUT`. Kamera by potom svoju kalibráciu
niesla so sebou ako ostatné kusy, čo je čistejšie než držať ju bokom.

Je to ale zápis do kamery a nie je overené, čo s ním firmvér spraví.
Neposielame ho, kým to nebude vedomé rozhodnutie — viď
[CAMERA-CAPABILITIES.md](CAMERA-CAPABILITIES.md).

---

## Prečo to staršia Vahana nepotrebovala

Nepotvrdené z kódu, ale sedí to s pozorovaním: staršia verzia zrejme používala
jednu spoločnú geometriu pre všetky Orah 4i a kalibráciu na kus nezaviedla.
Kusy bez súboru na nej preto bežali a na novšej sú označené ako chybné.

Čo to znamená prakticky: **tie kamery nie sú pokazené.** Chýba im meranie, ktoré
sa dá spraviť znova.
