/* Sonde d'environnement : construit le payload `hello` (PROTOCOL.md). */
const uxp = require("uxp");

const PLUGIN_ID = "io.khanjar.executor";
const PLUGIN_VERSION = "0.7.2"; // à garder synchro avec manifest.json

function helloPayload() {
  let hostVersion = "?";
  let uiLocale = "?";
  try { hostVersion = uxp.host.version; } catch (e) { /* absent : non bloquant */ }
  try { uiLocale = uxp.host.uiLocale; } catch (e) { /* idem */ }
  return {
    v: 1,
    kind: "event",
    type: "hello",
    plugin: { id: PLUGIN_ID, version: PLUGIN_VERSION },
    host: { app: "premierepro", version: hostVersion, uiLocale },
    capabilities: {
      audioEffects: false, // v1 : API AudioFilterFactory asymétrique, non exposée
      keyframes: true,     // M4 livré (cuisson d'ease — apply.js/ease.js)
    },
  };
}

module.exports = { helloPayload, PLUGIN_ID, PLUGIN_VERSION };
