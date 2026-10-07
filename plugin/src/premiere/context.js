/* Accès au contexte Premiere courant (projet, séquence, sélection),
 * avec erreurs typées. Aucune mise en cache : le plugin est sans état. */
const ppro = require("premierepro");
const { CmdError, CODES } = require("./errors");

async function requireProject() {
  const project = await ppro.Project.getActiveProject();
  if (!project) throw new CmdError(CODES.NO_PROJECT, "Aucun projet actif");
  return project;
}

async function requireSequence(project) {
  const sequence = await project.getActiveSequence();
  if (!sequence) throw new CmdError(CODES.NO_SEQUENCE, "Aucune séquence active");
  return sequence;
}

async function selectionItems(sequence) {
  const selection = await sequence.getSelection();
  const items = await selection.getTrackItems();
  return items || [];
}

module.exports = { ppro, requireProject, requireSequence, selectionItems };
