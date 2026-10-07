/* Pose d'un calque d'effets (adjustment layer) à la tête de lecture.
 *
 * L'API UXP 26.3 ne permet PAS de CRÉER un adjustment layer (aucune API de
 * création d'items synthétiques) — mais elle permet de le DÉTECTER
 * (trackItem.isAdjustmentLayer()) et d'insérer un ProjectItem existant
 * (sequence.createOverwriteItemAction). Stratégie :
 *   1. chercher un adjustment layer déjà posé dans la séquence active
 *      (→ getProjectItem()) ;
 *   2. sinon, chercher dans le chutier par nom (EN/FR) ;
 *   3. sinon, erreur explicite : l'utilisateur en crée un une fois
 *      (Fichier > Nouveau > Calque d'effets) et c'est réglé pour toujours.
 * Piste cible : la première piste libre à la tête de lecture AU-DESSUS du
 * contenu ; à défaut, une nouvelle piste au sommet.
 */
const { ppro, requireProject, requireSequence } = require("./context");
const { CmdError, CODES } = require("./errors");

async function findInActiveSequence(sequence) {
  const trackCount = await sequence.getVideoTrackCount();
  for (let t = 0; t < trackCount; t++) {
    const track = await sequence.getVideoTrack(t);
    const items = await track.getTrackItems(ppro.Constants.TrackItemType.CLIP, false);
    for (const item of items || []) {
      try {
        if (await item.isAdjustmentLayer()) return await item.getProjectItem();
      } catch (e) { /* item non applicable : suivant */ }
    }
  }
  return null;
}

async function findInBin(project) {
  const root = await project.getRootItem();
  const queue = [root];
  while (queue.length > 0) {
    const folder = queue.shift();
    let children = [];
    try { children = await folder.getItems(); } catch (e) { continue; }
    for (const child of children || []) {
      const name = (child.name || "").toLowerCase();
      if (/adjust|calque d.effets|effektebene|capa de ajustes/.test(name)) return child;
      // Dossier ? on descend (getItems échouera silencieusement sinon)
      queue.push(child);
    }
  }
  return null;
}

/* Première piste libre à la tête de lecture au-dessus du contenu. */
async function targetTrackIndex(sequence, playheadTicks) {
  const trackCount = await sequence.getVideoTrackCount();
  let highestOccupied = -1;
  for (let t = 0; t < trackCount; t++) {
    try {
      const track = await sequence.getVideoTrack(t);
      const items = await track.getTrackItems(ppro.Constants.TrackItemType.CLIP, false);
      for (const item of items || []) {
        const start = (await item.getStartTime()).ticksNumber;
        const end = (await item.getEndTime()).ticksNumber;
        if (playheadTicks >= start && playheadTicks < end) {
          highestOccupied = Math.max(highestOccupied, t);
          break;
        }
      }
    } catch (e) { /* piste illisible : ignorée */ }
  }
  // Piste juste au-dessus du contenu (créée automatiquement si hors bornes)
  return highestOccupied + 1;
}

async function addAdjustmentLayer() {
  const project = await requireProject();
  const sequence = await requireSequence(project);

  let source = await findInActiveSequence(sequence);
  if (!source) source = await findInBin(project);
  if (!source) {
    throw new CmdError(
      CODES.ADJUSTMENT_NOT_FOUND,
      "Aucun calque d'effets dans le projet — créez-en un une fois (Fichier > Nouveau > Calque d'effets)"
    );
  }

  const playhead = await sequence.getPlayerPosition();
  const trackIndex = await targetTrackIndex(sequence, playhead.ticksNumber);

  // Les éditions de séquence (overwrite/insert) sont sur SequenceEditor, PAS
  // sur Sequence (corrigé 2026-07-18 : sequence.createOverwriteItemAction
  // n'existe pas → le calque ne se posait jamais).
  const editor = ppro.SequenceEditor.getEditor(sequence);
  let success = false;
  project.lockedAccess(() => {
    success = project.executeTransaction((compoundAction) => {
      compoundAction.addAction(
        editor.createOverwriteItemAction(source, playhead, trackIndex, 0)
      );
    }, "Khanjar - Calque d'effets");
  });
  if (!success) throw new CmdError(CODES.TRANSACTION_FAILED, "Pose du calque d'effets refusée");

  return { trackIndex, atTicks: String(playhead.ticksNumber) };
}

module.exports = { addAdjustmentLayer };
