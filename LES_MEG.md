# VHS til Mac – brukerveiledning

Digitaliser VHS-opptak fra videokameraet med **ezcap Video Grabber** (Somagic, USB-ID `1c88:1001`).
Ingen Homebrew, Terminal, drivere eller Windows trengs.

## 1. Installer
1. Pakk ut ZIP-filen (dobbeltklikk).
2. Dra **VHS til Mac** til **Programmer**-mappen.
3. Første gang: dobbeltklikk appen. macOS sier at den ikke kan bekrefte utvikleren, fordi
   appen ikke er notarisert av Apple (det krever et betalt utviklerabonnement).
   - Åpne **Systeminnstillinger → Personvern og sikkerhet**, rull ned og trykk **Åpne likevel**
     ved meldingen om «VHS til Mac». Bekreft med passord/Touch ID.
   - På eldre macOS (12–14) kan du i stedet høyreklikke appen → **Åpne** → **Åpne**.
   Dette trengs bare én gang.

Appen trenger ingen kjerneutvidelse og ingen endringer i sikkerhetsinnstillingene utover dette.
Den eneste tillatelsen den kan be om, er **mikrofon** – og bare hvis du velger
«Annen lydinngang på Mac-en» som lydkilde.

## 2. Koble til
1. Koble adapteren til Mac-en. **Helst direkte**, uten hub: adapteren trenger mye
   USB 2.0-båndbredde. Bruk en enkel USB-C-til-USB-A-overgang ved behov.
2. Kamera → adapter:
   - **Gul** RCA: kameraets VIDEO OUT → adapterens gule plugg (kompositt).
   - **Rød/hvit** RCA: kameraets AUDIO OUT → adapterens røde/hvite plugger.
   - Har kameraet **S-Video**-utgang, gir den skarpere farger. Velg da S-Video i appen.
3. Når adapteren kobles til første gang, kan macOS vise **Tastaturoppsett-assistenten**
   («Kan ikke identifisere tastaturet»). Adapteren har en «stillbilde-knapp» som macOS tror
   er et tastatur. Bare lukk vinduet.

## 3. Bruk
1. Åpne appen. Statusfeltet øverst viser fire nivåer:
   - **USB-adapter** – er adapteren funnet?
   - **Videostrøm** – sender adapteren data?
   - **Videosignal** – ser adapteren et bilde fra kameraet?
   - **Lyd** – kommer det lyd?
2. Start avspilling på kameraet. Bildet vises i appen.
3. Trykk **Start opptak** (eller ⌘R). Trykk **Stopp opptak** når du er ferdig.
4. Filene lagres i **Filmer → VHS-opptak** med dato og klokkeslett i navnet, for eksempel
   `VHS 2026-10-31 kl. 15.42.07.mp4`. Eksisterende filer blir aldri overskrevet.
5. **Åpne opptaksmappe** viser filene. Fanen **Historikk** viser tidligere opptak og størrelser.

### Innstillinger
- **Inngang:** Kompositt (gul) eller S-Video.
- **TV-standard:** PAL for norske/europeiske opptak, NTSC for amerikanske/japanske.
- **Kvalitet:** MP4 med H.264. «Høy» passer for VHS (ca. 3,2 GB per time).
- **Arkivkopi:** lagrer i tillegg en uendret, linjeflettet kopi i ProRes 422 med 24-bit lyd
  (ca. 18 GB per time). Fin hvis du vil redigere eller lagre originalen for fremtiden.
- **Lyd:** fra adapteren, fra en annen lydinngang på Mac-en, eller ingen lyd.
  Appen varsler hvis valgt lydkilde ikke leverer lyd – den lagrer aldri stille uten å si fra.
- **Bilde:** lysstyrke, kontrast, fargemetning og fargetone justeres direkte i adapteren.

## 4. Hvis noe ikke virker
Gå til fanen **Diagnose**:
1. **Les USB-beskrivelser** – kun lesing; viser hvordan Mac-en ser adapteren.
2. **Test videostrømmen (5 s)** – måler data, synk, bilder og lyd.
3. **Finn inngang med signal** – prøver alle innganger og velger den som har bilde.
4. **Lagre diagnosepakke …** – lager en ZIP med rapport, logg, et stillbilde og et kort
   utdrag av rå USB-data. Send ZIP-filen til den som hjelper deg. Pakken inneholder ikke
   brukernavn, filstier til dine filer eller serienumre.

| Melding | Hva du kan gjøre |
|---|---|
| *Ikke funnet* | Koble til på nytt, prøv en annen port, unngå hub. |
| *Kunne ikke åpne/starte … opptatt* | Lukk andre programmer som kan bruke adapteren (f.eks. OBS), koble fra og til. |
| *for lite USB-båndbredde* | Koble adapteren direkte til Mac-en. |
| *Ingen videosignal* | Kameraet må stå i avspillingsmodus (VCR/PLAY) og spille. Sjekk den gule kabelen, eller bruk «Finn inngang med signal». |
| *Signalet er NTSC/PAL – bytt TV-standard* | Bytt TV-standard under Innstillinger. |
| *Adapteren sender ikke lyd* | Sjekk rød/hvit kabel. Fungerer det fortsatt ikke: velg en annen lydinngang på Mac-en. |
| Bevegelser ser stripete/hakkete ut | Innstillinger → Avansert → «Bytt rekkefølge på halvbilder». |
