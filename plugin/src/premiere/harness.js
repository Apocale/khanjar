/* Harnais de test E2E (docs/ARCHITECTURE.md §9) — commandes réservées aux
 * tests, jamais appelées par le flux produit :
 *  - testSetup   : projet scratch + import d'un média + séquence + sélection ;
 *  - readParams  : relit les paramètres du dernier composant du clip
 *                  sélectionné → mesure de fidélité après un apply.
 */
const { ppro, requireProject, requireSequence, selectionItems } = require("./context");
const { CmdError, CODES } = require("./errors");
const { classifyTrackItem } = require("./apply");

async function testSetup(msg) {
  if (!msg.projectPath || !msg.mediaPath) {
    throw new CmdError(CODES.INTERNAL, "projectPath et mediaPath requis");
  }
  const project = await ppro.Project.createProject(msg.projectPath);
  if (!project) throw new CmdError(CODES.INTERNAL, "createProject a échoué");

  const imported = await project.importFiles([msg.mediaPath], true);
  if (!imported) throw new CmdError(CODES.INTERNAL, "importFiles a échoué");

  const root = await project.getRootItem();
  const items = await root.getItems();
  if (!items || items.length === 0) throw new CmdError(CODES.INTERNAL, "média importé introuvable");
  const clipItems = items.map((it) => ppro.ClipProjectItem.cast(it)).filter(Boolean);

  const sequence = await project.createSequenceFromMedia("Khanjar Test", clipItems);
  if (!sequence) throw new CmdError(CODES.INTERNAL, "createSequenceFromMedia a échoué");

  const track = await sequence.getVideoTrack(0);
  const trackItems = await track.getTrackItems(ppro.Constants.TrackItemType.CLIP, false);
  if (!trackItems || trackItems.length === 0) throw new CmdError(CODES.INTERNAL, "aucun trackItem dans la séquence de test");

  let selectionOk = false;
  ppro.TrackItemSelection.createEmptySelection((selection) => {
    selection.addItem(trackItems[0], true);
    selectionOk = sequence.setSelection(selection);
  });
  return {
    project: msg.projectPath,
    trackItems: trackItems.length,
    selectionOk,
  };
}

/* Crée un projet avec PLUSIEURS clips vidéo sur V1 et les sélectionne TOUS
 * (reproduction du bug multi-clips signalé 2026-07-14). mediaPaths = liste de
 * fichiers distincts (sinon Premiere dédoublonne à l'import). */
async function testSetupMulti(msg) {
  const paths = msg.mediaPaths || [];
  if (!msg.projectPath || paths.length === 0) {
    throw new CmdError(CODES.INTERNAL, "projectPath et mediaPaths requis");
  }
  const project = await ppro.Project.createProject(msg.projectPath);
  if (!project) throw new CmdError(CODES.INTERNAL, "createProject a échoué");

  const imported = await project.importFiles(paths, true);
  if (!imported) throw new CmdError(CODES.INTERNAL, "importFiles a échoué");

  const root = await project.getRootItem();
  const items = await root.getItems();
  const clipItems = (items || []).map((it) => ppro.ClipProjectItem.cast(it)).filter(Boolean);
  if (clipItems.length === 0) throw new CmdError(CODES.INTERNAL, "aucun média importé");

  const sequence = await project.createSequenceFromMedia("Khanjar Multi", clipItems);
  if (!sequence) throw new CmdError(CODES.INTERNAL, "createSequenceFromMedia a échoué");

  const track = await sequence.getVideoTrack(0);
  const trackItems = await track.getTrackItems(ppro.Constants.TrackItemType.CLIP, false);
  if (!trackItems || trackItems.length < 2) {
    throw new CmdError(CODES.INTERNAL, `séquence avec ${trackItems ? trackItems.length : 0} clip(s) seulement`);
  }

  let selectionOk = false;
  ppro.TrackItemSelection.createEmptySelection((selection) => {
    for (const ti of trackItems) selection.addItem(ti, true);
    selectionOk = sequence.setSelection(selection);
  });

  // Confirme ce que getSelection renvoie réellement (le cœur du diagnostic)
  const sel = await sequence.getSelection();
  const selItems = await sel.getTrackItems();
  return {
    project: msg.projectPath,
    clipsOnTrack: trackItems.length,
    selectionOk,
    selectionReturns: selItems ? selItems.length : 0,
  };
}

/* Pour CHAQUE clip sélectionné : nom + nombre de composants + matchName du
 * dernier composant (celui qu'un apply vient d'ajouter). */
async function dumpAllSelected() {
  const project = await requireProject();
  const sequence = await requireSequence(project);
  const items = await selectionItems(sequence);
  const clips = [];
  for (const item of items) {
    let name = "(sans nom)";
    try { name = await item.getName(); } catch (e) { /* ignore */ }
    let count = 0, last = "?";
    const chainDump = [];
    try {
      const chain = await item.getComponentChain();
      count = chain.getComponentCount();
      for (let i = 0; i < count; i++) {
        const c = chain.getComponentAtIndex(i);
        let mn = "?", dn = "?";
        try { mn = await c.getMatchName(); } catch (e) {}
        try { dn = await c.getDisplayName(); } catch (e) {}
        chainDump.push({ i, mn, dn });
      }
      if (count > 0) last = chainDump[count - 1].mn;
    } catch (e) { last = `(err: ${e.message})`; }
    // Type de média (vidéo/audio) tel que le filtre d'apply le voit — diagnostic
    // du correctif « piste audio liée = faux échec » (2026-09-19).
    let media = { kind: "?", raw: null, via: "?" };
    try { media = await classifyTrackItem(item); } catch (e) { /* diagnostic seulement */ }
    clips.push({ name, kind: media.kind, mediaType: media.raw, via: media.via,
                 componentCount: count, lastComponent: last, chain: chainDump });
  }
  return { selectedCount: items.length, clips };
}

/* SONDE : énumère TOUTES les propriétés/méthodes réellement exposées à
 * l'exécution sur le dernier composant du 1er clip sélectionné (chaîne de
 * prototypes comprise). Objectif : confirmer/infirmer empiriquement l'absence
 * d'un setter de NOM d'effet (les typings et api_config disent « aucun », mais
 * on ne présente pas une hypothèse comme un fait). */
async function inspectComponent() {
  const project = await requireProject();
  const sequence = await requireSequence(project);
  const items = await selectionItems(sequence);
  if (items.length === 0) throw new CmdError(CODES.NO_SELECTION, "Aucun clip sélectionné");
  const chain = await items[0].getComponentChain();
  const count = chain.getComponentCount();
  if (count === 0) throw new CmdError(CODES.INTERNAL, "chaîne vide");
  const comp = chain.getComponentAtIndex(count - 1);

  const props = new Set();
  for (let o = comp; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) {
    for (const k of Object.getOwnPropertyNames(o)) props.add(k);
  }
  const all = Array.from(props).sort();
  const nameish = all.filter((k) => /name|label|instance|title|rename/i.test(k));
  let displayName = "?";
  try { displayName = await comp.getDisplayName(); } catch (e) { /* ignore */ }
  return { displayName, propsCount: all.length, all, nameRelated: nameish };
}

/* Relit les params du DERNIER composant vidéo du 1er clip sélectionné
 * (celui qu'un apply vient d'ajouter) : {index, name, value, samples?}.
 * msg.sampleTicks : liste de ticks (String) → échantillonne chaque paramètre
 * à ces temps (vérification des keyframes). */
async function readParams(msg) {
  const project = await requireProject();
  const sequence = await requireSequence(project);
  const items = await selectionItems(sequence);
  if (items.length === 0) throw new CmdError(CODES.NO_SELECTION, "Aucun clip sélectionné");

  // msg.sampleFractions : fractions [0..1] de la durée du clip → converties en
  // ticks absolus (vérification de l'ancrage Échelle/Sortie sans connaître
  // l'in-point côté appelant).
  if (Array.isArray(msg.sampleFractions) && msg.sampleFractions.length > 0) {
    const ip = await items[0].getInPoint();
    const op = await items[0].getOutPoint();
    const dur = op.ticksNumber - ip.ticksNumber;
    msg.sampleTicks = msg.sampleFractions.map((f) => String(Math.round(ip.ticksNumber + f * dur)));
  }

  const chain = await items[0].getComponentChain();
  const count = chain.getComponentCount();
  if (count === 0) throw new CmdError(CODES.INTERNAL, "chaîne vide");
  // msg.componentMatch : lire le premier composant dont le matchName contient ce
  // texte (ex. « Basic 3D ») au lieu du dernier — l'effet animé d'un preset n'est
  // pas toujours en bas de la pile (2026-10-07, test d'ancrage de « CHAT GPT »).
  let componentIndex = count - 1;
  if (typeof msg.componentMatch === "string" && msg.componentMatch) {
    for (let i = 0; i < count; i++) {
      const mn = await chain.getComponentAtIndex(i).getMatchName();
      if (mn && mn.includes(msg.componentMatch)) { componentIndex = i; break; }
    }
  }
  const component = chain.getComponentAtIndex(componentIndex);

  const result = {
    componentCount: count,
    matchName: await component.getMatchName(),
    displayName: await component.getDisplayName(),
    params: [],
  };
  const zero = ppro.TickTime ? ppro.TickTime.TIME_ZERO : undefined;
  const paramCount = component.getParamCount();
  for (let i = 0; i < paramCount; i++) {
    const cp = component.getParam(i);
    let value = null;
    try {
      value = await cp.getValueAtTime(zero);
    } catch (e) {
      try { value = await cp.getStartValue(); } catch (e2) { value = `(illisible: ${e2.message})`; }
    }
    // Les valeurs reviennent parfois enveloppées (Keyframe.value.value) —
    // constaté empiriquement : on déballe jusqu'à la valeur primitive.
    for (let unwrap = 0; unwrap < 3 && value && typeof value === "object" && "value" in value; unwrap++) {
      value = value.value;
    }
    if (value && typeof value === "object") {
      // PointF / Color → représentation JSON-able
      value = { x: value.x, y: value.y, red: value.red, green: value.green, blue: value.blue, alpha: value.alpha };
    }
    const entry = { index: i, name: cp.displayName, value };
    if (Array.isArray(msg && msg.sampleTicks) && msg.sampleTicks.length > 0) {
      entry.samples = [];
      for (const t of msg.sampleTicks) {
        let sampled = null;
        try {
          sampled = await cp.getValueAtTime(ppro.TickTime.createWithTicks(String(t)));
          for (let u = 0; u < 3 && sampled && typeof sampled === "object" && "value" in sampled; u++) {
            sampled = sampled.value;
          }
        } catch (e) { sampled = `(err: ${e.message})`; }
        entry.samples.push({ t: String(t), v: sampled });
      }
    }
    result.params.push(entry);
  }
  return result;
}

/* Modes d'interpolation réellement posés sur un paramètre, relus depuis
 * Premiere (et non depuis notre plan) : c'est LA vérification que le bézier
 * a pris. Traduit en libellé lisible + l'icône attendue dans Effect Controls
 * (losange = linéaire, sablier = bézier) pour comparaison avec une capture. */
async function readKeyframeModes(cp) {
  const KF = ppro.Keyframe || {};
  const label = (mode) => {
    if (mode === KF.INTERPOLATION_MODE_LINEAR) return "linéaire (losange)";
    if (mode === KF.INTERPOLATION_MODE_BEZIER) return "bézier (sablier)";
    if (mode === KF.INTERPOLATION_MODE_HOLD) return "hold (demi-carré)";
    if (mode === KF.INTERPOLATION_MODE_TIME) return "time";
    return `mode ${mode}`;
  };
  const out = [];
  let times = [];
  try { times = cp.getKeyframeListAsTickTimes() || []; } catch (e) { return out; }
  for (const t of times) {
    let kf = null;
    try { kf = cp.getKeyframePtr(t); } catch (e) {
      out.push({ t: String(t.ticks), label: `(err: ${e.message})` });
      continue;
    }
    // LIMITE UXP 26.3 : PointKeyframe n'expose que {value, position} — pas de
    // get/setTemporalInterpolationMode. Le mode d'un paramètre de POINT
    // (Position…) est donc illisible par API ; seul l'échantillonnage de
    // valeurs peut témoigner de la forme de la courbe (anchor-test).
    if (typeof kf.getTemporalInterpolationMode !== "function") {
      out.push({ t: String(t.ticks), label: "non lisible (PointKeyframe)", unreadable: true });
      continue;
    }
    try {
      const mode = await kf.getTemporalInterpolationMode();
      out.push({ t: String(t.ticks), mode, label: label(mode) });
    } catch (e) {
      out.push({ t: String(t.ticks), label: `(err: ${e.message})` });
    }
  }
  return out;
}

/* Vide TOUTE la chaîne d'effets du 1er clip sélectionné, dans l'ordre
 * (vérification de l'ordre des effets + valeurs après un apply). */
async function dumpChain() {
  const project = await requireProject();
  const sequence = await requireSequence(project);
  const items = await selectionItems(sequence);
  if (items.length === 0) throw new CmdError(CODES.NO_SELECTION, "Aucun clip sélectionné");

  const chain = await items[0].getComponentChain();
  const count = chain.getComponentCount();
  const zero = ppro.TickTime ? ppro.TickTime.TIME_ZERO : undefined;
  const components = [];
  for (let c = 0; c < count; c++) {
    const comp = chain.getComponentAtIndex(c);
    const entry = { chainIndex: c, matchName: await comp.getMatchName(), displayName: await comp.getDisplayName(), params: [] };
    const pcount = comp.getParamCount();
    for (let i = 0; i < pcount; i++) {
      const cp = comp.getParam(i);
      let value = null;
      try {
        value = await cp.getValueAtTime(zero);
        for (let u = 0; u < 3 && value && typeof value === "object" && "value" in value; u++) value = value.value;
      } catch (e) { value = `(err)`; }
      if (value && typeof value === "object") value = JSON.stringify(value);
      const param = { index: i, name: cp.displayName, value };
      let varying = false;
      try { varying = cp.isTimeVarying(); } catch (e) { /* non bloquant */ }
      if (varying) param.keyframeModes = await readKeyframeModes(cp);
      entry.params.push(param);
    }
    components.push(entry);
  }
  return { count, components };
}

/* SPIKE « keyframes façonneurs » (2026-07-21) — question décisive : peut-on
 * courber une trajectoire alors qu'UXP n'expose aucune API de poignées ?
 * Mesure établie ce jour : un keyframe passé en BEZIER rend une courbe
 * EXACTEMENT linéaire (poignées par défaut alignées sur la corde).
 * Hypothèse à tester : en insérant un keyframe intermédiaire « façonneur » sur
 * la courbe eased voulue, Premiere recalcule les poignées de ses VOISINS
 * (Catmull-Rom) ; en supprimant ensuite le façonneur, les poignées
 * persisteraient → ease sans API de poignées.
 *
 * Protocole sur le 1er clip sélectionné, dernier composant, param `paramIndex`
 * (défaut 8 = Opacity de Transform) : A(0%,0) S(25%,shaperValue) B(100%,100),
 * tout en bézier, puis suppression de S, puis échantillonnage.
 * Lecture : ~25/50/75 = linéaire (hypothèse fausse) ; nettement sous 25 au
 * premier point = poignées persistantes (hypothèse vraie).
 * msg.keepShaper = true → ne supprime pas S (mesure de contrôle). */
async function easeProbe(msg) {
  const project = await requireProject();
  const sequence = await requireSequence(project);
  const items = await selectionItems(sequence);
  if (items.length === 0) throw new CmdError(CODES.NO_SELECTION, "Aucun clip sélectionné");
  const item = items[0];

  const paramIndex = msg && msg.paramIndex != null ? msg.paramIndex : 8;
  const shaperValue = msg && msg.shaperValue != null ? msg.shaperValue : 15.6;
  const keepShaper = !!(msg && msg.keepShaper);

  const ip = await item.getInPoint();
  const op = await item.getOutPoint();
  const inTicks = ip.ticksNumber;
  const span = Math.round((op.ticksNumber - inTicks) * 0.4); // segment large et lisible
  const tA = inTicks;
  const tS = inTicks + Math.round(span * 0.25);
  const tB = inTicks + span;

  const KF = ppro.Keyframe || {};
  const BEZIER = KF.INTERPOLATION_MODE_BEZIER;
  const chain = await item.getComponentChain();
  const count = chain.getComponentCount();
  const componentIndex = count - 1;
  const tick = (t) => ppro.TickTime.createWithTicks(String(t));

  project.lockedAccess(() => {
    // T1 : les trois keyframes, dont le façonneur.
    project.executeTransaction((ca) => {
      const cp = chain.getComponentAtIndex(componentIndex).getParam(paramIndex);
      ca.addAction(cp.createSetTimeVaryingAction(true));
      for (const [t, v] of [[tA, 0], [tS, shaperValue], [tB, 100]]) {
        const kf = cp.createKeyframe(v);
        kf.position = tick(t);
        ca.addAction(cp.createAddKeyframeAction(kf));
      }
    }, "Khanjar spike ease");
    // T2 : bézier sur les trois (les keyframes existent désormais).
    project.executeTransaction((ca) => {
      const cp = chain.getComponentAtIndex(componentIndex).getParam(paramIndex);
      for (const t of [tA, tS, tB]) {
        ca.addAction(cp.createSetInterpolationAtKeyframeAction(tick(t), BEZIER, true));
      }
    }, "Khanjar spike ease");
    // T3 : retrait du façonneur — les poignées calculées survivent-elles ?
    if (!keepShaper) {
      project.executeTransaction((ca) => {
        const cp = chain.getComponentAtIndex(componentIndex).getParam(paramIndex);
        ca.addAction(cp.createRemoveKeyframeAction(tick(tS), true));
      }, "Khanjar spike ease");
    }
  });

  const fresh = await item.getComponentChain();
  const cp = fresh.getComponentAtIndex(componentIndex).getParam(paramIndex);
  const samples = [];
  for (const f of [0.25, 0.5, 0.75]) {
    const t = tA + Math.round(span * f);
    let v = null;
    try {
      v = await cp.getValueAtTime(tick(t));
      for (let u = 0; u < 3 && v && typeof v === "object" && "value" in v; u++) v = v.value;
    } catch (e) { v = `(err: ${e.message})`; }
    samples.push({ at: `${Math.round(f * 100)}%`, v, linear: Math.round(f * 100) });
  }
  let remaining = 0;
  try { remaining = (cp.getKeyframeListAsTickTimes() || []).length; } catch (e) { /* ignore */ }
  return { paramName: cp.displayName, keepShaper, shaperValue, keyframesRestants: remaining, samples };
}

module.exports = { testSetup, testSetupMulti, readParams, dumpChain, dumpAllSelected, easeProbe, inspectComponent };
