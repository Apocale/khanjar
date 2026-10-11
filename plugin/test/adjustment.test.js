/* P-05 (audit du 2026-10-08) : ⌘⇧J — jamais un chutier ni un média pris pour
 * le calque d'effets, noms des 10 langues, autres séquences, piste libre sur
 * toute la durée du calque. Vrai addAdjustmentLayer(), projet simulé
 * (fake-premiere.js, données synthétiques).
 *
 *   node plugin/test/adjustment.test.js
 */
const fake = require("./fake-premiere");
const { addAdjustmentLayer, normalizeName } = require("../src/premiere/adjustment");

const { check, done } = fake.checker("ADJUSTMENT");
const TPS = fake.TPS;
const S = (s) => Math.round(s * TPS);

/* Séquence active : V1 couvre la tête de lecture (10 s) ; autres pistes au choix. */
function setup({ root, tracks, playhead = S(10), others = [] }) {
  const seq = fake.reset({});
  seq.playhead = playhead;
  seq.tracks = tracks || [[fake.timelineItem({ start: 0, end: S(60), name: "A-roll" })], []];
  fake.state.root = root || fake.folder("root", []);
  fake.state.sequences = [seq, ...others];
  return seq;
}
const baseOf = (item) => (item && item.__base) || item;

(async () => {
  // 1. Chutier « Adjustment Layers » contenant « Adjustment Layer » : le CLIP, jamais le dossier.
  {
    const layer = fake.clipItem("Adjustment Layer", { inTicks: 0, outTicks: S(5) });
    const seq = setup({ root: fake.folder("root", [fake.folder("Adjustment Layers", [layer])]) });
    const res = await addAdjustmentLayer();
    const posed = seq.overwrites[0];
    check(posed && baseOf(posed.item) === layer, "calque rangé dans un chutier : le calque est posé, pas le chutier");
    check(res.trackIndex === 1 && posed.videoTrackIndex === 1, `sur V2, au-dessus du contenu (piste ${res.trackIndex + 1})`);
    check(posed.at === S(10), "à la tête de lecture");
  }

  // 2. Seul un « color adjust.mov » à la racine : aucun calque, rien n'est posé.
  {
    const seq = setup({ root: fake.folder("root", [fake.clipItem("color adjust.mov"), fake.sequenceItem("Adjusted cut")]) });
    let code = null;
    try { await addAdjustmentLayer(); } catch (e) { code = e.code; }
    check(code === "ADJUSTMENT_NOT_FOUND" && seq.overwrites.length === 0, `« color adjust.mov » ignoré : ${code}, rien posé`);
  }

  // 3. Noms localisés et variantes.
  for (const name of ["Capa de ajuste", "Calque de réglage", "Calque d’effets", "Einstellungsebene",
    "調整レイヤー", "Корректирующий слой", "Adjustment Layer 2", "Adjustment Layer"]) {
    const layer = fake.clipItem(name);
    const seq = setup({ root: fake.folder("root", [fake.folder("Effets", [fake.folder("Sous-chutier", [layer])])]) });
    let ok = false;
    try { await addAdjustmentLayer(); ok = seq.overwrites.length === 1 && baseOf(seq.overwrites[0].item) === layer; } catch (e) { ok = false; }
    check(ok, `« ${name} » trouvé (dans un sous-chutier)`);
  }

  // 4. Une SÉQUENCE nommée comme un calque n'est jamais posée.
  {
    const seq = setup({ root: fake.folder("root", [fake.sequenceItem("Adjustment Layer")]) });
    let code = null;
    try { await addAdjustmentLayer(); } catch (e) { code = e.code; }
    check(code === "ADJUSTMENT_NOT_FOUND" && seq.overwrites.length === 0, "séquence « Adjustment Layer » : ignorée");
  }

  // 5. V2 libre à la tête de lecture mais occupée 1 s plus loin : piste suivante.
  {
    const layer = fake.clipItem("Adjustment Layer", { inTicks: 0, outTicks: S(5) });
    const broll = fake.timelineItem({ start: S(11), end: S(20), name: "B-roll" });
    const seq = setup({
      root: fake.folder("root", [layer]),
      tracks: [[fake.timelineItem({ start: 0, end: S(60) })], [broll], []],
    });
    const res = await addAdjustmentLayer();
    check(res.trackIndex === 2, `B-roll sur V2 1 s après la tête : calque sur V3 (piste ${res.trackIndex + 1}), V2 intact`);
    // Sans V3 : piste neuve au sommet.
    const seq2 = setup({
      root: fake.folder("root", [fake.clipItem("Adjustment Layer", { inTicks: 0, outTicks: S(5) })]),
      tracks: [[fake.timelineItem({ start: 0, end: S(60) })], [fake.timelineItem({ start: S(11), end: S(20) })]],
    });
    const res2 = await addAdjustmentLayer();
    check(res2.trackIndex === 2 && seq2.overwrites[0].videoTrackIndex === 2, "aucune piste libre : index d'une piste neuve (2)");
    // Calque court (2 s) : le B-roll 3 s plus loin ne gêne pas.
    setup({
      root: fake.folder("root", [fake.clipItem("Adjustment Layer", { inTicks: 0, outTicks: S(2) })]),
      tracks: [[fake.timelineItem({ start: 0, end: S(60) })], [fake.timelineItem({ start: S(13), end: S(20) })]],
    });
    const res3 = await addAdjustmentLayer();
    check(res3.trackIndex === 1, "calque de 2 s, B-roll 3 s plus loin : V2 reste utilisable");
    // Durée inconnue : tout clip après la tête bloque la piste.
    setup({
      root: fake.folder("root", [fake.clipItem("Adjustment Layer")]),
      tracks: [[fake.timelineItem({ start: 0, end: S(60) })], [fake.timelineItem({ start: S(50), end: S(55) })], []],
    });
    const res4 = await addAdjustmentLayer();
    check(res4.trackIndex === 2, "durée du calque inconnue : V2 (clip 40 s plus loin) évitée");
  }

  // 6. Calque déjà posé dans la séquence active : réutilisé, sa durée compte.
  {
    const src = fake.clipItem("Mon calque renommé");
    const seq = setup({
      tracks: [[fake.timelineItem({ start: 0, end: S(60) })],
        [fake.timelineItem({ start: S(30), end: S(34), adjustment: true, projectItem: src })], []],
    });
    const res = await addAdjustmentLayer();
    check(baseOf(seq.overwrites[0].item) === src, "calque de la séquence active (nom quelconque) réutilisé");
    check(res.trackIndex === 1, `calque de 4 s : V2 libre de 10 à 14 s → V2 (piste ${res.trackIndex + 1})`);
  }

  // 7. Calque présent seulement dans UNE AUTRE séquence : trouvé sans le nom.
  {
    const src = fake.clipItem("Réglage couleur");
    const other = fake.makeSequence({ name: "Autre", tracks: [[fake.timelineItem({ start: 0, end: S(3), adjustment: true, projectItem: src })]] });
    const seq = setup({ others: [other] });
    await addAdjustmentLayer();
    check(seq.overwrites.length === 1 && baseOf(seq.overwrites[0].item) === src, "calque d'une autre séquence réutilisé (indépendant de la langue)");
  }

  // 8. Transaction refusée : TRANSACTION_FAILED (message S17 côté app).
  {
    setup({ root: fake.folder("root", [fake.clipItem("Adjustment Layer")]) });
    fake.hooks.refuseTransaction = () => true;
    let code = null;
    try { await addAdjustmentLayer(); } catch (e) { code = e.code; }
    check(code === "TRANSACTION_FAILED", `transaction refusée : ${code}`);
  }

  check(normalizeName("  Calque d’Effets 03 ") === "calque d'effets", "normalisation : casse, insécable, apostrophe, suffixe numérique");

  done();
})().catch((e) => { console.error(e); process.exit(1); });
