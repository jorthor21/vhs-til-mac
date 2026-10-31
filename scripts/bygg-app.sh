#!/bin/bash
# Bygger «VHS til Mac.app» (universal: Apple Silicon + Intel) og en ZIP for distribusjon.
#
# Kjøres på en Mac med Xcode (eller Command Line Tools med Swift 5.9+),
# for eksempel automatisk i GitHub Actions. Sluttbrukeren trenger IKKE dette.
#
#   scripts/bygg-app.sh [versjon]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.2.0}"
BUILD="$(date +%Y%m%d%H%M)"
APP_NAME="VHS til Mac"
OUT="build"
APP="$OUT/$APP_NAME.app"

echo "==> Kjører C-enhetstester"
make -C Tests/c test

echo "==> Kompilerer (arm64 + x86_64, release)"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
BIN="$BIN_DIR/VHSTilMac"
test -x "$BIN" || { echo "Fant ikke binærfilen $BIN"; exit 1; }
echo "    Arkitekturer: $(lipo -archs "$BIN")"

echo "==> Setter sammen app-pakken"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VHSTilMac"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Lager ikon"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  s2=$((s*2))
  sips -z $s2 $s2 Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Legger ved lisenser og kildekode-informasjon"
mkdir -p "$APP/Contents/Resources/Lisenser"
cp LICENSE "$APP/Contents/Resources/Lisenser/VHS-til-Mac-GPL-2.0.txt"
cp Sources/CLibUSB/COPYING "$APP/Contents/Resources/Lisenser/libusb-LGPL-2.1.txt"
cp TREDJEPARTS-LISENSER.md "$APP/Contents/Resources/Lisenser/"

echo "==> Ad-hoc-signerer (ikke Apple-notarisert)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP"

echo "==> Sjekker at appen ikke er avhengig av Homebrew eller andre eksterne biblioteker"
if otool -L "$APP/Contents/MacOS/VHSTilMac" | grep -E "/opt/homebrew|/usr/local|libusb" ; then
  echo "FEIL: binærfilen lenker mot et eksternt bibliotek"; exit 1
fi
otool -L "$APP/Contents/MacOS/VHSTilMac"

echo "==> Pakker ZIP"
ZIP="$OUT/VHS-til-Mac-$VERSION.zip"
rm -f "$ZIP"
cp LES_MEG.md "$OUT/LES MEG.md"
( cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$(basename "$ZIP")" && zip -q "$(basename "$ZIP")" "LES MEG.md" )
echo "Ferdig: $ZIP"
