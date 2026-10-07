#!/bin/zsh
# Construit Khanjar.app (release) : binaire + ccx embarqué + Info.plist,
# signature ad hoc (Developer ID + notarisation : étape distribution, cf. M6).
# Sortie : dist/Khanjar.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Khanjar.app"
PLUGIN_VERSION=$(python3 -c "import json;print(json.load(open('$ROOT/plugin/manifest.json'))['version'])")
# Version de l'APP native — découplée du plugin (le plugin ne change pas à
# chaque évolution de l'UI/app ; éviter un réinstall inutile du ccx).
APP_VERSION="0.8.3"

# 0. Traductions : chaque texte L("…") du code doit avoir sa version française.
python3 "$ROOT/scripts/check-l10n.py"

# 0bis. Sparkle (mises à jour automatiques) : récupéré et vérifié s'il manque.
"$ROOT/scripts/fetch-sparkle.sh"

# 1. Plugin (ccx à jour)
"$ROOT/scripts/build-plugin.sh"

# 2. Binaire release. NOTE : arm64 seulement (Apple Silicon). Le build UNIVERSEL
#    (arm64+x86_64 pour couvrir les Mac Intel) exige Xcode COMPLET — cette machine
#    n'a que les Command Line Tools, et `swift build --arch` échoue alors sur
#    xcbuild. Amis ciblés = tous Apple Silicon → suffisant. Pour un ami Intel :
#    installer Xcode puis rétablir `--arch arm64 --arch x86_64` (binaire sous
#    .build/apple/Products/Release/).
cd "$ROOT/helper"
swift build -c release
BIN="$ROOT/helper/.build/release/khanjar"

# 3. Bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Khanjar"
cp "$ROOT/plugin/dist/khanjar-executor.ccx" "$APP/Contents/Resources/"
# ditto, pas cp : le framework contient des liens symboliques (Versions/Current).
ditto "$ROOT/helper/Vendor/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Langues de l'interface : anglais par défaut, français si le Mac est en français.
cp -R "$ROOT/helper/Resources/en.lproj" "$ROOT/helper/Resources/fr.lproj" "$APP/Contents/Resources/"

# Rapports de plantage : adresse d'envoi (DSN Sentry) lue sur la machine qui
# construit, JAMAIS commitée (dépôt public). Sans elle, la case n'est pas proposée.
SENTRY_DSN="${KHANJAR_SENTRY_DSN:-}"
CONF="${KHANJAR_CONFIG_DIR:-$HOME/.config/khanjar}"   # surchargeable pour les tests
[[ -z "$SENTRY_DSN" && -f "$CONF/sentry-dsn" ]] && SENTRY_DSN=$(tr -d ' \n' < "$CONF/sentry-dsn")
CRASH_KEY=""
if [[ -n "$SENTRY_DSN" ]]; then
  [[ "$SENTRY_DSN" =~ '^https://[^@]+@[^/]+/[0-9]+$' ]] || { echo "DSN Sentry invalide : $SENTRY_DSN" >&2; exit 1; }
  CRASH_KEY="	<key>KhanjarCrashReportDSN</key><string>$SENTRY_DSN</string>"
  echo "Rapports de plantage : activés (DSN présent)"
else
  echo "Rapports de plantage : désactivés (pas de DSN — case non proposée)"
fi

# Mises à jour : adresse du flux (versions publiées sur GitHub) et clé PUBLIQUE de
# signature, lues sur la machine qui construit. Sans elles, les mises à jour sont
# éteintes (build local) et le menu ne propose rien.
REPO="${KHANJAR_REPO:-}"
[[ -z "$REPO" && -f "$CONF/repo" ]] && REPO=$(tr -d ' \n' < "$CONF/repo")
ED_PUB="${KHANJAR_SPARKLE_PUBLIC_KEY:-}"
[[ -z "$ED_PUB" && -f "$CONF/sparkle-ed25519.pub" ]] && ED_PUB=$(tr -d ' \n' < "$CONF/sparkle-ed25519.pub")
UPDATE_KEYS=""
if [[ -n "$REPO" && -n "$ED_PUB" ]]; then
  [[ "$REPO" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] || { echo "Dépôt invalide : $REPO (attendu compte/nom)" >&2; exit 1; }
  FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
  UPDATE_KEYS="	<key>SUFeedURL</key><string>$FEED</string>
	<key>SUPublicEDKey</key><string>$ED_PUB</string>"
  echo "Mises à jour : activées ($FEED)"
else
  echo "Mises à jour : désactivées (pas de dépôt ou de clé — voir scripts/release.sh)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Khanjar</string>
	<key>CFBundleIdentifier</key><string>io.khanjar.app</string>
	<key>CFBundleName</key><string>Khanjar</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
	<key>NSDocumentsFolderUsageDescription</key><string>Khanjar reads your Premiere Pro effect presets, which are stored in your Documents folder.</string>
	<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
	<key>CFBundleVersion</key><string>$APP_VERSION</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>KhanjarPluginVersion</key><string>$PLUGIN_VERSION</string>
$CRASH_KEY
$UPDATE_KEYS
</dict>
</plist>
PLIST

# 4. Signature ad hoc (suffisant en local ; Developer ID pour distribuer).
#    --deep re-signe aussi Sparkle et ses outils internes (Autoupdate, Updater.app,
#    XPC) : tout le paquet porte alors la même signature ad hoc.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "OK : $APP v$APP_VERSION (plugin v$PLUGIN_VERSION embarqué)"
echo "Lancement : open '$APP'   ·   Login item : Réglages Système > Ouverture"