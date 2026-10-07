/* Inspection de la sélection courante (lecture seule). */
const { requireProject, requireSequence, selectionItems } = require("./context");

async function getSelection() {
  const project = await requireProject();
  let projectName = "?";
  try { projectName = await project.name; } catch (e) { /* non bloquant */ }

  let sequence = null;
  try { sequence = await requireSequence(project); } catch (e) {
    return { items: [], count: 0, project: projectName, hasSequence: false };
  }

  const items = await selectionItems(sequence);
  const described = [];
  for (const item of items) {
    let name = "(sans nom)";
    try { name = await item.getName(); } catch (e) { /* API name absente */ }
    described.push({ name });
  }
  return {
    items: described,
    count: described.length,
    project: projectName,
    hasSequence: true,
  };
}

module.exports = { getSelection };
