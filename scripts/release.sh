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

# ── Garde-fous AVANT de construire (audit du 2026-10-08, A5#14) ──
# Relancer ce script sans monter la version remplaçait la copie locale d'une version
# déjà publiée par un autre build du même numéro ; Sparkle compare CFBundleVersion :
# les amis déjà à jour n'auraient jamais reçu le nouveau code.
PLANNED=$(/usr/bin/sed -n 's/^APP_VERSION="\(.*\)"/\1/p' "$ROOT/scripts/build-app.sh")
[[ -n "$PLANNED" ]] || { echo "APP_VERSION introuvable dans scripts/build-app.sh" >&2; exit 1; }
OUT="$ROOT/dist/release/$PLANNED"
[[ ! -e "$OUT" ]] || {
  echo "Refusé : $OUT existe déjà (version $PLANNED déjà préparée, peut-être publiée)." >&2
  echo "Monte APP_VERSION dans scripts/build-app.sh. Ne supprime ce dossier que si $PLANNED n'a JAMAIS été publiée." >&2
  exit 1; }
if command -v gh >/dev/null 2>&1 && gh release view "v$PLANNED" --repo "$REPO" >/dev/null 2>&1; then
  echo "Refusé : la release v$PLANNED existe déjà sur GitHub (publiée ou brouillon). Monte APP_VERSION." >&2
  exit 1
fi
# Version que voient les apps installées : celle du flux publié (sparkle:version = CFBundleVersion).
autoload -Uz is-at-least
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
PUBLISHED=$(curl -fsSL --max-time 30 "$FEED_URL" 2>/dev/null | /usr/bin/sed -n 's/.*<sparkle:version>\([^<]*\)<.*/\1/p' | head -1 || true)
if [[ -n "$PUBLISHED" ]]; then
  if ! is-at-least "$PUBLISHED" "$PLANNED" || [[ "$PLANNED" == "$PUBLISHED" ]]; then
    echo "Refusé : $PLANNED n'est pas supérieure à la version publiée $PUBLISHED. Monte APP_VERSION." >&2
    exit 1
  fi
  echo "Version publiée : $PUBLISHED → préparation de $PLANNED"
elif [[ "${KHANJAR_SKIP_PUBLISHED_CHECK:-}" == 1 ]]; then
  echo "⚠︎ Version publiée non vérifiée (KHANJAR_SKIP_PUBLISHED_CHECK=1)"
else
  echo "Refusé : impossible de lire la version publiée ($FEED_URL — réseau ?)." >&2
  echo "Première publication, ou vérification faite à la main : relance avec KHANJAR_SKIP_PUBLISHED_CHECK=1." >&2
  exit 1
fi

"$ROOT/scripts/build-app.sh"
APP="$ROOT/dist/Khanjar.app"
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" >/dev/null 2>&1 || {
  echo "Refusé : l'app construite n'a pas les mises à jour activées." >&2; exit 1; }
# Une app en quarantaine (fichier copié depuis un téléchargement par navigateur) la
# transmettrait à tous les amis via l'archive (ditto la restaure) : « Ouvrir quand
# même » reviendrait, même pour une installation par Claude Code (A5#15).
if xattr -lr "$APP" 2>/dev/null | grep -q com.apple.quarantine; then
  echo "Refusé : $APP porte com.apple.quarantine. Repars de sources propres (xattr -dr com.apple.quarantine sur le fichier fautif), puis relance." >&2
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
[[ "$VERSION" == "$PLANNED" ]] || { echo "Refusé : l'app construite annonce $VERSION, build-app.sh dit $PLANNED." >&2; exit 1; }

mkdir -p "$OUT"
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
echo "Publier (après relecture), dans cet ordre :"
# PAS --prerelease : le lien « releases/latest/download/appcast.xml » que lisent les apps
# installées ignore les pré-versions — marquer une version ainsi la rendrait invisible
# aux mises à jour. La bêta se lit dans le titre.
# Brouillon d'abord (audit du 2026-10-08, A5#14) : `gh release create … --latest` crée la
# release PUIS envoie les fichiers ; une coupure laissait une release « latest » sans
# appcast.xml, et toutes les vérifications de mise à jour tombaient en 404.
echo "  1. brouillon et fichiers :"
echo "     gh release create v$VERSION \"$ZIP\" \"$OUT/appcast.xml\" --repo $REPO --title \"Khanjar $VERSION (beta)\" --draft"
echo "  2. vérifier que les deux fichiers sont là (Khanjar-$VERSION.zip : $LENGTH octets ; appcast.xml) :"
echo "     gh release view v$VERSION --repo $REPO"
echo "  3. publier :"
echo "     gh release edit v$VERSION --repo $REPO --draft=false --latest"
echo "  4. contrôler ce que voient les apps installées (attendu : 200, puis $VERSION) :"
echo "     curl -sIL $FEED_URL | grep -iE '^(HTTP|location)'"
echo "     curl -fsSL $FEED_URL | grep shortVersionString"
