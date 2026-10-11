/* Test hors Premiere de la règle « noms de paramètres et langue »
 * (apply.js, buildParamActions / relativeKind). UXP est simulé : ce test
 * vérifie la DÉCISION écrire/sauter, pas le rendu dans Premiere.
 *
 *   node plugin/test/param-names.test.js            (sources du dépôt)
 *   node plugin/test/param-names.test.js <apply.js> (une autre version, ex. avant correctif)
 */
const Module = require("module");
const path = require("path");

const fakePpro = {
  Keyframe: { INTERPOLATION_MODE_LINEAR: 0, INTERPOLATION_MODE_BEZIER: 5, INTERPOLATION_MODE_HOLD: 4 },
  TickTime: { createWithTicks: (t) => ({ ticks: t }) },
  PointF: function (x, y) { this.x = x; this.y = y; },
  Color: function (r, g, b, a) { Object.assign(this, { r, g, b, a }); },
};
const resolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  return request === "premierepro" ? "premierepro" : resolve.call(this, request, ...rest);
};
require.cache.premierepro = { id: "premierepro", filename: "premierepro", loaded: true, exports: fakePpro };

const target = process.argv[2] ? path.resolve(process.argv[2]) : path.join(__dirname, "../src/premiere/apply.js");
const apply = require(target);

/* Composant simulé : noms tels que Premiere les AFFICHE (sa langue à lui). */
function component(liveNames) {
  return {
    getParamCount: () => liveNames.length,
    getParam: (i) => ({
      displayName: liveNames[i],
      createKeyframe: (value) => ({ value }),
      createSetValueAction: () => ({ kind: "set", index: i }),
      createSetTimeVaryingAction: () => ({ kind: "tv", index: i }),
      createAddKeyframeAction: () => ({ kind: "kf", index: i }),
    }),
  };
}

// Transform (AE.ADBE Geometry2), 12 paramètres — noms d'un preset enregistré
// dans un Premiere ANGLAIS (pack du commerce), et ce qu'affiche un Premiere français.
const EN = ["Anchor Point", "Position", "", "Scale Height", "Scale Width", "Skew", "Skew Axis", "Rotation", "Opacity", "", "Shutter Angle", "Sampling"];
const FR = ["Point d'ancrage", "Position", "", "Hauteur d'échelle", "Largeur d'échelle", "Inclinaison", "Axe d'inclinaison", "Rotation", "Opacité", "", "Angle d'obturateur", "Échantillonnage"];
const presetParams = EN.map((name, index) => ({ index, name, value: index === 1 ? { x: 0.5, y: 0.5 } : 50 }));
const timeCtx = { inTicks: 0, durTicks: 254016000000 };

function run(liveNames, expectedCount) {
  const fidelity = { paramsSet: 0, paramsSkipped: 0, detail: [] };
  const built = apply.buildParamActions(component(liveNames), presetParams, fidelity, timeCtx, { type: 1, srcDur: "0" }, 8467200000, expectedCount);
  // Depuis l'audit P-06 (2026-10-09), buildParamActions RENVOIE le nombre de
  // réglages construits (l'appelant ne les compte posés qu'après une
  // transaction réussie) ; les versions antérieures incrémentaient paramsSet.
  if (built && typeof built.built === "number") fidelity.paramsSet = built.built;
  return fidelity;
}

let failures = 0;
function check(cond, label) {
  console.log(`${cond ? "  ✓" : "  ✗"} ${label}`);
  if (!cond) failures += 1;
}

const same = run(EN, 12);
check(same.paramsSet === 12 && same.paramsSkipped === 0, `même langue : 12/12 écrits (obtenu ${same.paramsSet}/12)`);

const cross = run(FR, 12);
console.log(`    preset anglais dans un Premiere français : ${cross.paramsSet}/12 écrits, ${cross.paramsSkipped} sautés`);
check(cross.paramsSet === 12 && cross.paramsSkipped === 0, "autre langue, même structure : tout est écrit");

const shifted = run(FR.concat(["Nouveau réglage"]), 12);
check(shifted.paramsSkipped > 0 && shifted.detail.some((d) => d.reason === "PARAM_STRUCTURE_MISMATCH"),
  `structure différente (13 ≠ 12) : les noms non vérifiables restent sautés (${shifted.paramsSkipped} sautés)`);

const unknown = run(FR, 0);
check(unknown.paramsSkipped > 0, "structure inconnue + noms différents : prudence, sauté");

if (apply.sameParamName) {
  check(apply.sameParamName("Échelle", " echelle "), "accents, casse et espaces ignorés");
}
if (apply.relativeKind && apply.relativeKind.length >= 1) {
  check(apply.relativeKind(["Skalierung"], 100) === "factor", "échelle reconnue en allemand");
  check(apply.relativeKind(["Rotación"], 10) === "delta", "rotation reconnue en espagnol");
  check(apply.relativeKind(["Поворот"], 10) === "delta", "rotation reconnue en russe");
  check(apply.relativeKind(["Opacity", "Opacité"], 100) === null, "opacité reste absolue");
  check(apply.relativeKind(["Position"], { x: 0.5, y: 0.5 }) === "offset", "position = décalage");
}

console.log(failures === 0 ? "PARAM-NAMES OK" : `PARAM-NAMES : ${failures} échec(s)`);
process.exit(failures === 0 ? 0 : 1);
