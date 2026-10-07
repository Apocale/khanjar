#!/bin/zsh
# Récupère Sparkle (mises à jour automatiques) dans helper/Vendor/, jamais commité.
# Version et empreinte ÉPINGLÉES : un fichier différent de celui publié par les
# auteurs de Sparkle est refusé. Sans rien à faire si la bonne version est déjà là.
#
#   scripts/fetch-sparkle.sh            (télécharge depuis github.com/sparkle-project)
#   SPARKLE_TARBALL=<fichier.tar.xz> scripts/fetch-sparkle.sh   (archive déjà téléchargée)
#
# Produit :
#   helper/Vendor/Sparkle.xcframework   → lié par Package.swift (binaryTarget)
#   helper/Vendor/sparkle-bin/          → sign_update, generate_appcast (scripts/release.sh)
set -euo pipefail

VERSION="2.10.0"
SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"   # publié par GitHub pour Sparkle-2.10.0.tar.xz
URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/helper/Vendor"
MARKER="$VENDOR/.sparkle-version"
[[ -f "$MARKER" && "$(cat "$MARKER")" == "$VERSION" && -d "$VENDOR/Sparkle.xcframework" ]] && exit 0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
TARBALL="${SPARKLE_TARBALL:-$WORK/Sparkle-$VERSION.tar.xz}"
if [[ -z "${SPARKLE_TARBALL:-}" ]]; then
  echo "Téléchargement de Sparkle $VERSION…"
  curl -sSfL --max-time 300 -o "$TARBALL" "$URL"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c --quiet || {
  echo "Refusé : l'empreinte de $TARBALL ne correspond pas à Sparkle $VERSION publié." >&2; exit 1; }
tar -xf "$TARBALL" -C "$WORK"

# L'archive fournit Sparkle.framework ; SwiftPM attend un .xcframework. Sans Xcode
# (Command Line Tools seuls), xcodebuild -create-xcframework est indisponible : on
# écrit l'enveloppe à la main (un Info.plist + le framework intact, signature d'origine).
rm -rf "$VENDOR/Sparkle.xcframework" "$VENDOR/sparkle-bin"
XCF="$VENDOR/Sparkle.xcframework"
mkdir -p "$XCF/macos-arm64_x86_64" "$VENDOR/sparkle-bin"
ditto "$WORK/Sparkle.framework" "$XCF/macos-arm64_x86_64/Sparkle.framework"
cat > "$XCF/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>LibraryIdentifier</key><string>macos-arm64_x86_64</string>
			<key>LibraryPath</key><string>Sparkle.framework</string>
			<key>SupportedArchitectures</key><array><string>arm64</string><string>x86_64</string></array>
			<key>SupportedPlatform</key><string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key><string>XFWK</string>
	<key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
PLIST
cp "$WORK/bin/sign_update" "$WORK/bin/generate_appcast" "$VENDOR/sparkle-bin/"
cp "$WORK/LICENSE" "$VENDOR/Sparkle-LICENSE"
echo "$VERSION" > "$MARKER"
echo "OK : Sparkle $VERSION dans $VENDOR"
