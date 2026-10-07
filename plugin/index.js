/* Khanjar — plugin UXP headless.
 * Rôle : exécuteur sans état des commandes de l'app Khanjar (PROTOCOL.md).
 * Toute l'intelligence produit (index, recherche, presets) vit dans l'app. */
const uxp = require("uxp");

const { DiskLog } = require("./src/log/diskLog");
const { helloPayload } = require("./src/env/probe");
const { Router } = require("./src/bridge/router");
const { WsClient } = require("./src/bridge/wsClient");
const { listEffects } = require("./src/premiere/effects");
const { getSelection } = require("./src/premiere/selection");
const { apply } = require("./src/premiere/apply");

const BUILD = require("./src/env/build");
const HELPER_URL = BUILD.HELPER_URL;

const log = new DiskLog("khanjar-executor.log");
const router = new Router(log);
const startedAt = Date.now();

router.register("ping", async () => ({ pong: true, uptimeMs: Date.now() - startedAt }));
router.register("listEffects", async () => listEffects());
router.register("getSelection", async () => getSelection());
router.register("apply", async (msg) => apply(msg.plan, msg.options));
const { addAdjustmentLayer } = require("./src/premiere/adjustment");
router.register("addAdjustmentLayer", async () => addAdjustmentLayer());
const { testSetup, testSetupMulti, readParams, dumpChain, dumpAllSelected, easeProbe, inspectComponent } = require("./src/premiere/harness");
// Diagnostics en LECTURE SEULE : toujours présents (support : « envoie-moi le
// résultat de khanjar dump-selected »). Ils ne modifient rien dans le projet.
router.register("readParams", async (msg) => readParams(msg));
router.register("dumpChain", async () => dumpChain());
router.register("dumpAllSelected", async () => dumpAllSelected());
router.register("inspectComponent", async () => inspectComponent());
// Harnais qui MODIFIENT Premiere (création de projet, import, keyframes de
// test) : uniquement dans une construction --dev, jamais dans une version
// publiée (2026-10-06). Sans ça, tout programme connecté au pont pouvait
// créer des projets et importer des fichiers chez l'utilisateur.
if (BUILD.DEV_HARNESS) {
  router.register("testSetup", async (msg) => testSetup(msg));
  router.register("testSetupMulti", async (msg) => testSetupMulti(msg));
  router.register("easeProbe", async (msg) => easeProbe(msg));
}
router.register("setDebug", async (msg) => {
  log.debugSink = msg.enabled
    ? (level, line) => client.send({ v: 1, kind: "event", type: "log", level, line })
    : null;
  return { enabled: !!msg.enabled };
});

const client = new WsClient({
  url: HELPER_URL,
  helloPayload,
  handleRequest: async (msg) => {
    const res = await router.handle(msg);
    log.flush();
    return res;
  },
  log,
});

// Hooks de cycle de vie (journalisés ; l'entrypoint command est requis par le
// manifest et réservé aux évolutions IPC).
try {
  uxp.entrypoints.setup({
    plugin: {
      create() { log.info("plugin.create"); },
      destroy() { log.info("plugin.destroy"); log.flush(); },
    },
    commands: {
      "khanjar.internal": () => { log.info("commande interne invoquée"); },
    },
  });
} catch (err) {
  log.error(`entrypoints.setup: ${err.message}`);
}

log.info(`Khanjar démarré (host ${(() => { try { return uxp.host.name + " " + uxp.host.version; } catch (e) { return "?"; } })()})`);
log.init().then(() => {
  client.start();
  log.flush();
});
