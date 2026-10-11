/* P-08 (audit du 2026-10-08) : une seule commande qui modifie le projet à la
 * fois. Vrai Router, vrai WsClient, vrai apply() ; Premiere simulé
 * (fake-premiere.js, données synthétiques).
 *
 *   node plugin/test/busy.test.js
 */
const fake = require("./fake-premiere");
const { Router } = require("../src/bridge/router");
const { WsClient } = require("../src/bridge/wsClient");
const { apply } = require("../src/premiere/apply");

const { check, done } = fake.checker("BUSY");
const quiet = { info() {}, error() {}, debug() {}, flush: async () => {} };

fake.defineEffect("SYN.Shadow", [{ name: "Opacity", value: 0 }, { name: "Distance", value: 0 }, { name: "Softness", value: 0 }]);
fake.defineEffect("SYN.Edge", [{ name: "Border", value: 0 }, { name: "Sharpness", value: 0 }]);
fake.defineEffect("SYN.Glow", [{ name: "Radius", value: 0 }]);
const PLAN = fake.plan("Trois effets synthétiques", [
  fake.op("SYN.Shadow", [{ index: 0, name: "Opacity", value: 60 }, { index: 1, name: "Distance", value: 12 }]),
  fake.op("SYN.Edge", [{ index: 0, name: "Border", value: 4 }]),
  fake.op("SYN.Glow", [{ index: 0, name: "Radius", value: 30 }]),
]);
const EFFECTS = PLAN.operations.map((o) => o.effect.matchName);

function clips(n) {
  return Array.from({ length: n }, (_, i) => new fake.TrackItem({ name: `clip ${i}` }));
}
const req = (id, extra) => Object.assign({ v: 1, kind: "req", id, cmd: "apply", plan: PLAN, options: {} }, extra || {});

(async () => {
  // 1. Deux Entrée à 20 ms d'écart, par le vrai WsClient (scénario de l'audit B3).
  {
    const selection = clips(200);
    fake.reset({ selection, effects: EFFECTS });
    fake.hooks.matchNamesDelayMs = 50; // Premiere lent : la 1ʳᵉ application dure plus de 20 ms
    const router = new Router(quiet);
    router.register("apply", async (msg) => apply(msg.plan, msg.options));
    const sent = [];
    let socket = null;
    global.WebSocket = class {
      constructor() { this.readyState = 1; socket = this; setImmediate(() => this.onopen && this.onopen()); }
      send(text) { sent.push(JSON.parse(text)); }
      close() {}
    };
    const client = new WsClient({ url: "ws://localhost:1", helloPayload: () => ({ kind: "event", type: "hello" }),
      handleRequest: (m) => router.handle(m), log: quiet });
    client._connect();
    await new Promise((r) => setImmediate(r));
    socket.onmessage({ data: JSON.stringify(req("1")) });
    await new Promise((r) => setTimeout(r, 20));
    socket.onmessage({ data: JSON.stringify(req("2")) });
    const until = Date.now() + 10000;
    while (sent.filter((m) => m.kind === "res").length < 2 && Date.now() < until) await new Promise((r) => setTimeout(r, 5));
    const res = sent.filter((m) => m.kind === "res");
    const r1 = res.find((m) => m.id === "1"), r2 = res.find((m) => m.id === "2");
    check(r1 && r1.ok && r1.result.applied.clips === 200, `1ʳᵉ application : 200 clips (obtenu ${r1 && r1.ok ? r1.result.applied.clips : JSON.stringify(r1 && r1.error)})`);
    check(r2 && !r2.ok && r2.error.code === "BUSY", `2ᵉ application à 20 ms : BUSY (obtenu ${r2 ? (r2.ok ? "ok" : r2.error.code) : "rien"})`);
    const added = selection.map((it) => it.components.length - 2);
    check(added.every((n) => n === 3), `3 effets par clip, jamais 6 (min ${Math.min(...added)}, max ${Math.max(...added)})`);
    const defaults = selection.filter((it) => it.components.slice(2).some((c) => c.params.some((p, i) => i === 0 && p.value === 0))).length;
    check(defaults === 0, `aucun effet resté aux valeurs par défaut (${defaults} clip(s))`);
  }

  // 2. Même chose sans délai : deux handle() lancés sans await entre eux.
  {
    const selection = clips(5);
    fake.reset({ selection, effects: EFFECTS });
    const router = new Router(quiet);
    let calls = 0;
    router.register("apply", async (msg) => { calls += 1; return apply(msg.plan, msg.options); });
    router.register("addAdjustmentLayer", async () => { calls += 1; return {}; });
    router.register("ping", async () => ({ pong: true }));
    const p1 = router.handle(req("a"));
    const p2 = router.handle(req("b"));
    const p3 = router.handle({ v: 1, kind: "req", id: "c", cmd: "addAdjustmentLayer" });
    const p4 = router.handle({ v: 1, kind: "req", id: "d", cmd: "ping" });
    const [a, b, c, d] = await Promise.all([p1, p2, p3, p4]);
    check(a.ok, "1ʳᵉ commande exécutée");
    check(!b.ok && b.error.code === "BUSY", "2ᵉ apply simultané : BUSY");
    check(!c.ok && c.error.code === "BUSY", "calque d'effets pendant un apply : BUSY");
    check(d.ok, "une commande de lecture (ping) n'est jamais bloquée");
    check(calls === 1, `une seule commande réellement lancée (${calls})`);
    const after = await router.handle(req("e"));
    check(after.ok, "verrou libéré après la fin : l'apply suivant passe");
  }

  // 3. Échéance dépassée : EXPIRED, la commande n'est pas appelée.
  {
    const router = new Router(quiet);
    let calls = 0;
    router.register("apply", async () => { calls += 1; return { applied: { clips: 1 } }; });
    const late = await router.handle(req("x", { expiresAt: Date.now() - 1 }));
    check(!late.ok && late.error.code === "EXPIRED", "requête expirée : EXPIRED");
    check(calls === 0, "requête expirée : apply jamais appelé");
    const ontime = await router.handle(req("y", { expiresAt: Date.now() + 60000 }));
    check(ontime.ok && calls === 1, "échéance future : exécutée normalement (verrou libéré après EXPIRED)");
    const none = await router.handle(req("z"));
    check(none.ok && calls === 2, "sans expiresAt (app 0.8.3) : exécutée");
    const bogus = await router.handle(req("w", { expiresAt: "bientôt" }));
    check(bogus.ok && calls === 3, "expiresAt qui n'est pas un nombre : ignoré");
  }

  // 4. Une exception dans la commande libère quand même le verrou (finally).
  {
    const router = new Router(quiet);
    let n = 0;
    router.register("apply", async () => { n += 1; if (n === 1) throw new Error("panne"); return { ok: true }; });
    const first = await router.handle(req("p"));
    const second = await router.handle(req("q"));
    check(!first.ok && first.error.code === "INTERNAL", "1ʳᵉ commande en panne : erreur rendue");
    check(second.ok, "verrou libéré après une panne");
  }

  done();
})().catch((e) => { console.error(e); process.exit(1); });
