#!/bin/zsh
# Construit le .ccx du plugin (zip des sources — ADR 0001), puis l'installe
# via UPIA si demandé (remove + install : une mise à jour ne recharge pas).
#
# Usage : ./scripts/build-plugin.sh [--dev] [--install]
#   --dev      inclut les commandes de harnais qui MODIFIENT Premiere (création
#              de projets de test, import, keyframes) — pour les modes CLI
#              multi-test / fidelity-test / anchor-test… JAMAIS pour une version
#              publiée : build-app.sh appelle ce script SANS --dev.
#   --install  installe le .ccx dans Premiere (chargement à chaud ~15 s).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="$ROOT/plugin"
DIST="$PLUGIN_DIR/dist"
CCX="$DIST/khanjar-executor.ccx"
UPIA="/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"
PLUGIN_NAME="Khanjar"
HELPER_URL="ws://localhost:48123"
# Règle réseau du manifeste : WebSockets locaux uniquement. Ni IP ni port (UXP
# refuse « ws://127.0.0.1:48123 » — mesuré le 2026-10-06, cf. AGENTS.md §3.1).
NETWORK_RULE="ws://localhost/"

DEV=false
INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --dev) DEV=true ;;
    --install) INSTALL=true ;;
    *) echo "Option inconnue : $arg (attendu : --dev, --install)"; exit 1 ;;
  esac
done

# Vérifications
for f in "$PLUGIN_DIR"/index.js "$PLUGIN_DIR"/src/**/*.js; do
  node --check "$f"
done
python3 -m json.tool "$PLUGIN_DIR/manifest.json" > /dev/null

# Garde-fou anti-désync de version (piège P1) : probe.js annonce la version dans
# le hello ; si elle diffère du manifeste, reconcile croit le plugin périmé et
# boucle en remove/install UPIA → blocage d'UPIA (§6). On refuse le build.
MANIFEST_V=$(python3 -c "import json;print(json.load(open('$PLUGIN_DIR/manifest.json'))['version'])")
PROBE_V=$(grep -oE 'PLUGIN_VERSION = "[0-9]+\.[0-9]+\.[0-9]+"' "$PLUGIN_DIR/src/env/probe.js" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
if [[ "$MANIFEST_V" != "$PROBE_V" ]]; then
  echo "ERREUR version désynchronisée : manifest.json=$MANIFEST_V ≠ probe.js=$PROBE_V"
  echo "→ corrige PLUGIN_VERSION dans plugin/src/env/probe.js pour qu'il vaille $MANIFEST_V"
  exit 1
fi

# Garde-fou réseau : le manifeste ne doit autoriser QUE le pont local.
DOMAINS=$(python3 -c "import json;print(json.load(open('$PLUGIN_DIR/manifest.json'))['requiredPermissions']['network']['domains'])")
if [[ "$DOMAINS" != "['$NETWORK_RULE']" ]]; then
  echo "ERREUR réseau : le manifeste autorise $DOMAINS — attendu uniquement ['$NETWORK_RULE']"
  exit 1
fi

# Copie de travail : build.js y est réécrit selon --dev, les sources ne
# changent jamais (rien à « oublier de remettre » avant de publier).
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$PLUGIN_DIR/manifest.json" "$PLUGIN_DIR/index.js" "$PLUGIN_DIR/src" "$STAGE/"
cat > "$STAGE/src/env/build.js" <<JS
// GÉNÉRÉ par scripts/build-plugin.sh — voir plugin/src/env/build.js
module.exports = { DEV_HARNESS: $DEV, HELPER_URL: "$HELPER_URL" };
JS

mkdir -p "$DIST"
rm -f "$CCX"
(cd "$STAGE" && zip -X -q -r "$CCX" manifest.json index.js src -x "*.DS_Store")
echo "OK: $CCX ($(du -h "$CCX" | cut -f1 | tr -d ' '))$([[ $DEV == true ]] && echo '  ⚠️ construction --dev : harnais inclus, NE PAS PUBLIER')"

if [[ $INSTALL == true ]]; then
  [[ -x "$UPIA" ]] || { echo "UPIA introuvable (Creative Cloud requis)"; exit 1; }
  "$UPIA" --remove "$PLUGIN_NAME" 2>/dev/null || true
  "$UPIA" --install "$CCX"
  echo "Installé. Chargement à chaud par Premiere sous ~15 s."
fi
