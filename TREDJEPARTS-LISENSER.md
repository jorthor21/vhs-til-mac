# Lisenser

## VHS til Mac
Lisens: **GNU General Public License v2.0 eller senere** (se `LICENSE`).

Appen er skrevet fra bunnen av. Kunnskapen om USB-protokollen (kontrollkommandoer,
registerverdier for SMI2021-brikken og GM7113C/SAA7113-videodekoderen, blokkformatet
`AA AA 00 00` / `AA AA 00 01` og lydformatet) er hentet fra disse GPL-lisensierte
prosjektene, som selv bygger på USB-logger fra Windows-driveren:

- **smi2021** Linux-kjernedriver – Jon Arne Jørgensen, Tony Brown, Michal Demin, Jeffry Johnston
  (https://github.com/jonjonarnearne/smi2021) – GPL-2.0-or-later
- **easycap-somagic-linux** – Tony Brown, Michal Demin, Jeffry Johnston, Jon Arne Jørgensen
  (https://github.com/9ary/easycap-somagic-linux, https://github.com/bonybrown/easycap-somagic-linux) – GPL-3.0-or-later for verktøyene

Ingen kode, firmware eller filer fra ArcSoft TotalMedia eller Windows-driveren er brukt.
Appen laster ikke opp firmware til adapteren.

## libusb 1.0.27
Lisens: **GNU Lesser General Public License v2.1** (se `Sources/CLibUSB/COPYING`).
Kompilert statisk inn i appen, uendret bortsett fra en håndskrevet `config.h`.
Hele kildekoden til appen og byggeskriptet (`scripts/bygg-app.sh`) følger med, slik at
hvem som helst kan bytte ut libusb og bygge appen på nytt, som LGPL 2.1 § 6 krever.
Opphavsrett: Daniel Drake, Johannes Erdfelt, Nathan Hjelm, Pete Batard, Hans de Goede
og andre bidragsytere (se `Sources/CLibUSB/AUTHORS`).

## Apple-rammeverk
AVFoundation, CoreMedia, CoreVideo, VideoToolbox (via AVFoundation), IOKit og SwiftUI
er en del av macOS og følger ikke med appen.

H.264- og ProRes-koding gjøres av macOS' innebygde kodere.

> Merk om GPL-versjon: easycap-somagic-verktøyene er lisensiert GPL-3.0-or-later, og
> kjernedriveren GPL-2.0-or-later. Fordi koden her er en uavhengig implementasjon basert på
> dokumentert protokollkunnskap, er den lisensiert GPL-2.0-or-later; distribusjon under
> GPL-3.0 er dermed også tillatt.
