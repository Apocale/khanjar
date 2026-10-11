/* P-07 (audit du 2026-10-08) : jamais d'effets en double après une insertion
 * partielle ou une relecture ratée. Vrai apply(), Premiere simulé
 * (fake-premiere.js, données synthétiques).
 *
 *   node plugin/test/partial-insert.test.js
 */
const fake = require("./fake-premiere");
const { apply } = require("../src/premiere/apply");

const { check, done } = fake.checker("PARTIAL-INSERT");

fake.defineEffect("SYN.Shadow", [{ name: "Opacity", value: 0 }, { name: "Distance", value: 0 }]);
fake.defineEffect("SYN.Edge", [{ name: "Border", value: 0 }]);
const PLAN = () => fake.plan("Ombre, contour, ombre", [
  fake.op("SYN.Shadow", [{ index: 0, name: "Opacity", value: 60 }]),
  fake.op("SYN.Edge", [{ index: 0, name: "Border", value: 4 }]),
  fake.op("SYN.Shadow", [{ index: 0, name: "Opacity", value: 30 }]),
]);
const EFFECTS = ["SYN.Shadow", "SYN.Edge"];
const added = (item) => item.components.length - 2;

function clips(n) {
  return Array.from({ length: n }, (_, i) => new fake.TrackItem({ name: `clip ${i}` }));
}

(async () => {
  // 1. La transaction groupée (non atomique) perd la 3ᵉ insertion du clip 1.
  //    (La dernière : perdre celle du milieu rendrait la suivante hors limites
  //    dans ce faux Premiere strict, et toute la transaction serait refusée.)
  {
    const selection = clips(2);
    fake.reset({ selection, effects: EFFECTS });
    let k = 0;
    fake.hooks.dropAction = (a, ctx) => ctx.index === 0 && a.kind === "insert" && a.item === selection[1] && ++k === 3;
    const res = await apply(PLAN(), {});
    console.log(`    clip 1 : chaîne finale = [${selection[1].names().join(", ")}]`);
    check(added(selection[1]) === 2, `clip 1 : 2 effets (les rescapés), jamais 5 (obtenu ${added(selection[1])})`);
    check(JSON.stringify(res.skipped.failedClips) === JSON.stringify(["clip 1"]), "clip 1 annoncé en échec");
    check(res.fidelity.detail.some((d) => d.reason === "PARTIAL_INSERT" && d.clip === "clip 1" && d.added === 2 && d.expected === 3),
      "raison PARTIAL_INSERT (2 sur 3)");
    check(added(selection[0]) === 3 && selection[0].components[2].param("Opacity").value === 60, "clip 0 : 3 effets réglés");
    check(res.applied.clips === 1, "1 clip appliqué");
  }

  // 2. La relecture de vérification lève UNE fois sur le clip 0 : aucun doublon.
  {
    const selection = clips(2);
    fake.reset({ selection, effects: EFFECTS });
    let armed = false, thrown = false;
    fake.hooks.afterTransaction = (ctx) => { if (ctx.index === 0) armed = true; };
    fake.hooks.getComponentChain = (item) => {
      if (armed && !thrown && item === selection[0]) { thrown = true; throw new Error("relecture en panne"); }
    };
    const res = await apply(PLAN(), {});
    check(thrown, "la relecture a bien levé une fois");
    check(added(selection[0]) === 3, `clip 0 : 3 effets, jamais 6 (obtenu ${added(selection[0])})`);
    check(res.applied.clips === 2 && res.skipped.failedClips.length === 0, "les 2 clips appliqués (2ᵉ relecture réussie)");
    check(selection[0].components[4].param("Opacity").value === 30, "réglages posés sur le bon bloc");
  }

  // 3. La relecture lève TOUJOURS sur le clip 0 : rien réinséré, clip en échec.
  {
    const selection = clips(2);
    fake.reset({ selection, effects: EFFECTS });
    let armed = false;
    fake.hooks.afterTransaction = (ctx) => { if (ctx.index === 0) armed = true; };
    fake.hooks.getComponentChain = (item) => { if (armed && item === selection[0]) throw new Error("relecture en panne"); };
    const res = await apply(PLAN(), {});
    check(added(selection[0]) === 3, `clip 0 : 3 effets, aucun réinséré (obtenu ${added(selection[0])})`);
    check(JSON.stringify(res.skipped.failedClips) === JSON.stringify(["clip 0"]) &&
      res.fidelity.detail.some((d) => d.reason === "READBACK_FAILED" && d.clip === "clip 0"),
      "clip 0 en échec, raison READBACK_FAILED");
    check(fake.stats.createComponent === 6, `aucune préparation de réinsertion (${fake.stats.createComponent} composants créés pour 2 clips × 3)`);
  }

  // 4. Rien reçu (delta = 0) : la réinsertion ciblée reste en place.
  {
    const selection = clips(2);
    fake.reset({ selection, effects: EFFECTS });
    fake.hooks.dropAction = (a, ctx) => ctx.index === 0 && a.kind === "insert" && a.item === selection[1];
    const res = await apply(PLAN(), {});
    check(added(selection[1]) === 3 && res.applied.clips === 2, `rien reçu → réinsertion : clip 1 a 3 effets (obtenu ${added(selection[1])})`);
    check(selection[1].components[2].param("Opacity").value === 60 && res.transaction === "per-clip", "réglés, transaction=per-clip");
  }

  done();
})().catch((e) => { console.error(e); process.exit(1); });
