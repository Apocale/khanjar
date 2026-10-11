/* P-01 (audit du 2026-10-08) : « Adapter les presets au cadrage du clip »
 * transpose par rapport à la valeur NEUTRE (Échelle 100, Position au centre,
 * Rotation 0), jamais sur un réglage déjà animé du clip. Vrai apply(),
 * Premiere simulé (fake-premiere.js, données synthétiques).
 *
 *   node plugin/test/relative.test.js
 */
const fake = require("./fake-premiere");
const { apply } = require("../src/premiere/apply");

const { check, done } = fake.checker("RELATIVE");
const TPS = fake.TPS;
const near = (a, b) => Math.abs(a - b) < 1e-6;
const nearPt = (a, b) => a && near(a.x, b.x) && near(a.y, b.y);

// Plan « intrinsèque » : réglages de Motion (11 paramètres), comme un PiP.
const motionOp = (params) => fake.op("AE.ADBE Motion", params, { paramCount: 11 });
const kfs = (a, b, i) => [{ t: "0", value: a, i: i || 0 }, { t: String(TPS), value: b, i: i || 0 }];

async function run(plan, item, relative) {
  fake.reset({ selection: [item], effects: [] });
  const res = await apply(plan, { relativeToClip: relative !== false });
  return res;
}
const motion = (item) => item.component("AE.ADBE Motion");
const keyframeValues = (param) => [...param.keyframes.entries()].sort((a, b) => a[0] - b[0]).map(([, v]) => v);

(async () => {
  // (a) Clip au cadrage neutre + PiP FIXE : on écrit exactement le preset.
  {
    const item = new fake.TrackItem({ name: "plein cadre" });
    const plan = fake.plan("PiP synthétique", [], [motionOp([
      { index: 0, name: "Position", value: { x: 0.274, y: 0.752 } },
      { index: 1, name: "Scale", value: 25 },
      { index: 4, name: "Rotation", value: 90 },
    ])]);
    await run(plan, item);
    const m = motion(item);
    check(nearPt(m.param("Position").value, { x: 0.274, y: 0.752 }), `(a) Position = preset (${JSON.stringify(m.param("Position").value)})`);
    check(near(m.param("Scale").value, 25), `(a) Échelle = 25 (obtenu ${m.param("Scale").value})`);
    check(near(m.param("Rotation").value, 90), `(a) Rotation = 90 (obtenu ${m.param("Rotation").value})`);
  }

  // (b) Clip réglé à 50 % + zoom 100 → 120 : 50 → 60.
  {
    const item = new fake.TrackItem({ name: "clip à 50 %", motion: { scale: 50 } });
    const plan = fake.plan("Zoom", [], [motionOp([{ index: 1, name: "Scale", value: 100, keyframes: kfs(100, 120) }])]);
    await run(plan, item);
    const v = keyframeValues(motion(item).param("Scale"));
    check(v.length === 2 && near(v[0], 50) && near(v[1], 60), `(b) zoom 100→120 sur un clip à 50 % : ${v.join(" → ")} (attendu 50 → 60)`);
  }

  // (c) Sous-titre (Vector Motion, in-point 1 h) à 100 + arrivée 110 → 100 : 110 → 100.
  {
    const comps = [
      new fake.Component("AE.ADBE Opacity", fake.opacityDefs()),
      new fake.Component("AE.ADBE Motion", fake.motionDefs()),
      new fake.Component("AE.ADBE Graphic Group", fake.motionDefs()),
      new fake.Component("AE.ADBE Text", [{ name: "Source Text", value: 0 }]),
    ];
    const item = new fake.TrackItem({ name: "sous-titre", inTicks: 3600 * TPS, components: comps });
    const plan = fake.plan("Pop", [], [fake.op("AE.ADBE Graphic Group", [{ index: 1, name: "Scale", value: 110, keyframes: kfs(110, 100) }], { paramCount: 11 })]);
    await run(plan, item);
    const v = keyframeValues(item.component("AE.ADBE Graphic Group").param("Scale"));
    check(v.length === 2 && near(v[0], 110) && near(v[1], 100), `(c) arrivée 110→100 sur un sous-titre à 100 : ${v.join(" → ")} (avant : 100 → 90,9)`);
  }

  // (d) Échelle actuelle 0 : preset inchangé (jamais tout à 0).
  {
    const item = new fake.TrackItem({ name: "invisible", motion: { scale: 0 } });
    const plan = fake.plan("Zoom", [], [motionOp([{ index: 1, name: "Scale", value: 100, keyframes: kfs(100, 120) }])]);
    await run(plan, item);
    const v = keyframeValues(motion(item).param("Scale"));
    check(v.length === 2 && near(v[0], 100) && near(v[1], 120), `(d) échelle actuelle 0 : preset inchangé (${v.join(" → ")})`);
  }

  // (e) Réglage DÉJÀ animé sur le clip : inchangé — via isTimeVarying…
  {
    const item = new fake.TrackItem({ name: "déjà animé", motion: { scale: 50, scaleKeyframes: [[0, 50], [2 * TPS, 70]] } });
    const plan = fake.plan("Zoom", [], [motionOp([{ index: 1, name: "Scale", value: 100, keyframes: kfs(100, 120) }])]);
    await run(plan, item);
    const p = motion(item).param("Scale");
    check(near(p.keyframes.get(0), 100) && near(p.keyframes.get(TPS), 120), "(e) déjà animé (isTimeVarying) : preset écrit tel quel");
  }
  // … et sans isTimeVarying (Premiere plus ancien) : début ≠ fin du clip.
  {
    const item = new fake.TrackItem({ name: "déjà animé, API ancienne",
      motion: { scale: 50, scaleKeyframes: [[0, 50], [2 * TPS, 70]], noIsTimeVarying: true } });
    const plan = fake.plan("Zoom", [], [motionOp([{ index: 1, name: "Scale", value: 100, keyframes: kfs(100, 120) }])]);
    await run(plan, item);
    const p = motion(item).param("Scale");
    check(near(p.keyframes.get(0), 100) && near(p.keyframes.get(TPS), 120), "(e) déjà animé (sans isTimeVarying, début ≠ fin) : preset tel quel");
  }
  // Sans isTimeVarying mais réglage fixe (début = fin) : transposé normalement.
  {
    const item = new fake.TrackItem({ name: "fixe, API ancienne", motion: { scale: 50, noIsTimeVarying: true } });
    const plan = fake.plan("Zoom", [], [motionOp([{ index: 1, name: "Scale", value: 100, keyframes: kfs(100, 120) }])]);
    await run(plan, item);
    const v = keyframeValues(motion(item).param("Scale"));
    check(near(v[0], 50) && near(v[1], 60), `    fixe sans isTimeVarying : transposé (${v.join(" → ")})`);
  }

  // (f) Premiere russe : « Масш. ширину » reconnu comme une échelle.
  {
    const defs = fake.motionDefs({ scaleWidth: 50 });
    defs[2].name = "Масш. ширину";
    const item = new fake.TrackItem({ name: "клип", components: [
      new fake.Component("AE.ADBE Opacity", fake.opacityDefs()), new fake.Component("AE.ADBE Motion", defs)] });
    const plan = fake.plan("Ширина", [], [motionOp([{ index: 2, name: "Масш. ширину", value: 120 }])]);
    await run(plan, item);
    const v = motion(item).params[2].value;
    check(near(v, 60), `(f) « Масш. ширину » 120 sur un clip à 50 % : ${v} (attendu 60)`);
  }

  // Position et rotation transposées autour du neutre.
  {
    const item = new fake.TrackItem({ name: "décalé", motion: { position: { x: 0.6, y: 0.5 }, rotation: 10 } });
    const plan = fake.plan("Coin", [], [motionOp([
      { index: 0, name: "Position", value: { x: 0.274, y: 0.752 } },
      { index: 4, name: "Rotation", value: 90 },
    ])]);
    await run(plan, item);
    const m = motion(item);
    check(nearPt(m.param("Position").value, { x: 0.374, y: 0.752 }), `position décalée de +0,1 : ${JSON.stringify(m.param("Position").value)}`);
    check(near(m.param("Rotation").value, 100), `rotation à 10° + 90 : ${m.param("Rotation").value}`);
  }

  // Case décochée : valeurs absolues.
  {
    const item = new fake.TrackItem({ name: "clip à 50 %", motion: { scale: 50 } });
    const plan = fake.plan("Zoom", [], [motionOp([{ index: 1, name: "Scale", value: 100, keyframes: kfs(100, 120) }])]);
    await run(plan, item, false);
    const v = keyframeValues(motion(item).param("Scale"));
    check(near(v[0], 100) && near(v[1], 120), `adaptation décochée : valeurs du preset (${v.join(" → ")})`);
  }

  done();
})().catch((e) => { console.error(e); process.exit(1); });
