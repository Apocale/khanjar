/* P-06 (audit du 2026-10-08) : un réglage n'est compté « posé » qu'après une
 * transaction réussie ; un réglage qui lève en route ne laisse aucune action
 * partielle. Vrai apply(), Premiere simulé (fake-premiere.js, données
 * synthétiques).
 *
 *   node plugin/test/params-refused.test.js
 */
const fake = require("./fake-premiere");
const { apply } = require("../src/premiere/apply");

const { check, done } = fake.checker("PARAMS-REFUSED");
const TPS = fake.TPS;

fake.defineEffect("SYN.Shadow", [{ name: "Opacity", value: 0 }, { name: "Distance", value: 0 }, { name: "Softness", value: 0 }]);
fake.defineEffect("SYN.Glow", [{ name: "Radius", value: 0 }, { name: "Intensity", value: 0 }]);

const PARAMS_PER_CLIP = 3;
const staticPlan = () => fake.plan("Ombre et lueur", [
  fake.op("SYN.Shadow", [{ index: 0, name: "Opacity", value: 60 }, { index: 1, name: "Distance", value: 12 }]),
  fake.op("SYN.Glow", [{ index: 0, name: "Radius", value: 30 }]),
]);

function clips(n) {
  return Array.from({ length: n }, (_, i) => new fake.TrackItem({ name: `clip ${i}` }));
}
function effectsOf(plan) { return plan.operations.map((o) => o.effect.matchName); }

(async () => {
  // 1. Premiere refuse les réglages d'UN clip sur 3 (transaction tout ou rien).
  {
    const selection = clips(3);
    const plan = staticPlan();
    fake.reset({ selection, effects: effectsOf(plan) });
    const refused = selection[1];
    fake.hooks.refuseTransaction = (ctx) => ctx.actions.some((a) => a.item === refused && a.kind !== "insert" && a.kind !== "append");
    const res = await apply(plan, {});
    const f = res.fidelity;
    console.log(`    réponse : paramsSet=${f.paramsSet} paramsSkipped=${f.paramsSkipped} paramsFailedClips=${JSON.stringify(f.paramsFailedClips)}`);
    check(f.paramsSet === 2 * PARAMS_PER_CLIP, `réglages posés comptés sur 2 clips sur 3 (${f.paramsSet}/${3 * PARAMS_PER_CLIP})`);
    check(f.paramsSkipped === PARAMS_PER_CLIP, `réglages du clip refusé comptés sautés (${f.paramsSkipped})`);
    check(JSON.stringify(f.paramsFailedClips) === JSON.stringify(["clip 1"]), "paramsFailedClips = [clip 1]");
    check(f.detail.some((d) => d.reason === "PARAMS_NOT_SET" && d.clip === "clip 1"), "raison PARAMS_NOT_SET pour clip 1");
    check(refused.component("SYN.Shadow").param("Opacity").value === 0, "réalité : clip 1 garde les valeurs par défaut (rien d'annoncé à tort)");
    check(selection[0].component("SYN.Shadow").param("Opacity").value === 60 && selection[2].component("SYN.Glow").param("Radius").value === 30,
      "réalité : clips 0 et 2 réglés");
    check(res.applied.clips === 3 && res.skipped.failedClips.length === 0, "les effets restent posés sur les 3 clips (insertion réussie)");
  }

  // 2. Un réglage animé qui lève au 3ᵉ keyframe : aucune action partielle.
  {
    const selection = clips(1);
    const keyframes = [0, 0.25, 0.5, 0.75, 1].map((s, k) => ({ t: String(s * TPS), value: k * 10, i: 0 }));
    const plan = fake.plan("Lueur animée", [
      fake.op("SYN.Glow", [{ index: 0, name: "Radius", value: 0, keyframes }, { index: 1, name: "Intensity", value: 7 }]),
    ]);
    fake.reset({ selection, effects: effectsOf(plan) });
    let n = 0;
    fake.hooks.createKeyframe = (param) => {
      if (param.displayName === "Radius" && ++n === 3) throw new Error("valeur refusée");
    };
    const res = await apply(plan, {});
    const radius = selection[0].component("SYN.Glow").param("Radius");
    const touched = (fake.stats.kinds.tv || 0) + (fake.stats.kinds.kf || 0);
    check(radius.keyframes.size === 0 && radius.varying === false && touched === 0,
      `réglage en échec au 3ᵉ keyframe : ni animation activée ni keyframe posé (${radius.keyframes.size} keyframe(s), ${touched} action(s))`);
    check(res.fidelity.paramsSkipped === 1 && res.fidelity.paramsSet === 1, `compté 1 sauté, 1 posé (${res.fidelity.paramsSkipped}/${res.fidelity.paramsSet})`);
    check(selection[0].component("SYN.Glow").param("Intensity").value === 7, "l'autre réglage de l'effet est posé");
  }

  // 3. Intrinsèque absent du clip (Vector Motion sur un clip vidéo) : réglages comptés sautés.
  {
    const selection = clips(2);
    const plan = fake.plan("Vector Motion", [], [
      fake.op("AE.ADBE Graphic Group", [{ index: 1, name: "Scale", value: 80 }, { index: 4, name: "Rotation", value: 10 }], { paramCount: 11 }),
    ]);
    fake.reset({ selection, effects: [] });
    const res = await apply(plan, { relativeToClip: false });
    check(res.fidelity.paramsSkipped === 4 && res.fidelity.paramsSet === 0,
      `INTRINSIC_NOT_ON_CLIP : 4 réglages comptés sautés sur 2 clips (avant : 0) — obtenu ${res.fidelity.paramsSkipped}`);
  }

  // 4. In-point illisible : réglages animés non posés (IN_POINT_UNREADABLE), fixes posés.
  {
    const selection = [new fake.TrackItem({ name: "sous-titre", inPointThrows: true, inTicks: 3600 * TPS })];
    const keyframes = [{ t: "0", value: 0, i: 0 }, { t: String(TPS), value: 100, i: 0 }];
    const plan = fake.plan("Lueur", [
      fake.op("SYN.Glow", [{ index: 0, name: "Radius", value: 0, keyframes }, { index: 1, name: "Intensity", value: 7 }]),
    ]);
    fake.reset({ selection, effects: effectsOf(plan) });
    const res = await apply(plan, {});
    const glow = selection[0].component("SYN.Glow");
    check(glow.param("Radius").keyframes.size === 0, "in-point illisible : aucun keyframe posé (ils seraient partis 1 h trop tôt)");
    check(glow.param("Intensity").value === 7, "in-point illisible : la valeur fixe est posée");
    check(res.fidelity.detail.some((d) => d.reason === "IN_POINT_UNREADABLE") && res.fidelity.paramsSkipped === 1,
      `raison IN_POINT_UNREADABLE, 1 réglage sauté (${res.fidelity.paramsSkipped})`);
  }

  // 5. Relecture de la chaîne impossible avant les réglages (preset intrinsèque) :
  //    réglages comptés sautés + clip dans paramsFailedClips.
  {
    const selection = clips(2);
    const plan = fake.plan("Opacité", [], [fake.op("AE.ADBE Opacity", [{ index: 0, name: "Opacity", value: 40 }], { paramCount: 2 })]);
    fake.reset({ selection, effects: [] });
    const calls = new Map();
    fake.hooks.getComponentChain = (item) => {
      const k = (calls.get(item) || 0) + 1;
      calls.set(item, k);
      if (item === selection[0] && k === 2) throw new Error("chaîne illisible");
    };
    const res = await apply(plan, {});
    check(JSON.stringify(res.fidelity.paramsFailedClips) === JSON.stringify(["clip 0"]) && res.fidelity.paramsSkipped === 1,
      `relecture ratée : clip 0 dans paramsFailedClips, 1 réglage sauté (${JSON.stringify(res.fidelity.paramsFailedClips)}, ${res.fidelity.paramsSkipped})`);
    check(selection[1].component("AE.ADBE Opacity").param("Opacity").value === 40 && res.fidelity.paramsSet === 1, "l'autre clip est réglé");
  }

  // ── P-11 : échecs de préparation, clip par clip ──
  // 6. createComponent lève sur le clip 2 : clips 1 et 3 appliqués, clip 2 en échec.
  {
    const selection = clips(3);
    const plan = staticPlan();
    fake.reset({ selection, effects: effectsOf(plan) });
    // 2 effets par clip : les appels 3 et 4 préparent le clip 2 (« clip 1 »).
    fake.hooks.createComponent = (matchName, n) => { if (n === 3) throw new Error("création impossible"); };
    let res = null, error = null;
    try { res = await apply(plan, {}); } catch (e) { error = e; }
    check(!error, `createComponent qui lève sur un clip : pas d'échec global (${error ? error.code : "ok"})`);
    if (res) {
      check(res.applied.clips === 2 && JSON.stringify(res.applied.clipNames) === JSON.stringify(["clip 0", "clip 2"]), "clips 1 et 3 appliqués");
      check(JSON.stringify(res.skipped.failedClips) === JSON.stringify(["clip 1"]) && res.skipped.reason === "PREPARE_FAILED",
        `clip 2 dans failedClips, raison PREPARE_FAILED (${JSON.stringify(res.skipped)})`);
      check(selection[1].components.length === 2, "clip 2 inchangé");
    }
  }

  // 7. Chaîne illisible sur un clip VIDÉO : signalé (avant : compté comme audio, tu).
  {
    const selection = clips(2);
    const plan = staticPlan();
    fake.reset({ selection, effects: effectsOf(plan) });
    fake.hooks.getComponentChain = (item) => { if (item === selection[0]) throw new Error("chaîne illisible"); };
    const res = await apply(plan, {});
    check(JSON.stringify(res.skipped.failedClips) === JSON.stringify(["clip 0"]) && res.applied.clips === 1,
      `clip vidéo à chaîne illisible : dans failedClips (${JSON.stringify(res.skipped)})`);
  }

  // 8. Tous les clips vidéo en échec de préparation : TRANSACTION_FAILED, pas « sélectionne un clip vidéo ».
  {
    const selection = clips(2);
    const plan = staticPlan();
    fake.reset({ selection, effects: effectsOf(plan) });
    fake.hooks.createComponent = () => null;
    let code = null;
    try { await apply(plan, {}); } catch (e) { code = e.code; }
    check(code === "TRANSACTION_FAILED", `tous en échec de préparation : ${code} (avant : NO_APPLICABLE_CLIP)`);
  }

  // 9. Que de l'audio : NO_APPLICABLE_CLIP (inchangé).
  {
    const selection = [new fake.TrackItem({ name: "son", kind: "audio" })];
    const plan = staticPlan();
    fake.reset({ selection, effects: effectsOf(plan) });
    let code = null;
    try { await apply(plan, {}); } catch (e) { code = e.code; }
    check(code === "NO_APPLICABLE_CLIP", `que de l'audio : ${code}`);
  }

  done();
})().catch((e) => { console.error(e); process.exit(1); });
