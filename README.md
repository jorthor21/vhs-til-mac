# VHS til Mac

En egen macOS-app (Swift/SwiftUI) som tar opp video og lyd fra **Somagic ezcap Video Grabber,
USB-ID `1c88:1001`** – uten Homebrew, FFmpeg, Python, Terminal, kjerneutvidelser eller Windows.

Brukerveiledning: se [`LES_MEG.md`](LES_MEG.md).

---

## Ærlig status

Appen er **ikke testet med den fysiske adapteren**. Den er bygget på dokumentert protokollkunnskap,
og det finnes gode grunner til å tro at den virker (se «Hvorfor dette bør virke»).
Status per del:

| Del | Status | Hvordan den er verifisert |
|---|---|---|
| Finne adapteren, lese hele USB-beskrivelsestreet, tilgangstest | **Implementert** | Kompilert og kjørt mot libusb på Linux (uten enhet tilkoblet). |
| Initialisering og isokron strømming (SMI2021-protokollen) | **Implementert, ikke testet på enheten** | Følger SMI2021-kjernedriveren og easycap-somagic, som begge bygger på USB-logger fra Windows-driveren. |
| Rammebygging: BT.656 → 720×576 / 720×480 UYVY, felt, resynk | **Implementert og enhetstestet** | 7 tester med syntetiske strømmer (PAL, NTSC, byttede felt, pakketap). Alle består. |
| Signaldeteksjon (dekoderens statusregister 0x1F) | **Implementert, ikke testet på enheten** | Samme tolkning som Linux-driveren `saa7115`. |
| Lyd fra adapteren (32-bit, 48 kHz stereo) | **Eksperimentell** | Formatet er hentet fra kjernedriveren og enhetstestet med syntetiske data. En Linux-bruker rapporterte problemer med kombinert lyd og bilde på `1001`, så dette er det mest usikre punktet. Appen varsler alltid hvis lyd mangler. |
| Deinterlacing (kamdeteksjon) | **Implementert og enhetstestet** | |
| Forhåndsvisning, MP4 (H.264/AAC), ProRes-arkiv, historikk, diagnosepakke | **Implementert, ikke kompilert ennå** | Swift-koden er syntakssjekket og gjennomgått manuelt for typefeil, men ikke kompilert. Det krever en Mac eller en macOS-byggemaskin (se under). |
| Signering | Ad-hoc-signert, **ikke notarisert** | Krever betalt Apple Developer-konto. |

### Hvorfor dette bør virke
- Beskrivelsene som andre har publisert for `1c88:1001` er identiske med SMI2021-familien:
  grensesnitt 0 (leverandørspesifikt) med 3 alternative innstillinger, og alt 2 = isokront endepunkt
  `0x82` INN, `wMaxPacketSize 0x1400` (3 × 1024 byte per mikroramme). Det er nøyaktig det
  SMI2021-kjernedriveren sjekker før den tar en enhet i bruk.
- I [EasyCap issue #1](https://github.com/stephenlacy/EasyCap/issues/1) rapporterer flere brukere at
  `1c88:1001` **leverer video uten firmware-opplasting** med den åpne SMI2021-protokollen.
  Hos dem var problemet at Linux' HID-driver holdt grensesnitt 1. Den situasjonen oppstår ikke
  her: appen bruker bare grensesnitt 0 og rører verken HID-grensesnittet eller konfigurasjonen.
- Grensesnitt 0 har ingen macOS-driver. Derfor kan en vanlig app gjøre krav på det via IOKit
  (gjennom libusb) uten kjerneutvidelse og uten spesielle rettigheter.
- libusb støtter isokrone overføringer på macOS (`ReadIsochPipeAsync`).

### Det som fortsatt er usikkert
1. Om macOS slipper gjennom kontrollforespørsler til en enhet der HID-grensesnittet eies av systemet.
   libusb sender dem som standard enhetsforespørsler. Det skal virke, men er ikke bekreftet.
2. Om isokrone høybåndbredde-overføringer (3 × 1024 byte) går stabilt gjennom USB-hubene dine.
3. Lydformatet når lyd og bilde går samtidig på akkurat denne varianten.
4. Hvilken kompositt-kanal (`MODE 0–5` i dekoderen) som er koblet til den gule pluggen på ezcap-varianten.
   Standard er 0, og diagnoseknappen «Finn inngang med signal» prøver alle.

Diagnosen i appen er laget for å svare på nøyaktig disse spørsmålene (se «Testresultater»).

---

## Få en ferdig `.app`

Selve appen trenger ingenting installert. Den må bare **kompileres én gang på en Mac-byggemaskin**.
Det gjøres automatisk og gratis med GitHub Actions (Apples byggemaskiner hos GitHub):

**Alternativ A – jeg gjør det:** koble GitHub-kontoen din til Claude
(claude.ai → Innstillinger → Connectors → GitHub), lag et tomt repo og si fra. Da laster jeg opp
koden, kjører byggingen, retter eventuelle kompileringsfeil og gir deg ZIP-filen.

**Alternativ B – selv, uten Terminal:**
1. Lag en gratis konto på github.com og et nytt **privat** repo, f.eks. `vhs-til-mac`.
2. «Add file → Upload files»: dra inn **innholdet** i prosjektmappen. Mappen `.github` er skjult i
   Finder; trykk **⌘⇧.** (Cmd+Shift+punktum) for å vise den, og ta den med.
3. Gå til fanen **Actions**. Byggingen «Bygg VHS til Mac» starter av seg selv (ca. 5 min).
4. Åpne den fullførte kjøringen, last ned **VHS-til-Mac** under *Artifacts* og pakk ut.

**Alternativ C – har du Xcode:** `scripts/bygg-app.sh` (gir `build/VHS-til-Mac-<versjon>.zip`).

Byggeskriptet kjører C-enhetstestene, kompilerer for både Apple Silicon og Intel, lager ikon,
legger ved lisenser, ad-hoc-signerer og kontrollerer med `otool` at appen ikke lenker mot noe
utenfor macOS.

Minstekrav: macOS 12 Monterey. Apple Silicon og Intel.

---

## Testresultater – slik hjelper du meg å rette det som gjenstår

Gjør dette med adapteren koblet til og kameraet i avspilling:

1. Åpne appen og vent 5 sekunder. Ta et **skjermbilde** av hele vinduet.
2. Fanen **Diagnose** → **1. Les USB-beskrivelser** → **2. Test videostrømmen (5 s)**.
3. Hvis du ikke får bilde: **3. Finn inngang med signal**.
4. **Lagre diagnosepakke …** → velg Skrivebord. Det lages en ZIP-fil.
5. Send meg ZIP-filen og skjermbildet. Fortell også:
   - macOS-versjon (Apple-menyen → Om denne Macen) og om det er Apple Silicon eller Intel
   - om adapteren sto direkte i Mac-en eller i en hub
   - om du så bilde/hørte lyd, og eventuelle feilmeldinger

ZIP-filen inneholder `rapport.txt` (beskrivelser, tellere og dekoderregistre), `logg.txt`
(alle USB-steg med eventuelle feilkoder), `stillbilde.png` og `usb-raadata.bin`
(de første ~6 MB av den isokrone strømmen). Med dette kan jeg se om feilen ligger i tilgang,
initialisering, båndbredde, rammeformat eller lyd, og rette koden målrettet.

**Hvis appen ikke starter i det hele tatt:** ta skjermbilde av feilmeldingen, og fortell
hvilken macOS-versjon du har.

---

## Teknisk oversikt

```
Sources/
  CLibUSB/       libusb 1.0.27 (LGPL-2.1), kompileres statisk inn – ingen Homebrew
  SMICore/       C: protokoll, rammebygging, lyd, deinterlacing (portabel, testbar)
    smi_usb.c      init, isokron strømming, dekoderregistre, diagnose
    smi_parser.c   0x400-blokker → BT.656 → UYVY-rammer + PCM-lyd
    smi_image.c    deinterlacing, luma-statistikk
  VHSTilMac/     Swift/SwiftUI-app
    Capture/       CaptureEngine: USB-kø, status, CVPixelBuffer, diagnose
    Recording/     AVAssetWriter: MP4 (H.264+AAC) og MOV (ProRes 422 + 24-bit PCM)
    Audio/         lyttemodus (AVAudioEngine), alternativ Mac-lydinngang
    Model/, Views/ innstillinger, historikk, logg, brukergrensesnitt
Tests/c/         enhetstester for C-kjernen (make -C Tests/c test)
Tools/smi-diag.c kommandolinje-diagnose for utviklere (Linux/macOS)
```

### Protokollen (kort)
| Steg | USB |
|---|---|
| Kontrollforespørsel | `bmRequestType 0x40`, `bRequest 0x01`, `wValue 0x0b`, `wIndex 0` |
| SMI-register | data `0b 00 00 82 01 RR RR VV` |
| Dekoder-register (I²C 0x4a) | data `0b 4a c0 01 01 RR VV 00`; lesing via `0x84` → `0xa0` → IN 13 byte |
| Init | SMI-porter `3a/3b/34/35`, ca. 50 dekoderregistre (PAL/NTSC, inngang, AGC, VREF) |
| Start | modus `01 05`, `SET_INTERFACE alt 2`, lyd `0x1740=0x1d`, send isokrone overføringer, `0x1800=0x0d` |
| Data | EP `0x82` isokron, 3072 byte/mikroramme = 3 blokker à 0x400 |
| Blokk | `AA AA 00 00` + 1020 byte BT.656-video, eller `AA AA 00 01` + 1020 byte lyd |
| Video | `FF 00 00 SAV` + 1440 byte UYVY per linje, felt-bit F, blanking-bit V |
| Lyd | S32LE stereo 48 kHz, laveste byte i hver sample = 0x00 (24 bit) |
| Stopp | modus `01 03`, alt 0 |

Kilder: [smi2021-kjernedriveren](https://github.com/jonjonarnearne/smi2021),
[easycap-somagic-linux](https://github.com/9ary/easycap-somagic-linux),
[bonybrown/easycap-somagic-linux](https://github.com/bonybrown/easycap-somagic-linux),
[EasyCap issue #1 (1c88:1001)](https://github.com/stephenlacy/EasyCap/issues/1),
[easycap-somagic-linux issue #27](https://github.com/pimartos/easycap-somagic-linux/issues/27).

### Synkronisering av lyd og bilde
Bildene nummereres fortløpende (25 eller 29,97 per sekund). Hvis USB mister bilder, fylles
hullet med forrige bilde, slik at lengden stemmer. Lyd tidsstemples etter antall sampler,
forankret i Mac-ens klokke, og justeres bare fremover hvis det oppstår hull.

### Hva Windows-arkivet inneholdt
`1. VHS.zip` inneholder ArcSoft TotalMedia ShowBiz/Studio (generisk DirectShow-opptak) og en
snarvei til enheten. **Selve ezcap-driveren (`.sys`/`.inf`) ligger ikke i arkivet.** Den hadde
uansett ikke vært nødvendig: `1c88:1001` trenger ikke firmware-opplasting. Ingen filer fra
arkivet er brukt.

## Lisens
GPL-2.0-or-later. Se [`TREDJEPARTS-LISENSER.md`](TREDJEPARTS-LISENSER.md).
