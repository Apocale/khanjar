/* P-09 + P-10 (audit du 2026-10-08) : un preset à milliers de keyframes ne
 * pose que la partie visible du clip ; les keyframes d'avant l'in-point sont
 * remplacés par un seul, à l'in-point, à la valeur de la courbe ; plafond de
 * 2 000 actions par clip. ease.js et le vrai apply(), Premiere simulé
 * (fake-premiere.js). Données SYNTHÉTIQUES (un « shake » généré ici).
 *
 *   node plugin/test/window.test.js
 */
const fake = require("./fake-premiere");
const ease = require("../src/premiere/ease");
const { apply } = require("../src/premiere/apply");

const { check, done } = fake.checker("WINDOW");
const TPS = fake.TPS;
const FRAME25 = Math.round(TPS / 25);
const near = (a, b, eps) => Math.abs(a - b) < (eps || 1e-6);

/* Shake synthétique : `n` keyframes de Position répartis sur `seconds`,
 * adoucis (vitesse 0, influence 1/3) → chemin cuit. */
function shake(n, seconds, eased) {
  const out = [];
  for (let k = 0; k < n; k++) {
    const kf = { t: String(Math.round((k * seconds * TPS) / n)), value: { x: 0.5 + (k % 2 ? 0.01 : -0.01), y: 0.5 + ((k % 3) - 1) * 0.008 }, i: eased ? 5 : 0 };
    if (eased) Object.assign(kf, { ov: 0, oi: 1 / 3, iv: 0, ii: 1 / 3 });
    out.push(kf);
  }
  return out;
}
const identity = (t) => t;

// 1. P-09, chemin cuit : 10 000 keyframes sur 12 min, clip de 3 s à 25 i/s.
{
  const clip = { inTicks: 0, durTicks: 3 * TPS };
  const kfs = shake(10000, 720, true);
  const r = ease.bakeParam(kfs, identity, FRAME25, clip);
  const hi = clip.inTicks + clip.durTicks + FRAME25;
  const last = r.points[r.points.length - 1];
  check(r.baked && r.windowed, "shake adouci : cuit puis limité au clip");
  check(r.points.length <= 220, `${r.points.length} keyframes au plus ≈ 210 (avant : plus de 10 000)`);
  check(r.points.every((p) => p.ticks >= 0 && p.ticks <= hi), "aucun keyframe hors de [in, fin + 1 image]");
  const exact = ease.curveValueAt(kfs.slice().sort((a, b) => Number(a.t) - Number(b.t)), identity, hi);
  check(last.ticks === hi && near(last.value.x, exact.x) && near(last.value.y, exact.y), "keyframe de bord à fin + 1 image, valeur exacte de la courbe");
}

(async () => {
  // 2. Même shake par le vrai apply() (Motion > Position) sur 1 puis 20 clips.
  for (const n of [1, 20]) {
    const selection = Array.from({ length: n }, (_, i) => new fake.TrackItem({ name: `clip ${i}`, durTicks: 3 * TPS }));
    fake.reset({ selection, effects: [], timebase: FRAME25 });
    const plan = fake.plan("Shake synthétique", [], [
      fake.op("AE.ADBE Motion", [{ index: 0, name: "Position", value: { x: 0.5, y: 0.5 }, keyframes: shake(10000, 720, true) }], { paramCount: 11 }),
    ]);
    const res = await apply(plan, { relativeToClip: false });
    const counts = selection.map((it) => it.component("AE.ADBE Motion").param("Position").keyframes.size);
    check(Math.max(...counts) <= 220 && res.fidelity.paramsSet === n,
      `apply() sur ${n} clip(s) : ≤ 220 keyframes de Position par clip (max ${Math.max(...counts)}), ${fake.stats.maxActions} actions dans la plus grosse transaction`);
  }

  // 3. Chemin NON cuit : 3 600 keyframes sur 12 min → fenêtré, interpolations comprises.
  {
    const clip = { inTicks: 0, durTicks: 3 * TPS };
    const linear = Array.from({ length: 3600 }, (_, k) => ({ t: String(Math.round((k * 720 * TPS) / 3600)), value: k % 2 ? 10 : -10, i: 0 }));
    const r = ease.plainKeyframes(linear, identity, FRAME25, clip);
    check(r.windowed && r.points.length <= 20, `non cuit, 3 600 keyframes : ${r.points.length} gardés (fenêtre du clip)`);
    const selection = [new fake.TrackItem({ name: "clip", durTicks: 3 * TPS })];
    fake.reset({ selection, effects: [], timebase: FRAME25 });
    const bez = linear.map((k) => ({ ...k, i: 5 })); // bézier sans ease : tracé natif + modes
    const plan = fake.plan("Secousse", [], [fake.op("AE.ADBE Motion", [{ index: 4, name: "Rotation", value: 0, keyframes: bez }], { paramCount: 11 })]);
    const res = await apply(plan, { relativeToClip: false });
    const rot = selection[0].component("AE.ADBE Motion").param("Rotation");
    check(rot.keyframes.size <= 20 && rot.modes.size === rot.keyframes.size && (fake.stats.kinds.interp || 0) === rot.keyframes.size,
      `apply() non cuit : ${rot.keyframes.size} keyframes, ${fake.stats.kinds.interp || 0} interpolations (avant : 3 600 + 3 600)`);
    check(res.fidelity.transactions === 2, `   2 transactions (réglages + interpolations) (obtenu ${res.fidelity.transactions})`);
  }

  // 4. Preset court : inchangé.
  {
    const clip = { inTicks: 5 * TPS, durTicks: 3 * TPS };
    const kfs = [{ t: "0", value: 0, i: 0 }, { t: String(TPS / 2), value: 60, i: 0 }, { t: String(TPS), value: 100, i: 0 }];
    const map = (t) => clip.inTicks + t;
    const r = ease.plainKeyframes(kfs, map, FRAME25, clip);
    check(!r.windowed && !r.cutAtIn && JSON.stringify(r.points.map((p) => [p.ticks, p.value])) ===
      JSON.stringify(kfs.map((k) => [clip.inTicks + Number(k.t), k.value])), "preset court : keyframes inchangés");
    const eased = kfs.map((k) => ({ ...k, i: 5, ov: 0, oi: 1 / 3, iv: 0, ii: 1 / 3 }));
    const b = ease.bakeParam(eased, map, FRAME25, clip);
    check(b.baked && !b.windowed && !b.cutAtIn && b.points[0].ticks === clip.inTicks && b.points[b.points.length - 1].ticks === clip.inTicks + TPS,
      `preset court cuit : ni coupé ni fenêtré (${b.points.length} points)`);
  }

  // 5. P-10 : ancré à la FIN, plus long que le clip (sous-titre de 0,3 s, in-point 1 h).
  {
    const inTicks = 3600 * TPS, dur = 0.3 * TPS;
    const selection = [new fake.TrackItem({ name: "sous-titre", inTicks, durTicks: dur })];
    fake.reset({ selection, effects: [] });
    const keyframes = [{ t: String(1.0 * TPS), value: 100, i: 0 }, { t: String(1.6 * TPS), value: 31, i: 0 }, { t: String(2.0 * TPS), value: 0, i: 0 }];
    const plan = fake.plan("Sortie scintillante", [], [
      fake.op("AE.ADBE Opacity", [{ index: 0, name: "Opacity", value: 100, keyframes }], { paramCount: 2, anchor: { type: 2, srcDur: String(2 * TPS) } }),
    ]);
    await apply(plan, {});
    const op = selection[0].component("AE.ADBE Opacity").param("Opacity");
    const ticks = [...op.keyframes.keys()].sort((a, b) => a - b);
    const first = op.keyframes.get(ticks[0]);
    // Sans clamp : 31 à in − 0,1 s, 0 à in + 0,3 s → à l'in-point : 31 − 31 × 0,1/0,4.
    check(ticks.length === 2 && ticks[0] === inTicks && near(first, 23.25, 1e-3),
      `ancré fin sur clip court : 1er keyframe à l'in-point = ${first} (attendu 23,25 ; avant : 100 puis 31 au même tick)`);
    check(new Set(ticks).size === ticks.length, "aucun tick en double");
  }

  // 6. P-10 : offset négatif (−0,45 s) sur un rush à in-point 0 → 1er keyframe à 0.
  {
    const selection = [new fake.TrackItem({ name: "rush", inTicks: 0, durTicks: 3 * TPS })];
    fake.reset({ selection, effects: [] });
    const keyframes = [{ t: String(-0.45 * TPS), value: 100, i: 0 }, { t: String(1.0 * TPS), value: 132, i: 0 }];
    const plan = fake.plan("Zoom lent", [], [fake.op("AE.ADBE Motion", [{ index: 1, name: "Scale", value: 100, keyframes }], { paramCount: 11 })]);
    await apply(plan, { relativeToClip: false });
    const scale = selection[0].component("AE.ADBE Motion").param("Scale");
    const ticks = [...scale.keyframes.keys()].sort((a, b) => a - b);
    const expected = 100 + 32 * (0.45 / 1.45);
    check(ticks[0] === 0 && near(scale.keyframes.get(0), expected, 1e-6) && ticks.every((t) => t >= 0),
      `offset négatif : 1er keyframe à 0 = ${scale.keyframes.get(0).toFixed(3)} (attendu ${expected.toFixed(3)} ; avant : à −0,45 s)`);
  }

  // 7. Plafond de 2 000 actions par clip : réglage trop lourd sauté, les autres posés.
  {
    const selection = [new fake.TrackItem({ name: "long", durTicks: 30 * TPS })];
    fake.reset({ selection, effects: [], timebase: FRAME25 });
    const dense = Array.from({ length: 3000 }, (_, k) => ({ t: String(Math.round((k * 30 * TPS) / 3000)), value: { x: 0.5 + (k % 2) * 0.01, y: 0.5 }, i: 0 }));
    const plan = fake.plan("Trop dense", [], [fake.op("AE.ADBE Motion", [
      { index: 0, name: "Position", value: { x: 0.5, y: 0.5 }, keyframes: dense },
      { index: 1, name: "Scale", value: 80 },
    ], { paramCount: 11 })]);
    const res = await apply(plan, { relativeToClip: false });
    const m = selection[0].component("AE.ADBE Motion");
    check(m.param("Position").keyframes.size === 0 && res.fidelity.detail.some((d) => d.reason === "TOO_MANY_KEYFRAMES"),
      "3 000 keyframes visibles (> 2 000 actions) : réglage sauté, TOO_MANY_KEYFRAMES");
    check(res.fidelity.paramsSkipped === 1 && m.param("Scale").value === 80 && res.fidelity.paramsSet === 1,
      "compté sauté (HUD orange) ; l'autre réglage du clip est posé");
  }

  done();
})().catch((e) => { console.error(e); process.exit(1); });
