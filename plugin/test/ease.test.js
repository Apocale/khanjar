/* P-03 (audit du 2026-10-08) : ease « à l'arrivée » (départ linéaire, arrivée
 * adoucie) cuite ; champs d'ease absents ou nuls non cuits ; HOLD conservé
 * dans un réglage cuit. Teste ease.js directement (aucun module Premiere).
 * Données synthétiques.
 *
 *   node plugin/test/ease.test.js
 */
const path = require("path");
const target = process.argv[2] ? path.resolve(process.argv[2]) : path.join(__dirname, "../src/premiere/ease.js");
const ease = require(target);

let failures = 0;
function check(cond, label) {
  console.log(`${cond ? "  ✓" : "  ✗"} ${label}`);
  if (!cond) failures += 1;
}

const TPS = 254016000000;
const FRAME = Math.round(TPS / 30);

/* Bézier temporelle recalculée ICI, indépendamment d'ease.js (modèle AE :
 * poignées = vitesse × influence × durée). */
function bezier(u, p0, p1, p2, p3) {
  const m = 1 - u;
  return m * m * m * p0 + 3 * m * m * u * p1 + 3 * m * u * u * p2 + u * u * u * p3;
}
function curveAt(fx, x1, x2, y0, y1, y2, y3) {
  let lo = 0, hi = 1;
  for (let k = 0; k < 60; k++) {
    const mid = (lo + hi) / 2;
    if (bezier(mid, 0, x1, x2, 1) < fx) lo = mid; else hi = mid;
  }
  return bezier((lo + hi) / 2, y0, y1, y2, y3);
}

// 1. Départ LINÉAIRE (vitesse = pente de la corde, influence 1/6), arrivée
//    BÉZIER adoucie (vitesse 0, influence 33 %) : « Ease In » sur le dernier keyframe.
{
  const dt = 0.3, v0 = 10, v1 = 100;
  const k0 = { t: "0", value: v0, i: 0, ov: (v1 - v0) / dt, oi: 1 / 6 };
  const k1 = { t: String(dt * TPS), value: v1, i: 5, iv: 0, ii: 0.33 };
  check(ease.hasEase(k0, k1) === true, "départ linéaire / arrivée adoucie : cuit");
  const expected = curveAt(0.5, 1 / 6, 1 - 0.33, v0, v0 + ((v1 - v0) / dt) * (1 / 6) * dt, v1 - 0 * 0.33 * dt, v1);
  const got = ease.valueAt(0.5, k0, k1, dt, false);
  check(Math.abs(got - expected) < 1e-6 && expected > (v0 + v1) / 2 + 5,
    `valeur à mi-temps = bézier recalculée ${expected.toFixed(3)} (obtenu ${got.toFixed(3)}, linéaire ${(v0 + v1) / 2})`);
  const r = ease.bakeParam([k0, k1], (t) => t, FRAME, { inTicks: 0, durTicks: 2 * TPS });
  const inner = r.points.filter((p) => p.ticks > 0 && p.ticks < dt * TPS);
  const worst = Math.max(...inner.map((p) => {
    const fx = p.ticks / (dt * TPS);
    return Math.abs(p.value - curveAt(fx, 1 / 6, 1 - 0.33, v0, v0 + (v1 - v0) / 6, v1, v1));
  }));
  check(r.baked && inner.length >= 8 && worst < 1e-6,
    `points cuits (1 par image : ${inner.length}) sur la courbe recalculée (écart max ${worst.toExponential(1)})`);
  // Même chose avec une vitesse ABSENTE côté linéaire (autre outil) : forcée à la pente.
  const k0bare = { t: "0", value: v0, i: 0, oi: 1 / 6 };
  check(ease.hasEase(k0bare, k1) && Math.abs(ease.valueAt(0.5, k0bare, k1, dt, false) - expected) < 1e-6,
    "côté linéaire sans vitesse : pente de la corde utilisée, même courbe");
}

// 1 bis. Même cas pour un POINT (Position) : arrivée adoucie cuite.
{
  const dt = 1, p0 = { x: 0.2, y: 0.5 }, p1 = { x: 0.5, y: 0.5 };
  const dist = 0.3;
  const k0 = { t: "0", value: p0, i: 0, ov: dist / dt, oi: 1 / 6 };
  const k1 = { t: String(TPS), value: p1, i: 5, iv: 0, ii: 0.33 };
  check(ease.hasEase(k0, k1) === true, "point : départ linéaire / arrivée adoucie : cuit");
  const s = curveAt(0.5, 1 / 6, 1 - 0.33, 0, 1 / 6, 1, 1);
  const got = ease.valueAt(0.5, k0, k1, dt, true);
  check(Math.abs(got.x - (0.2 + s * 0.3)) < 1e-6 && s > 0.5, `point à mi-temps : x=${got.x.toFixed(4)} (attendu ${(0.2 + s * 0.3).toFixed(4)}, linéaire 0.35)`);
}

// 2. Champs d'ease absents ou nuls : non cuit (garde des presets « d'ailleurs »).
{
  const a = { t: "0", value: 0, i: 5 }, b = { t: String(TPS), value: 100, i: 5 };
  check(ease.hasEase(a, b) === false, "champs d'ease absents : non cuit");
  const z0 = { t: "0", value: 0, i: 5, ov: 0, oi: 0 }, z1 = { t: String(TPS), value: 100, i: 5, iv: 0, ii: 0 };
  check(ease.hasEase(z0, z1) === false, "champs d'ease tous à 0 : non cuit");
  const l0 = { t: "0", value: 0, i: 0, ov: 0, oi: 0 }, l1 = { t: String(TPS), value: 100, i: 5, iv: 0, ii: 0 };
  check(ease.hasEase(l0, l1) === false, "départ linéaire + arrivée à champs nuls : non cuit");
}

// 3. Deux keyframes LINÉAIRES : jamais cuits, même avec des champs d'ease.
{
  const a = { t: "0", value: 0, i: 0, ov: 0, oi: 0.33 }, b = { t: String(TPS), value: 100, i: 0, iv: 0, ii: 0.33 };
  check(ease.hasEase(a, b) === false, "deux keyframes linéaires : non cuit");
  const r = ease.bakeParam([a, b], (t) => t, FRAME, { inTicks: 0, durTicks: 2 * TPS });
  check(r.baked === false, "bakeParam : tracé natif (non cuit)");
}

// 4. Ease classique des deux côtés (sortie et entrée à vitesse 0) : toujours cuit.
{
  const a = { t: "0", value: 0, i: 5, ov: 0, oi: 1 / 3 }, b = { t: String(TPS), value: 100, i: 5, iv: 0, ii: 1 / 3 };
  check(ease.hasEase(a, b) === true, "ease entrée/sortie classique : cuit (inchangé)");
  // Poignées exactement sur la corde : courbe linéaire, rien à cuire.
  const c = { t: "0", value: 0, i: 5, ov: 100, oi: 1 / 3 }, d = { t: String(TPS), value: 100, i: 5, iv: 100, ii: 1 / 3 };
  check(ease.hasEase(c, d) === false, "poignées sur la corde : non cuit");
}

// 5. HOLD au milieu d'un réglage cuit : palier conservé.
{
  const kfs = [
    { t: "0", value: 0, i: 5, oi: 0.333, ov: 0 },
    { t: String(0.5 * TPS), value: 100, i: 4, ii: 0.333, iv: 0, oi: 0.333, ov: 0 },
    { t: String(TPS), value: 0, i: 0, ii: 0.167, iv: 0 },
  ];
  const r = ease.bakeParam(kfs, (t) => t, FRAME, { inTicks: 0, durTicks: 2 * TPS });
  const pts = r.points;
  const at = (ticks) => {
    for (let i = 1; i < pts.length; i++) {
      if (ticks <= pts[i].ticks) {
        const f = (ticks - pts[i - 1].ticks) / (pts[i].ticks - pts[i - 1].ticks);
        return pts[i - 1].value + f * (pts[i].value - pts[i - 1].value);
      }
    }
    return pts[pts.length - 1].value;
  };
  check(r.baked, "réglage avec une ease : cuit");
  check(Math.abs(at(0.75 * TPS) - 100) < 1e-9 && Math.abs(at(TPS - 2) - 100) < 1e-6,
    `HOLD : 100 tenu jusqu'au keyframe suivant (à 0,75 s : ${at(0.75 * TPS)} ; avant : rampe 100 → 0)`);
  check(pts.some((p) => p.ticks === TPS && p.value === 0), "puis coupe à 0 au keyframe suivant");
}

console.log(failures === 0 ? "EASE OK" : `EASE : ${failures} échec(s)`);
process.exit(failures === 0 ? 0 : 1);
