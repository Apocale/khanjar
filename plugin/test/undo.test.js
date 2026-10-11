/* P-02 (audit du 2026-10-08) : nombre d'entrées d'annulation (transactions
 * réussies et non vides) d'une application, quel que soit le nombre de clips.
 * Vrai apply(), Premiere simulé (fake-premiere.js, données synthétiques).
 *
 *   node plugin/test/undo.test.js
 */
const fake = require("./fake-premiere");
const { apply } = require("../src/premiere/apply");

const { check, done } = fake.checker("UNDO");
const TPS = fake.TPS;

fake.defineEffect("SYN.Shadow", [{ name: "Opacity", value: 0 }, { name: "Distance", value: 0 }, { name: "Softness", value: 0 }]);
fake.defineEffect("SYN.Edge", [{ name: "Border", value: 0 }, { name: "Sharpness", value: 0 }]);
fake.defineEffect("SYN.Glow", [{ name: "Radius", value: 0 }]);

const threeEffects = () => fake.plan("Trois effets réglés", [
  fake.op("SYN.Shadow", [{ index: 0, name: "Opacity", value: 60 }, { index: 1, name: "Distance", value: 12 }]),
  fake.op("SYN.Edge", [{ index: 0, name: "Border", value: 4 }]),
  fake.op("SYN.Glow", [{ index: 0, name: "Radius", value: 30 }]),
]);
// Keyframes du preset (offsets en ticks), sans ease : tracé keyframe par keyframe.
const kfs = (mode) => [
  { t: "0", value: 0, i: mode },
  { t: String(TPS / 2), value: 50, i: mode },
  { t: String(TPS), value: 100, i: mode },
];
const animated = (mode) => fake.plan(`Glow animé (mode ${mode})`, [
  fake.op("SYN.Glow", [{ index: 0, name: "Radius", value: 0, keyframes: kfs(mode) }]),
]);
const intrinsicOnly = () => fake.plan("Opacité seule", [], [
  fake.op("AE.ADBE Opacity", [{ index: 0, name: "Opacity", value: 50 }], { paramCount: 2 }),
]);
const nakedEffect = () => fake.plan("Effet nu", [fake.op("SYN.Glow", [])]);

function clips(n, prefix) {
  return Array.from({ length: n }, (_, i) => new fake.TrackItem({ name: `${prefix || "clip"} ${i}` }));
}

async function run(plan, n, opts) {
  const selection = clips(n);
  fake.reset({ selection, effects: plan.operations.map((o) => o.effect.matchName) });
  if (opts && opts.setup) opts.setup(selection);
  const res = await apply(plan, {});
  return { res, selection, undo: fake.stats.txOkNonEmpty };
}

(async () => {
  for (const n of [1, 3, 500]) {
    const { res, selection, undo } = await run(threeEffects(), n);
    check(undo === 2 && res.fidelity.transactions === 2,
      `3 effets réglés sur ${n} clip(s) : 2 annulations (obtenu ${undo}, fidelity.transactions=${res.fidelity.transactions})`);
    const ok = selection.every((it) => it.component("SYN.Shadow").param("Opacity").value === 60 &&
      it.component("SYN.Glow").param("Radius").value === 30);
    check(ok && res.fidelity.paramsSet === 4 * n && res.fidelity.paramsSkipped === 0,
      `   réglages posés sur chaque clip (${res.fidelity.paramsSet}/${4 * n})`);
    check(res.transaction === "single", `   transaction=single (obtenu ${res.transaction})`);
  }

  {
    const { res, selection, undo } = await run(animated(5), 3);
    const radius = selection[0].component("SYN.Glow").param("Radius");
    const modes = [...radius.modes.values()];
    check(undo === 3 && res.fidelity.transactions === 3, `keyframes bézier non cuits : 3 annulations (obtenu ${undo})`);
    check(modes.length === 3 && modes.every((m) => m === 5), `   mode bézier posé sur les 3 keyframes (${modes.join(",")})`);
  }

  {
    const { res, selection, undo } = await run(animated(0), 3);
    const radius = selection[0].component("SYN.Glow").param("Radius");
    check(undo === 2 && res.fidelity.transactions === 2,
      `keyframes LINÉAIRES : pas de transaction d'interpolation, 2 annulations (obtenu ${undo})`);
    check(radius.keyframes.size === 3 && (fake.stats.kinds.interp || 0) === 0, "   3 keyframes posés, aucune action d'interpolation");
  }

  {
    const { res, selection, undo } = await run(intrinsicOnly(), 3);
    check(undo === 1 && res.fidelity.transactions === 1, `preset 100 % intrinsèque : 1 annulation (obtenu ${undo})`);
    check(fake.stats.tx === 1, `   aucune transaction d'insertion vide (${fake.stats.tx} transaction(s) au total)`);
    check(fake.stats.createComponent === 0, "   aucune préparation de composant");
    check(selection.every((it) => it.component("AE.ADBE Opacity").param("Opacity").value === 50), "   opacité posée sur les 3 clips");
  }

  {
    const { res, undo } = await run(nakedEffect(), 3);
    check(undo === 1 && res.fidelity.transactions === 1, `effet nu : 1 annulation (obtenu ${undo})`);
  }

  // Chaîne périmée sur le clip 2 dans la transaction groupée : les autres restent
  // groupés, le clip 2 passe par le repli et ses réglages sont posés.
  {
    let target = null;
    const { res, selection } = await run(threeEffects(), 3, {
      setup(sel) {
        target = sel[1];
        fake.hooks.beforeTransaction = (ctx) => { if (ctx.index === 1) target.markChainsStale(); };
      },
    });
    const allSet = selection.every((it) => it.component("SYN.Shadow").param("Opacity").value === 60);
    check(allSet, "chaîne périmée sur le clip 2 : réglages posés sur les 3 clips");
    check(res.fidelity.paramsSet === 12 && res.fidelity.paramsFailedClips.length === 0,
      `   12/12 réglages, aucun clip en échec (paramsFailedClips=${JSON.stringify(res.fidelity.paramsFailedClips)})`);
    check(res.fidelity.transactions === 3 && res.transaction === "per-clip",
      `   insertion + transaction groupée + repli du seul clip 2 = 3 (obtenu ${res.fidelity.transactions}, ${res.transaction})`);
  }

  done();
})().catch((e) => { console.error(e); process.exit(1); });
