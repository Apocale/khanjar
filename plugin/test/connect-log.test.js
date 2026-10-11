/* P-04 (audit du 2026-10-08) : journal du plugin quand il ne joint pas l'app.
 * Charge le VRAI plugin/index.js dans un processus enfant, avec un faux
 * « uxp » (dossier de données dans un dossier temporaire) et un faux
 * WebSocket ; vérifie aussi WsClient, DiskLog et Router directement.
 *
 *   node plugin/test/connect-log.test.js
 */
const Module = require("module");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

/* ── Processus enfant : lance index.js dans un mode donné ─────────────── */
if (process.argv[2] === "child") {
  const mode = process.argv[3];          // refused | throws | hang-folder
  const dir = process.argv[4];
  const waitMs = Number(process.argv[5] || 2600);
  const fileObj = (name) => {
    const f = path.join(dir, name);
    return {
      name,
      async write(text) { fs.writeFileSync(f, text); },
      async read() { return fs.readFileSync(f, "utf8"); },
    };
  };
  const folder = {
    nativePath: dir,
    async createFile(name) { fs.writeFileSync(path.join(dir, name), ""); return fileObj(name); },
    async getEntry(name) {
      if (!fs.existsSync(path.join(dir, name))) throw new Error("introuvable");
      return fileObj(name);
    },
  };
  const fakeUxp = {
    host: { name: "premierepro", version: "26.5.2", uiLocale: "fr_FR" },
    entrypoints: { setup() {} },
    storage: { localFileSystem: { async getDataFolder() {
      if (mode === "hang-folder") return new Promise(() => {});
      return folder;
    } } },
  };
  const resolve = Module._resolveFilename;
  Module._resolveFilename = function (request, ...rest) {
    return request === "uxp" ? "uxp" : resolve.call(this, request, ...rest);
  };
  require.cache.uxp = { id: "uxp", filename: "uxp", loaded: true, exports: fakeUxp };
  require("./fake-premiere");
  let attempts = 0;
  global.WebSocket = class {
    constructor(url) {
      attempts += 1;
      if (mode === "throws") throw new Error(`Permission denied to the url ${url}. Manifest entry not found.`);
      this.readyState = 0;
      setTimeout(() => {
        this.readyState = 3;
        if (this.onerror) this.onerror({ type: "error", message: "ECONNREFUSED" });
        if (this.onclose) this.onclose({ code: 1006, reason: "" });
      }, 20);
    }
    send() {}
    close() {}
  };
  const out = process.stdout.write.bind(process.stdout);
  console.log = () => {};
  console.error = () => {};
  require("../index.js");
  setTimeout(() => {
    const read = (n) => (fs.existsSync(path.join(dir, n)) ? fs.readFileSync(path.join(dir, n), "utf8") : null);
    out(JSON.stringify({ attempts, log: read("khanjar-executor.log"), prev: read("khanjar-executor.prev.log") }));
    process.exit(0);
  }, waitMs);
  return;
}

/* ── Processus parent : les vérifications ─────────────────────────────── */
const fake = require("./fake-premiere");
const { check, done } = fake.checker("CONNECT-LOG");
const { WsClient } = require("../src/bridge/wsClient");
const { Router } = require("../src/bridge/router");

function runChild(mode, dir, waitMs) {
  const r = spawnSync(process.execPath, [__filename, "child", mode, dir, String(waitMs || 2600)], { encoding: "utf8", timeout: 20000 });
  try { return JSON.parse(r.stdout); } catch (e) { return { error: r.stderr || r.stdout }; }
}

(async () => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "khanjar-p04-"));

  // 1. Rien n'écoute (refus) : ouvertures, fermetures et erreurs au journal.
  {
    const dir = fs.mkdtempSync(path.join(base, "refused-"));
    const r = runChild("refused", dir);
    const log = r.log || "";
    console.log(`    refus : ${r.attempts} tentative(s) en 2,6 s ; journal :\n${log.trim().split("\n").map((l) => "      " + l).join("\n")}`);
    check(r.attempts >= 2, "le client a tenté de se connecter plusieurs fois");
    check(/WS tentative 1 : erreur — ECONNREFUSED/.test(log) && /WS fermé \(code 1006, tentative 1\)/.test(log) && /tentative 2/.test(log),
      "chaque tentative laisse sa trace sur disque (erreur, fermeture avec code, n° de tentative)");
    // 2ᵉ lancement de Premiere : la session précédente est gardée.
    const r2 = runChild("refused", dir, 300);
    check(r2.prev && r2.prev.includes("WS tentative 1 : erreur") && r2.log && !r2.log.includes("tentative 2 :"),
      "2ᵉ lancement : khanjar-executor.prev.log garde la session précédente");
  }

  // 2. Règle réseau refusée par UXP : l'échec du constructeur est écrit à chaque tentative.
  {
    const dir = fs.mkdtempSync(path.join(base, "throws-"));
    const r = runChild("throws", dir);
    const n = ((r.log || "").match(/construction refusée — Permission denied/g) || []).length;
    check(n >= 2, `constructeur refusé : écrit à chaque tentative (${n} lignes)`);
  }

  // 3. getDataFolder ne répond jamais : le client se connecte quand même.
  {
    const dir = fs.mkdtempSync(path.join(base, "hang-"));
    const r = runChild("hang-folder", dir, 700);
    check(r.attempts >= 1, `dossier de données muet : ${r.attempts} tentative(s) de connexion quand même`);
  }

  // 4. Plafond : 5 premières tentatives, puis 1 sur 30.
  {
    const lines = [];
    const log = { info: (m) => lines.push(m), error: (m) => lines.push(m), debug() {}, flush: async () => {} };
    let count = 0;
    global.WebSocket = class {
      constructor() { count += 1; this.readyState = 0; setImmediate(() => this.onclose && this.onclose({ code: 1006 })); }
      close() {}
    };
    const client = new WsClient({ url: "ws://localhost:1", helloPayload: () => ({}), handleRequest: async () => ({}), log, reconnectMs: 1 });
    client._connect();
    while (count < 100) await new Promise((r) => setTimeout(r, 2));
    const logged = [...new Set(lines.map((l) => Number((l.match(/tentative (\d+)/) || [])[1])))].filter((n) => n <= 95);
    check(JSON.stringify(logged) === JSON.stringify([1, 2, 3, 4, 5, 35, 65, 95]), `tentatives écrites : ${logged.join(", ")} (attendu 1-5, puis 1 sur 30)`);
    clearTimeout(client.reconnectTimer);
    client.reconnectTimer = 1; // plus de nouvelle tentative
  }

  // 5. Socket restée « en connexion » : abandonnée puis relancée, une seule chaîne.
  {
    const lines = [];
    const log = { info: (m) => lines.push(m), error: (m) => lines.push(m), debug() {}, flush: async () => {} };
    const sockets = [];
    global.WebSocket = class {
      constructor() { this.readyState = 0; sockets.push(this); }
      close() { this.readyState = 3; setTimeout(() => this.onclose && this.onclose({ code: 1006 }), 30); }
    };
    const client = new WsClient({ url: "ws://localhost:1", helloPayload: () => ({}), handleRequest: async () => ({}), log,
      reconnectMs: 5, connectingTimeoutMs: 40 });
    client._connect();
    await new Promise((r) => setTimeout(r, 200));
    const abandoned = lines.filter((l) => /toujours en connexion/.test(l)).length;
    check(abandoned >= 2 && sockets.length >= 3, `socket bloquée : abandonnée et relancée (${abandoned} abandons, ${sockets.length} sockets)`);
    // La fermeture tardive d'une socket abandonnée ne crée pas de 2ᵉ chaîne :
    // au plus une socket « vivante » à la fois.
    const alive = sockets.filter((s) => s.readyState === 0).length;
    check(alive === 1, `une seule socket en cours à la fois (${alive})`);
    clearTimeout(client.reconnectTimer);
    client.reconnectTimer = 1;
    client.ws = null;
  }

  // 6. Commande qui modifie le projet : « req apply » sur disque AVANT l'exécution.
  {
    const written = [];
    const lines = [];
    const log = {
      info: (m) => lines.push(m), error: (m) => lines.push(m), debug: (m) => lines.push(m),
      flush: async () => { written.push(lines.slice()); },
    };
    const router = new Router(log);
    let seenOnDisk = false;
    router.register("apply", async () => {
      seenOnDisk = written.some((snap) => snap.some((l) => /^req apply \(r1\)/.test(l)));
      return { ok: true };
    });
    await router.handle({ v: 1, kind: "req", id: "r1", cmd: "apply" });
    check(seenOnDisk, "« req apply » écrit et flushé avant que l'application commence");
  }

  // 7. Écriture du journal qui ne rend jamais la main (m11) : l'application part
  // quand même, au plus 500 ms après, et le verrou est libéré.
  {
    const log = { info() {}, error() {}, debug() {}, flush: () => new Promise(() => {}) };
    const router = new Router(log);
    let ran = 0;
    router.register("apply", async () => { ran += 1; return { ok: true }; });
    const t0 = Date.now();
    await router.handle({ v: 1, kind: "req", id: "s1", cmd: "apply" });
    const took = Date.now() - t0;
    await router.handle({ v: 1, kind: "req", id: "s2", cmd: "apply" });
    check(ran === 2 && took < 900, `journal bloqué : application lancée après ${took} ms, la suivante aussi (pas de BUSY sans fin)`);
  }

  fs.rmSync(base, { recursive: true, force: true });
  done();
})().catch((e) => { console.error(e); process.exit(1); });
