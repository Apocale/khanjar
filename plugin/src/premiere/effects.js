/* Énumération des effets disponibles (matchNames + displayNames).
 * Les deux listes de VideoFilterFactory sont parallèles (même index). */
const { ppro } = require("./context");

async function listEffects() {
  const matchNames = await ppro.VideoFilterFactory.getMatchNames();
  const displayNames = await ppro.VideoFilterFactory.getDisplayNames();

  const video = matchNames.map((matchName, i) => ({
    matchName,
    displayName: displayNames[i] !== undefined ? displayNames[i] : matchName,
  }));

  // Audio : displayNames uniquement (AudioFilterFactory n'expose pas de
  // matchNames et crée par displayName — capability désactivée en v1,
  // on remonte quand même l'inventaire pour l'indexation future).
  let audio = [];
  try {
    const audioNames = await ppro.AudioFilterFactory.getDisplayNames();
    audio = (audioNames || []).map((displayName) => ({ displayName }));
  } catch (e) { /* API absente/instable : capability audio reste false */ }

  return {
    video,
    audio,
    counts: { video: video.length, audio: audio.length },
  };
}

module.exports = { listEffects };
