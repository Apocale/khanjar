/* Pose d'un calque d'effets (adjustment layer) à la tête de lecture.
 *
 * L'API UXP 26.3 ne permet PAS de CRÉER un adjustment layer (aucune API de
 * création d'items synthétiques) — mais elle permet de le DÉTECTER
 * (trackItem.isAdjustmentLayer()) et d'insérer un ProjectItem existant
 * (sequence.createOverwriteItemAction). Stratégie :
 *   1. chercher un adjustment layer déjà posé dans la séquence active
 *      (→ getProjectItem()) ;
 *   2. sinon, dans les AUTRES séquences du projet (même test, indépendant de
 *      la langue), si l'API les expose ;
 *   3. sinon, dans le chutier par nom exact, localisé ;
 *   4. sinon, erreur explicite : l'utilisateur en crée un une fois
 *      (Fichier > Nouveau > Calque d'effets) et c'est réglé pour toujours.
 * Piste cible : la première piste AU-DESSUS du contenu à la tête de lecture
 * qui soit libre sur toute la durée du calque ; à défaut, une piste neuve au
 * sommet.
 *
 * 2026-10-09 (audit P-05 ; A1#5, B1, B2#4, B3#5, B4#4) — CAUSES :
 *  - le nom était testé sur CHAQUE élément du chutier, dossiers compris, avant
 *    d'y descendre : un chutier « Adjustment Layers » était renvoyé (échec à
 *    chaque ⌘⇧J), un « color adjust.mov » était posé (son son sur A1) ;
 *  - les sous-chutiers n'étaient probablement jamais parcourus (getItems sur
 *    un ProjectItem non converti en FolderItem) ;
 *  - les noms étaient faux hors anglais (« effektebene », « capa de ajustes »…) ;
 *  - la piste n'était jugée libre qu'à l'instant de la tête de lecture, alors
 *    que l'écrasement couvre toute la durée du calque : un B-roll 1 s plus
 *    loin sur la même piste était écrasé, sans message.
 * CORRECTIONS ci-dessous ; à vérifier dans Premiere : T-05 (sous-chutiers,
 * nom exact du calque en français, création d'une piste neuve).
 */
const { ppro, requireProject, requireSequence } = require("./context");
const { CmdError, CODES } = require("./errors");

/* Recherche dans les autres séquences bornée dans le temps (gros projets). */
const OTHER_SEQUENCES_BUDGET_MS = 1500;

/* Noms par défaut d'un calque d'effets dans les 10 langues de Premiere
 * (dictionnaires de Premiere 2026 relevés par l'audit B2#4 ; le français a
 * deux libellés : celui du menu et celui de l'élément créé). Comparés après
 * normalizeName. */
const ADJUSTMENT_NAMES = new Set([
  "adjustment layer",
  "calque d'effets",
  "calque de réglage",
  "einstellungsebene",
  "capa de ajuste",
  "livello di regolazione",
  "camada de ajuste",
  "調整レイヤー",
  "조정 레이어",
  "корректирующий слой",
  "调整图层",
]);

/* Minuscules, apostrophe typographique → droite, espaces (insécables compris)
 * repliés, suffixe numérique retiré (« Adjustment Layer 2 »). */
function normalizeName(name) {
  let s = String(name == null ? "" : name);
  try { s = s.normalize("NFC"); } catch (e) { /* sans normalize : comparaison brute */ }
  s = s.toLowerCase().replace(/[’‘ʼ]/g, "'").replace(/\s+/g, " ").trim();
  return s.replace(/\s*[([]?\d+[)\]]?$/, "").trim();
}

function ticksOf(time) {
  if (time == null) return null;
  let n = Number(time.ticksNumber);
  if (!isFinite(n)) n = Number(time.ticks);
  return isFinite(n) ? n : null;
}

/* Vue « dossier » d'un élément du chutier, ou null. */
function asFolder(item) {
  try {
    if (ppro.FolderItem && typeof ppro.FolderItem.cast === "function") {
      const folder = ppro.FolderItem.cast(item);
      if (folder) return folder;
    }
  } catch (e) { /* cast refusé : pas un dossier */ }
  return item && typeof item.getItems === "function" ? item : null;
}

/* Vue « élément de clip » d'un élément du chutier, ou null. */
function asClip(item) {
  try {
    if (ppro.ClipProjectItem && typeof ppro.ClipProjectItem.cast === "function") {
      return ppro.ClipProjectItem.cast(item) || null;
    }
  } catch (e) { return null; }
  return item; // API absente : le nom exact a déjà été vérifié
}

function sequenceId(sequence) {
  try {
    const g = sequence && sequence.guid;
    if (g == null) return null;
    const s = typeof g === "string" ? g : (typeof g.toString === "function" ? g.toString() : null);
    return s && s !== "[object Object]" ? s : null;
  } catch (e) { return null; }
}

/* Premier calque d'effets posé dans une séquence → { source, durTicks }. */
async function findInSequence(sequence, deadline) {
  const trackCount = await sequence.getVideoTrackCount();
  for (let t = 0; t < trackCount; t++) {
    if (deadline && Date.now() > deadline) return null;
    const track = await sequence.getVideoTrack(t);
    const items = await track.getTrackItems(ppro.Constants.TrackItemType.CLIP, false);
    for (const item of items || []) {
      try {
        if (!(await item.isAdjustmentLayer())) continue;
        const source = await item.getProjectItem();
        if (!source) continue;
        let durTicks = null;
        try {
          const start = ticksOf(await item.getStartTime());
          const end = ticksOf(await item.getEndTime());
          if (start != null && end != null && end > start) durTicks = end - start;
        } catch (e) { /* durée inconnue : prudence maximale sur la piste */ }
        return { source, durTicks };
      } catch (e) { /* item non applicable : suivant */ }
    }
  }
  return null;
}

/* Autres séquences du projet (détection de l'API, recherche bornée). */
async function findInOtherSequences(project, active) {
  if (typeof project.getSequences !== "function") return null;
  const deadline = Date.now() + OTHER_SEQUENCES_BUDGET_MS;
  let sequences = [];
  try { sequences = (await project.getSequences()) || []; } catch (e) { return null; }
  const activeId = sequenceId(active);
  for (const sequence of sequences) {
    if (Date.now() > deadline) break;
    if (!sequence || sequence === active || (activeId && sequenceId(sequence) === activeId)) continue;
    try {
      const found = await findInSequence(sequence, deadline);
      if (found) return found;
    } catch (e) { /* séquence illisible : suivante */ }
  }
  return null;
}

async function clipDuration(clip) {
  try {
    if (typeof clip.getInPoint !== "function" || typeof clip.getOutPoint !== "function") return null;
    const video = ppro.Constants && ppro.Constants.MediaType ? ppro.Constants.MediaType.VIDEO : undefined;
    const a = ticksOf(await clip.getInPoint(video));
    const b = ticksOf(await clip.getOutPoint(video));
    return a != null && b != null && b > a ? b - a : null;
  } catch (e) { return null; }
}

/* Chutier, en largeur : on DESCEND dans les dossiers, on n'en renvoie jamais
 * un ; candidat = élément de clip (pas une séquence) au nom exact localisé. */
async function findInBin(project) {
  const root = await project.getRootItem();
  const queue = root ? [root] : [];
  while (queue.length > 0) {
    const folder = queue.shift();
    let children = [];
    try { children = (await folder.getItems()) || []; } catch (e) { continue; }
    for (const child of children) {
      const sub = asFolder(child);
      if (sub) { queue.push(sub); continue; }
      if (!ADJUSTMENT_NAMES.has(normalizeName(child && child.name))) continue;
      const clip = asClip(child);
      if (!clip) continue;
      try {
        if (typeof clip.isSequence === "function" && (await clip.isSequence())) continue;
      } catch (e) { continue; }
      return { source: child, durTicks: await clipDuration(clip) };
    }
  }
  return null;
}

/* Première piste au-dessus du contenu à la tête de lecture, libre sur TOUT
 * [tête, tête + durée] (durée inconnue : jusqu'à la fin de la séquence) ; à
 * défaut, l'index d'une piste neuve au sommet. Une piste illisible n'est
 * jamais choisie (on ne risque pas d'y écraser un clip). */
async function targetTrackIndex(sequence, playheadTicks, durTicks) {
  const trackCount = await sequence.getVideoTrackCount();
  const tracks = [];
  let highestAtPlayhead = -1;
  for (let t = 0; t < trackCount; t++) {
    const spans = [];
    let readable = true;
    try {
      const track = await sequence.getVideoTrack(t);
      const items = await track.getTrackItems(ppro.Constants.TrackItemType.CLIP, false);
      for (const item of items || []) {
        const start = ticksOf(await item.getStartTime());
        const end = ticksOf(await item.getEndTime());
        if (start == null || end == null) { readable = false; continue; }
        spans.push([start, end]);
        if (playheadTicks >= start && playheadTicks < end) highestAtPlayhead = Math.max(highestAtPlayhead, t);
      }
    } catch (e) { readable = false; }
    tracks.push({ spans, readable });
  }
  const until = durTicks != null && durTicks > 0 ? playheadTicks + durTicks : Infinity;
  for (let t = highestAtPlayhead + 1; t < trackCount; t++) {
    if (!tracks[t].readable) continue;
    const busy = tracks[t].spans.some(([start, end]) => start < until && end > playheadTicks);
    if (!busy) return t;
  }
  // Piste neuve au sommet : création automatique par Premiere à vérifier (T-05).
  return trackCount;
}

async function addAdjustmentLayer() {
  const project = await requireProject();
  const sequence = await requireSequence(project);

  let found = await findInSequence(sequence);
  if (!found) found = await findInOtherSequences(project, sequence);
  if (!found) found = await findInBin(project);
  if (!found) {
    throw new CmdError(
      CODES.ADJUSTMENT_NOT_FOUND,
      "Aucun calque d'effets dans le projet — créez-en un une fois (Fichier > Nouveau > Calque d'effets)"
    );
  }

  const playhead = await sequence.getPlayerPosition();
  const playheadTicks = ticksOf(playhead);
  const trackIndex = await targetTrackIndex(sequence, playheadTicks, found.durTicks);

  // Les éditions de séquence (overwrite/insert) sont sur SequenceEditor, PAS
  // sur Sequence (corrigé 2026-07-18 : sequence.createOverwriteItemAction
  // n'existe pas → le calque ne se posait jamais). Action créée DANS le
  // callback (AGENTS §3.1 items 1 et 9).
  const editor = ppro.SequenceEditor.getEditor(sequence);
  let success = false;
  try {
    project.lockedAccess(() => {
      success = project.executeTransaction((compoundAction) => {
        compoundAction.addAction(
          editor.createOverwriteItemAction(found.source, playhead, trackIndex, 0)
        );
      }, "Khanjar - Calque d'effets");
    });
  } catch (err) {
    throw new CmdError(CODES.TRANSACTION_FAILED, `Pose du calque d'effets refusée : ${err.message}`);
  }
  if (!success) throw new CmdError(CODES.TRANSACTION_FAILED, "Pose du calque d'effets refusée");

  return { trackIndex, atTicks: String(playheadTicks) };
}

module.exports = { addAdjustmentLayer, normalizeName, ADJUSTMENT_NAMES };
