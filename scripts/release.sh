#!/bin/zsh
# Prépare une version PUBLIABLE de Khanjar, sans rien publier :
#   dist/release/<version>/Khanjar-<version>.zip   (l'app, signée EdDSA pour Sparkle)
#   dist/release/<version>/appcast.xml             (le flux que lisent les apps installées)
#
# Prérequis, une seule fois :
#   swift scripts/sparkle-keygen.swift              → ~/.config/khanjar/sparkle-ed25519.{key,pub}
#   echo "<compte>/khanjar" > ~/.config/khanjar/repo
#
# Les apps installées lisent https://github.com/<compte>/khanjar/releases/latest/download/appcast.xml :
# publier = créer une release GitHub « v<version> » avec CES DEUX fichiers (commande affichée à la fin).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${KHANJAR_CONFIG_DIR:-$HOME/.config/khanjar}"   # surchargeable pour les tests
KEY="$CONF/sparkle-ed25519.key"
[[ -f "$KEY" && -f "$CONF/sparkle-ed25519.pub" ]] || { echo "Clé absente : lance d'abord  swift scripts/sparkle-keygen.swift" >&2; exit 1; }
[[ -f "$CONF/repo" ]] || { echo "Dépôt inconnu : echo \"<compte>/khanjar\" > $CONF/repo" >&2; exit 1; }
REPO=$(tr -d ' \n' < "$CONF/repo")

"$ROOT/scripts/build-app.sh"
APP="$ROOT/dist/Khanjar.app"
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" >/dev/null 2>&1 || {
  echo "Refusé : l'app construite n'a pas les mises à jour activées." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")

OUT="$ROOT/dist/release/$VERSION"
rm -rf "$OUT"; mkdir -p "$OUT"
ZIP="$OUT/Khanjar-$VERSION.zip"
# ditto garde les liens symboliques et la signature du paquet (zip les casserait).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SIGN="$ROOT/helper/Vendor/sparkle-bin/sign_update"
SIG=$("$SIGN" -f "$KEY" -p "$ZIP")
"$SIGN" --verify -f "$KEY" "$ZIP" "$SIG" >/dev/null
LENGTH=$(stat -f%z "$ZIP")
URL="https://github.com/$REPO/releases/download/v$VERSION/Khanjar-$VERSION.zip"
DATE=$(LC_ALL=en_US.UTF-8 date -u "+%a, %d %b %Y %H:%M:%S +0000")

# Notes de version affichées par Sparkle : docs/release-notes/<version>.html si présent.
NOTES_FILE="$ROOT/docs/release-notes/$VERSION.html"
if [[ -f "$NOTES_FILE" ]]; then NOTES=$(cat "$NOTES_FILE")
else NOTES="<p>Khanjar $VERSION — <a href=\"https://github.com/$REPO/releases/tag/v$VERSION\">release notes</a></p>"; fi

cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Khanjar</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Khanjar $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <description><![CDATA[$NOTES]]></description>
      <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIG"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT/appcast.xml"

echo "OK : Khanjar $VERSION prêt dans $OUT (rien n'est publié)"
echo "Publier (après relecture) :"
# PAS --prerelease : le lien « releases/latest/download/appcast.xml » que lisent les apps
# installées ignore les pré-versions — marquer une version ainsi la rendrait invisible
# aux mises à jour. La bêta se lit dans le titre.
echo "  gh release create v$VERSION \"$ZIP\" \"$OUT/appcast.xml\" --repo $REPO --title \"Khanjar $VERSION (beta)\" --latest"
