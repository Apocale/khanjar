/* Exécution d'un ApplyPlan (PROTOCOL.md §apply).
 *
 * Contrat :
 *  - target "selection" uniquement — jamais de repli sur un clip non sélectionné ;
 *  - toute la préparation (créations de composants) est asynchrone et se fait
 *    AVANT la transaction (le callback d'executeTransaction est synchrone) ;
 *  - transactions nommées plan.label, chacune couvrant TOUS les clips
 *    (2026-10-09, audit P-02 — avant : une ou deux PAR CLIP pour les réglages) :
 *      1. insertion des effets (absente pour un preset 100 % intrinsèque),
 *      2. réglages (valeurs et keyframes, effets ajoutés ET intrinsèques),
 *      3. modes d'interpolation, seulement s'il reste des keyframes HOLD ou
 *         bézier non cuits (AGENTS §3.1 item 5 : deux transactions obligatoires).
 *    Soit 1 ⌘Z pour un effet nu, 2 pour un preset réglé, 3 au plus, quel que
 *    soit le nombre de clips — un SEUL ⌘Z est impossible : un effet n'expose
 *    ses paramètres qu'une fois posé. Si une transaction groupée échoue, repli
 *    automatique clip par clip (même nom), signalé par
 *    result.transaction = "per-clip" ; fidelity.transactions = nombre de
 *    transactions réussies ;
 *  - un composant ne sert qu'une fois : une instance par (clip × opération).
 */
const { ppro, requireProject, requireSequence, selectionItems } = require("./context");
const { CmdError, CODES } = require("./errors");
const { bakeParam, plainKeyframes, TPS: TPS_APPLY } = require("./ease");

/* Partitionne les opérations en (applicables, manquantes) contre l'inventaire
 * réel : les matchNames non ajoutables (intrinsèques type AE.ADBE Motion,
 * effets tiers absents) sont ignorés opération par opération — un preset
 * partiellement applicable s'applique, avec rapport de fidélité. */
async function partitionOperations(plan) {
  if (!plan || plan.target !== "selection" || !Array.isArray(plan.operations) || plan.operations.length === 0) {
    throw new CmdError(CODES.INTERNAL, "ApplyPlan invalide");
  }
  const known = new Set(await ppro.VideoFilterFactory.getMatchNames());
  const applicable = [];
  const missing = [];
  for (const op of plan.operations) {
    const matchName = op.effect && op.effect.matchName;
    if (matchName && known.has(matchName)) applicable.push(op);
    else missing.push({ matchName: matchName || "(vide)", reason: "EFFECT_MISSING" });
  }
  if (applicable.length === 0) {
    throw new CmdError(
      CODES.EFFECT_NOT_FOUND,
      `Aucun effet applicable : ${missing.map((m) => m.matchName).join(", ")}`
    );
  }
  return { applicable, missing, known };
}

/* Index du HAUT de la pile d'effets utilisateur.
 *
 * POURQUOI : un effet ajouté en QUEUE de chaîne se retrouve tout en bas de la
 * liste, sous les calques d'un graphique — et n'agit alors pas sur lui
 * (constaté par l'utilisateur, 2026-07-21). Le natif empile les nouveaux
 * effets en haut ; on fait pareil, pour tous les types de clips.
 *
 * COMMENT : les composants intrinsèques de TÊTE (Opacity, Motion, Vector
 * Motion, Time Remapping) occupent toujours le début de la chaîne. On insère
 * juste APRÈS eux — donc AU-DESSUS de tout le reste, y compris le calque « Text »
 * d'un graphique (qui, lui, est en FIN de chaîne).
 *
 * ⚠️ POURQUOI PAS « premier composant ajoutable » (ancienne logique, buguée) :
 * sur un graphique SANS effet utilisateur, la chaîne est [Opacity, Motion,
 * Vector Motion, Text]. Aucun composant n'est « ajoutable » (tous intrinsèques),
 * donc on retombait en fin de chaîne → l'effet se posait APRÈS « Text » → il
 * n'agit pas sur le graphique (bug constaté par l'utilisateur, capture 2026-07-23).
 * En sautant explicitement les intrinsèques de tête, on se pose AVANT « Text ».
 * matchNames vérifiés empiriquement (dump-selected, chaîne d'un graphique). */
const TOP_INTRINSICS = new Set([
  "AE.ADBE Opacity",
  "AE.ADBE Motion",
  "AE.ADBE Graphic Group",   // « Vector Motion » d'un graphique/MOGRT
  "AE.ADBE Time Remapping",
]);
async function userStackTop(chain, addable) {
  let count = 0;
  try { count = chain.getComponentCount(); } catch (e) { return 0; }
  for (let i = 0; i < count; i++) {
    let matchName = null;
    try { matchName = await chain.getComponentAtIndex(i).getMatchName(); } catch (e) { return i; }
    if (!TOP_INTRINSICS.has(matchName)) return i; // 1er composant hors intrinsèques de tête
  }
  return count;
}

/* CLASSIFICATION VIDÉO / AUDIO d'un item de la sélection (2026-09-19).
 *
 * POURQUOI : sélectionner un clip vidéo sélectionne AUSSI sa piste audio liée
 * (séquence imbriquée, .mp4 avec son) → getSelection renvoie DEUX trackItems
 * du même nom. L'item AUDIO possède lui aussi une chaîne de composants
 * (Volume, Panner…), donc `getComponentChain()` ne suffit pas à l'écarter : on
 * tentait d'y insérer un effet vidéo, l'insertion échouait, la transaction
 * groupée aussi (→ repli par-clip = plusieurs Cmd+Z), et l'utilisateur voyait
 * « 1 non appliqué » à chaque clip sonore — 83 faux EFFECT_NOT_RECEIVED dans
 * le journal (« Nested Sequence 112 », « *.mp4 », « *.wav »).
 *
 * COMMENT : TrackItem.getMediaType() (présent en 26.5.1 : api_config + binaire)
 * comparé aux constantes MediaType, sous forme de chaîne (Guid ou string selon
 * la version). Repli empirique si l'API manque ou renvoie autre chose : une
 * chaîne VIDÉO commence toujours par les intrinsèques Opacity/Motion
 * (AGENTS.md §3.1) ; une chaîne AUDIO porte des effets « Internal … »
 * (Internal Volume, Internal Channel Volume… — matchNames relevés dans les
 * presets audio de l'utilisateur). Tout cas indécis reste traité comme VIDÉO
 * (comportement historique) et est tracé MEDIA_TYPE_UNKNOWN. */
/* Chaîne discriminante d'un Guid/constante, ou null si la sérialisation est
 * dégénérée ("[object Object]", "{}", vide) — un objet natif opaque rendrait
 * AUDIO et VIDEO identiques, et TOUT serait classé audio. */
function stringifyGuid(g) {
  try {
    if (g == null) return null;
    if (typeof g === "string") return g.trim() || null;
    if (typeof g === "number") return String(g);
    let s = null;
    if (typeof g.toString === "function") s = g.toString();
    if (!s || s === "[object Object]") s = JSON.stringify(g);
    if (!s || s === "{}" || s === "[object Object]" || s === "null") return null;
    return s;
  } catch (e) { return null; }
}

/* Constantes MediaType stringifiées ; invalidées si elles ne se distinguent pas
 * l'une de l'autre (aucune décision ne peut alors reposer sur getMediaType). */
function mediaTypeConstants() {
  const C = (ppro.Constants && ppro.Constants.MediaType) || {};
  const audio = stringifyGuid(C.AUDIO), video = stringifyGuid(C.VIDEO);
  if (!audio || !video || audio === video) return { audio: null, video: null };
  return { audio, video };
}

async function classifyTrackItem(item) {
  let raw = null;
  try {
    if (typeof item.getMediaType === "function") {
      raw = stringifyGuid(await item.getMediaType());
      const { audio, video } = mediaTypeConstants();
      if (raw && audio && raw === audio) return { kind: "audio", raw, via: "mediaType" };
      if (raw && video && raw === video) return { kind: "video", raw, via: "mediaType" };
    }
  } catch (e) { /* API absente ou refusée : repli sur la chaîne */ }
  try {
    const chain = await item.getComponentChain();
    if (!chain) return { kind: "unknown", raw, via: "no-chain" };
    const count = chain.getComponentCount();
    let internal = 0;
    for (let i = 0; i < count; i++) {
      const mn = await chain.getComponentAtIndex(i).getMatchName();
      if (TOP_INTRINSICS.has(mn)) return { kind: "video", raw, via: "chain" };
      if (typeof mn === "string" && mn.startsWith("Internal ")) internal += 1;
    }
    if (count > 0 && internal === count) return { kind: "audio", raw, via: "chain" };
    return { kind: "unknown", raw, via: "chain" };
  } catch (e) {
    return { kind: "unknown", raw, via: "error" };
  }
}

/* Retrouve, dans la chaîne relue, la position de départ du bloc que NOUS
 * venons d'insérer (suite contiguë de matchNames dans l'ordre du plan).
 * `preferred` = l'index d'insertion utilisé, vérifié en premier ; sinon on
 * balaie depuis la FIN (cas du repli en append). -1 si introuvable. */
function locateInserted(names, operations, preferred) {
  const wanted = operations.map((op) => op.effect.matchName);
  const fits = (start) =>
    start >= 0 &&
    start + wanted.length <= names.length &&
    wanted.every((matchName, k) => names[start + k] === matchName);
  if (preferred != null && fits(preferred)) return preferred;
  for (let start = names.length - wanted.length; start >= 0; start--) {
    if (fits(start)) return start;
  }
  return -1;
}

/* M4 : actions de pose de valeurs sur un composant LIVE (post-insertion —
 * vérifié empiriquement le 2026-07-07 : un composant fraîchement créé
 * n'expose PAS getParam/getParamCount avant insertion). Sécurités :
 * index borné + vérification du nom (l'ordre prfpset correspond à l'ordre
 * UXP ; un désaccord = skip tracé, jamais une valeur au mauvais endroit).
 * Toute erreur par-paramètre est comptée, jamais propagée. */
/* M4.4 : les points et couleurs arrivent en objets JSON — conversion vers les
 * types natifs UXP attendus par createKeyframe. */
function toNativeValue(v) {
  if (v && typeof v === "object") {
    if ("x" in v && "y" in v) return new ppro.PointF(v.x, v.y);
    if ("r" in v) {
      try {
        return new ppro.Color(v.r, v.g, v.b, v.a);
      } catch (e) {
        const c = new ppro.Color();
        c.red = v.r; c.green = v.g; c.blue = v.b; c.alpha = v.a;
        return c;
      }
    }
  }
  return v;
}

/* NOMS DE PARAMÈTRES ET LANGUE DE PREMIERE (2026-10-06).
 *
 * Un .prfpset enregistre le nom de chaque paramètre dans la LANGUE du Premiere
 * qui a créé le preset (vérifié sur les presets Adobe du bundle : « Scale » en
 * en_US, « Echelle » en fr_FR, « Skalierung » en de_DE), et displayName renvoie
 * le nom du Premiere qui applique. Exiger l'égalité stricte des noms faisait
 * donc sauter presque tous les réglages d'un pack anglais chez un monteur dont
 * Premiere est en français (ou l'inverse) : l'effet arrivait vide, sans
 * animation. La comparaison ignore casse, accents et espaces ; quand les noms
 * diffèrent malgré tout, c'est la STRUCTURE de l'effet (nombre de paramètres
 * identique à l'enregistrement) qui décide si l'index est fiable. */
function normParamName(name) {
  let s = String(name == null ? "" : name).trim().toLowerCase();
  try { s = s.normalize("NFD").replace(/[\u0300-\u036f]/g, ""); } catch (e) { /* sans normalize : comparaison brute */ }
  return s.replace(/\s+/g, " ");
}

function sameParamName(a, b) {
  return normParamName(a) === normParamName(b);
}

/* ADAPTATION À L'ÉTAT ACTUEL DU CLIP (« relative »).
 *
 * POURQUOI : un preset écrit ses valeurs en ABSOLU. « Échelle 100 → 120 »
 * appliqué à un élément déjà cadré à 50 % le fait SAUTER à 100 % avant de
 * zoomer — le cadrage de l'utilisateur est détruit. Idem pour la position : un
 * preset « slide up » qui finit au centre recentre de force un sous-titre placé
 * en bas. On transpose donc le preset sur la valeur courante du clip :
 *   - Échelle : proportionnel (×1,2 sur un clip à 50 % → 50 → 60) ;
 *   - Position / point : additif (le décalage du preset est conservé) ;
 *   - Rotation : additif ;
 *   - le reste (opacité, flou…) : ABSOLU, car « opacité 0 → 100 » veut bien
 *     dire 0 → 100.
 * Ne s'applique qu'aux composants INTRINSÈQUES (Motion, Vector Motion) : c'est
 * là que vit le cadrage réel du clip ; un effet ajouté part de ses défauts.
 *
 * Échelle et rotation se reconnaissent à leur NOM, dans les 10 langues de
 * Premiere (relevées dans les presets Adobe localisés, Motion index 1/2/4), et
 * sur le nom du preset comme sur celui du Premiere qui applique : un preset
 * allemand dans un Premiere allemand restait sinon en valeurs absolues.
 * 2026-10-09 (audit P-01, B2#9) : « масш » ajouté — le Premiere russe abrège
 * « Масш. ширину / высоту » (largeur/hauteur d'échelle), que « масштаб » ne
 * reconnaissait pas. */
const SCALE_RE = /scale|echelle|échelle|skalier|escala|scala|dimensionar|zoom|taille|スケール|비율|масштаб|масш|缩放/i;
const ROTATION_RE = /rotat|rotac|rotaç|rotaz|dreh|回転|회전|поворот|旋转/i;

function relativeKind(names, sample) {
  if (sample && typeof sample === "object" && "x" in sample && "y" in sample) return "offset";
  if (typeof sample === "number") {
    const list = (Array.isArray(names) ? names : [names]).map((n) => String(n || ""));
    if (list.some((n) => SCALE_RE.test(n))) return "factor";
    if (list.some((n) => ROTATION_RE.test(n))) return "delta";
  }
  return null;
}

function mapValue(v, kind, k) {
  if (kind === "offset") return { x: v.x + k.x, y: v.y + k.y };
  if (kind === "factor") return v * k;
  return v + k; // delta
}

/* RÉFÉRENCE = VALEUR NEUTRE (2026-10-09, audit P-01 ; décision d'Isma Q1).
 *
 * CAUSE : la référence était la 1ʳᵉ valeur du PRESET (k = actuelle / preset,
 * actuelle − preset). Une valeur FIXE redevenait donc toujours la valeur du
 * clip — « PiP 25% » ne bougeait plus rien, un zoom fixe à 181 % disparaissait
 * (les 38 PiP Adobe de toutes les palettes) — et une animation qui ARRIVE au
 * repos était inversée : 110 → 100 devenait 100 → 90,9 ; échelle actuelle 0 →
 * tout le preset à 0.
 * CORRECTION : on transpose par rapport au NEUTRE du réglage — Échelle 100,
 * Position et Point d'ancrage au centre (0,5 ; 0,5), Rotation 0 :
 *   facteur k = actuelle / 100 ; décalage k = actuelle − centre ; delta k = actuelle,
 * appliqué à toutes les valeurs du réglage, fixes comme keyframes. Un clip au
 * cadrage normal reçoit exactement le preset (le natif) ; « zoom 100 → 120 »
 * sur un clip réglé à 50 % donne toujours 50 → 60 (la demande d'août).
 * Réglage rendu TEL QUEL si : lecture impossible ; réglage DÉJÀ animé sur le
 * clip (isTimeVarying si l'API l'expose, sinon valeur à l'in-point ≠ valeur à
 * la fin du clip ; invérifiable = on n'y touche pas) ; k neutre, non fini, ou
 * ≤ 0 pour un facteur. Lectures async faites AVANT le verrou (appelant), seuls
 * des nombres sont gardés (AGENTS §3.1 items 1-2). */
const NEUTRAL_SCALE = 100;
const NEUTRAL_POINT = { x: 0.5, y: 0.5 };
// Garde-fou d'unités : Premiere rend les positions NORMALISÉES (0-1 à l'écran,
// relu sur Transform par anchor-test). Une lecture hors de [-10, 10] serait en
// pixels (non observé) : la transposer projetterait le clip hors cadre.
const MAX_NORMALIZED = 10;

function unwrapValue(v) {
  for (let u = 0; u < 3 && v && typeof v === "object" && "value" in v; u++) v = v.value;
  return v;
}

function sameReading(a, b) {
  if (typeof a === "number" && typeof b === "number") return Math.abs(a - b) <= 1e-9 * Math.max(1, Math.abs(a));
  if (a && b && typeof a === "object" && typeof b === "object") {
    return Math.abs(a.x - b.x) <= 1e-9 && Math.abs(a.y - b.y) <= 1e-9;
  }
  return false;
}

/* Lit la valeur courante du paramètre sur le clip et transpose le preset.
 * `getParam(index)` relit le paramètre depuis la chaîne à chaque lecture.
 * Retourne le paramètre inchangé si rien n'est à ajuster (voir ci-dessus). */
async function adjustParamToClip(getParam, p, timeCtx) {
  const sample = (p.keyframes && p.keyframes.length > 0) ? p.keyframes[0].value : p.value;
  if (sample == null) return p;
  let kind = null;
  let current;
  try {
    const cp = getParam(p.index);
    kind = relativeKind([p.name, cp && cp.displayName], sample);
    if (!kind) return p;
    let varying = null; // null = API absente : on compare début et fin du clip
    if (typeof cp.isTimeVarying === "function") {
      try { varying = !!(await cp.isTimeVarying()); } catch (e) { varying = null; }
    }
    if (varying === true) return p;
    const inKnown = timeCtx.inKnown !== false;
    const at = (ticks) => ppro.TickTime.createWithTicks(String(Math.round(ticks)));
    current = unwrapValue(await getParam(p.index).getValueAtTime(at(inKnown ? timeCtx.inTicks || 0 : 0)));
    if (varying === null) {
      if (!inKnown || !(timeCtx.durTicks > 0)) return p; // invérifiable : on n'y touche pas
      const end = timeCtx.inTicks + timeCtx.durTicks - 1;
      const atEnd = unwrapValue(await getParam(p.index).getValueAtTime(at(end)));
      if (!sameReading(current, atEnd)) return p; // déjà animé sur le clip
    }
  } catch (e) { return p; }

  let k;
  if (kind === "offset") {
    if (!current || typeof current !== "object") return p;
    const x = Number(current.x), y = Number(current.y);
    if (!isFinite(x) || !isFinite(y) || Math.abs(x) > MAX_NORMALIZED || Math.abs(y) > MAX_NORMALIZED) return p;
    k = { x: x - NEUTRAL_POINT.x, y: y - NEUTRAL_POINT.y };
    if (Math.abs(k.x) < 1e-9 && Math.abs(k.y) < 1e-9) return p;
  } else if (kind === "factor") {
    if (typeof current !== "number" || !isFinite(current)) return p;
    k = current / NEUTRAL_SCALE;
    if (!isFinite(k) || k <= 0 || Math.abs(k - 1) < 1e-9) return p;
  } else {
    if (typeof current !== "number" || !isFinite(current)) return p;
    k = current; // neutre 0
    if (Math.abs(k) < 1e-9) return p;
  }

  const out = { ...p };
  if (p.keyframes && p.keyframes.length > 0) {
    out.keyframes = p.keyframes.map((kf) => ({ ...kf, value: mapValue(kf.value, kind, k) }));
  } else if (p.value != null) {
    out.value = mapValue(p.value, kind, k);
  }
  return out;
}

/* Position d'un keyframe selon l'ancrage natif du preset (<Type> du prfpset,
 * mapping vérifié empiriquement 2026-07-20) :
 *   1 = Entrée  : in + t
 *   0 = Échelle : in + t × (durClip / durSource)  — défaut Adobe, majoritaire
 *   2 = Sortie  : in + durClip − (durSource − t)  — collé à la fin du clip
 * t = offset depuis AnchorInPoint (ticks). timeCtx = {inTicks, durTicks} du
 * clip cible ; anchor = {type, srcDur} de l'opération. Précision : les ticks
 * (~9e14) restent < 2^53, exacts en Number.
 * 2026-10-09 (audit P-10) : plus de clamp à l'in-point pour l'ancrage Sortie
 * (AGENTS §3.2 0ter : offsets signés, ne jamais clamper). Les keyframes
 * tombés avant l'in-point sont remplacés ensuite par UN keyframe à l'in-point
 * portant la valeur de la courbe (ease.js, fitToClip). */
function keyframeTicks(t, anchor, timeCtx) {
  const srcDur = Number(anchor && anchor.srcDur) || 0;
  const type = anchor ? anchor.type : 1;
  if (type === 0 && srcDur > 0 && timeCtx.durTicks > 0) {
    return timeCtx.inTicks + t * (timeCtx.durTicks / srcDur);
  }
  if (type === 2 && srcDur > 0 && timeCtx.durTicks > 0) {
    return timeCtx.inTicks + timeCtx.durTicks - (srcDur - t);
  }
  return timeCtx.inTicks + t; // type 1 (ou repli)
}

/* Construit les actions de POSE des valeurs/keyframes (transaction 1) et, en
 * parallèle, le programme d'interpolation à rejouer en transaction 2 :
 * [{ paramIndex, ticks, mode }] — QUE des nombres, aucun objet UXP, pour que
 * la seconde transaction reparte d'objets frais.
 *
 * POURQUOI DEUX TRANSACTIONS (2026-07-21) : grouper add-keyframe et
 * set-interpolation dans la MÊME action composée ne pose pas le mode — les
 * keyframes restaient linéaires (losanges dans Effect Controls au lieu de
 * sabliers). On ne peut pas cibler par le temps un keyframe qui n'existe pas
 * encore au moment où l'action est créée. L'échantillon officiel Adobe
 * (uxp-premiere-pro-samples, keyframe.ts) fait bien DEUX executeTransaction
 * sous un même lockedAccess.
 *
 * COMPTAGE (2026-10-09, audit P-06) : `paramsSet` était incrémenté ICI, à la
 * construction, avant l'exécution — une transaction refusée laissait les
 * effets aux valeurs par défaut avec un HUD vert « 27 réglages ». Désormais
 * chaque réglage est construit dans un tableau LOCAL, versé dans `actions`
 * seulement s'il est complet (un keyframe qui lève au milieu ne laisse plus
 * une animation à moitié posée), et la fonction RENVOIE `built`, le nombre de
 * réglages construits : l'appelant ne les compte posés qu'après une
 * transaction réussie. Les réglages sautés restent comptés ici.
 *
 * PLAFOND (2026-10-09, audit P-09) : `budget` = { used, max } partagé par tous
 * les réglages d'UN clip. Un réglage dont les actions (keyframes + modes)
 * feraient dépasser `max` est sauté (TOO_MANY_KEYFRAMES, compté dans
 * paramsSkipped → HUD orange) au lieu de figer Premiere dans une transaction
 * synchrone géante. Le coût est calculé AVANT de créer la moindre action. */
function buildParamActions(component, params, fidelity, timeCtx, anchor, timebase, expectedCount, budget) {
  const actions = [];
  const interpolations = [];
  let built = 0;
  if (!params || params.length === 0) return { actions, interpolations, built };
  const KF = ppro.Keyframe || {};
  const LINEAR = KF.INTERPOLATION_MODE_LINEAR != null ? KF.INTERPOLATION_MODE_LINEAR : null;
  const BEZIER = KF.INTERPOLATION_MODE_BEZIER != null ? KF.INTERPOLATION_MODE_BEZIER : LINEAR;
  const HOLD = KF.INTERPOLATION_MODE_HOLD != null ? KF.INTERPOLATION_MODE_HOLD : LINEAR;
  // Enum kfInterpMode du prfpset (recherche 2026-07-21) : 0=linéaire, 4=hold,
  // 5=bézier. HOLD doit être honoré (un « pop » maintenu ≠ un glissement).
  // Limite dure UXP : les poignées d'ease (influence/vitesse) ne sont PAS
  // réglables — le bézier par défaut est le maximum de fidélité atteignable.
  const mapMode = (i) => (i === 0 ? LINEAR : i === 4 ? HOLD : BEZIER);
  let count = 0;
  try { count = component.getParamCount(); } catch (err) {
    fidelity.paramsSkipped += params.length;
    fidelity.detail.push({ reason: "PRE_INSERT_PARAMS_UNSUPPORTED", message: err.message });
    return { actions, interpolations, built };
  }
  // GARDE-FOU ANTI-CORRUPTION : un preset désigne ses paramètres par INDEX. Si
  // l'effet installé ici n'a pas le même nombre de paramètres qu'à
  // l'enregistrement du preset (autre version de Premiere, autre version d'un
  // effet tiers), la définition a changé : un paramètre inséré au milieu décale
  // tous les suivants et une valeur atterrirait sur le MAUVAIS réglage. Dans ce
  // cas on n'écrit QUE les paramètres dont le nom concorde — jamais à l'aveugle.
  // À l'inverse, structure CONFIRMÉE identique (même effet, même nombre de
  // paramètres) : l'index fait foi et un nom différent n'est qu'une question de
  // langue (voir normParamName) ou un renommage par Adobe — on écrit, comme le
  // fait Premiere en natif, qui applique un preset sans regarder les noms.
  const structureKnown = expectedCount > 0;
  const structureDiffers = structureKnown && count !== expectedCount;
  if (structureDiffers) {
    fidelity.detail.push({ reason: "PARAM_STRUCTURE_MISMATCH", expected: expectedCount, live: count });
  }
  for (const p of params) {
    const local = [];        // actions de CE réglage (versées seulement s'il est complet)
    const localInterp = [];  // son programme d'interpolation
    let isBaked = false;
    try {
      if (p.index < 0 || p.index >= count) {
        fidelity.paramsSkipped += 1;
        fidelity.detail.push({ param: p.name, reason: "INDEX_OUT_OF_RANGE" });
        continue;
      }
      const cp = component.getParam(p.index);
      const liveName = cp && cp.displayName;
      const named = normParamName(p.name) !== "" && normParamName(liveName) !== "";
      const namesAgree = named && sameParamName(p.name, liveName);
      if (named && !namesAgree) {
        if (!structureKnown || structureDiffers) {
          fidelity.paramsSkipped += 1;
          fidelity.detail.push({ param: p.name, live: liveName, reason: "NAME_MISMATCH" });
          continue;
        }
        // Compté (journal) sans être sauté ; un seul exemple dans le détail,
        // un preset en autre langue en produirait un par paramètre et par clip.
        fidelity.namesDiffer = (fidelity.namesDiffer || 0) + 1;
        if (fidelity.namesDiffer === 1) {
          fidelity.detail.push({ param: p.name, live: liveName, reason: "NAME_DIFFERS_SAME_STRUCTURE" });
        }
      }
      // Structure différente : sans nom concordant, l'index n'est pas fiable.
      if (structureDiffers && !namesAgree) {
        fidelity.paramsSkipped += 1;
        fidelity.detail.push({ param: p.name || `#${p.index}`, reason: "UNVERIFIABLE_PARAM" });
        continue;
      }
      // Paramètre keyframé. Position selon l'ancrage natif (keyframeTicks) ;
      // le point d'entrée du clip est inclus dans timeCtx.inTicks (rappel :
      // images/graphiques/sous-titres ont un in-point par défaut de 1 h).
      // Mode d'interpolation : on rejoue le mode STOCKÉ dans le preset
      // (champ i : 0=linéaire, 5=bézier — 84 % des keyframes réels sont
      // bézier ; les forcer en linéaire changeait le « feel » vs natif).
      if (p.keyframes && p.keyframes.length > 0) {
        const mapTick = (offset) => keyframeTicks(offset, anchor, timeCtx);
        // CUISSON : si le preset porte de l'ease, on trace la courbe native en
        // keyframes LINÉAIRES denses (le mode bézier seul ne courbe rien — cf.
        // AGENTS.md §3.1). Sinon, tracé keyframe-par-keyframe avec le mode stocké.
        // Dans les deux cas : coupé à l'in-point et limité à la partie visible
        // du clip au-delà de 400 points (P-09/P-10, ease.js).
        const baked = bakeParam(p.keyframes, mapTick, timebase, timeCtx);
        const points = baked.baked ? baked.points : plainKeyframes(p.keyframes, mapTick, timebase, timeCtx).points;
        // 2026-10-09 (audit P-02) : plus d'action d'interpolation pour un
        // keyframe LINÉAIRE — c'est le mode d'un keyframe neuf (AGENTS §3.1
        // item 5). Seuls HOLD et bézier ont besoin de la transaction 2 ; un
        // preset linéaire ne coûte donc plus de ⌘Z supplémentaire. Les points
        // cuits sont tous linéaires.
        const modeOf = (pt) => {
          if (baked.baked || pt.mode === 0) return null;
          const mode = mapMode(pt.mode);
          return mode != null && mode !== LINEAR ? mode : null;
        };
        const cost = 1 + points.length + points.filter((pt) => modeOf(pt) != null).length;
        if (budget && budget.used + cost > budget.max) {
          fidelity.paramsSkipped += 1;
          fidelity.detail.push({ param: p.name, reason: "TOO_MANY_KEYFRAMES", actions: cost, limit: budget.max });
          continue;
        }
        local.push(cp.createSetTimeVaryingAction(true));
        for (const pt of points) {
          const keyframe = cp.createKeyframe(toNativeValue(pt.value));
          keyframe.position = ppro.TickTime.createWithTicks(String(pt.ticks));
          local.push(cp.createAddKeyframeAction(keyframe));
          const mode = modeOf(pt);
          if (mode != null) localInterp.push({ paramIndex: p.index, ticks: pt.ticks, mode });
        }
        isBaked = baked.baked;
      } else {
        if (budget && budget.used + 1 > budget.max) {
          fidelity.paramsSkipped += 1;
          fidelity.detail.push({ param: p.name, reason: "TOO_MANY_KEYFRAMES", actions: 1, limit: budget.max });
          continue;
        }
        const keyframe = cp.createKeyframe(toNativeValue(p.value));
        local.push(cp.createSetValueAction(keyframe, true));
      }
    } catch (err) {
      fidelity.paramsSkipped += 1;
      fidelity.detail.push({ param: p.name, reason: "VALUE_REJECTED", message: err.message });
      continue; // rien de ce réglage n'entre dans la transaction
    }
    for (const action of local) actions.push(action);
    for (const it of localInterp) interpolations.push(it);
    if (budget) budget.used += local.length + localInterp.length;
    if (isBaked) fidelity.baked = (fidelity.baked || 0) + 1;
    built += 1;
  }
  return { actions, interpolations, built };
}

/* Transaction 2 : pose du mode d'interpolation sur des keyframes qui existent
 * désormais réellement. Les actions sont créées ICI (contrainte 26.3) à partir
 * d'un composant relu dans la même passe synchrone. */
function buildInterpolationActions(component, interpolations, fidelity) {
  const actions = [];
  for (const it of interpolations) {
    try {
      const cp = component.getParam(it.paramIndex);
      const pos = ppro.TickTime.createWithTicks(String(it.ticks));
      actions.push(cp.createSetInterpolationAtKeyframeAction(pos, it.mode, true));
    } catch (err) {
      fidelity.interpSkipped = (fidelity.interpSkipped || 0) + 1;
      fidelity.detail.push({ reason: "INTERP_REJECTED", message: err.message });
    }
  }
  return actions;
}

/* Prépare, pour un clip, la liste {chain, component, index, paramActions} de
 * chaque opération, et l'index d'insertion retenu (haut de la pile
 * utilisateur ; les effets d'un même preset se suivent à partir de là, ce qui
 * préserve l'ordre du plan). Retourne null si le clip n'est pas applicable
 * (ex. clip audio). */
async function prepareClip(item, operations, addable) {
  // Repérage du point d'insertion sur une chaîne dédiée : le balayage
  // enchaîne des await, l'objet ne doit pas servir ensuite (objets UXP
  // périmés entre await — AGENTS.md §3.1).
  let insertIndex = null;
  try {
    const scan = await item.getComponentChain();
    if (!scan) return null;
    insertIndex = await userStackTop(scan, addable);
  } catch (err) {
    return null;
  }

  let chain;
  try {
    chain = await item.getComponentChain();
  } catch (err) {
    return null;
  }
  if (!chain) return null;

  const steps = [];
  for (const op of operations) {
    const component = await ppro.VideoFilterFactory.createComponent(op.effect.matchName);
    if (!component) return null;
    steps.push({ chain, component, index: insertIndex + steps.length });
  }
  return { steps, insertIndex };
}

/* ── POSE DES RÉGLAGES : UNE transaction pour TOUS les clips ─────────────
 * (2026-10-09, audit P-02 + P-06 ; décision d'Isma Q2).
 *
 * CAUSE : seule l'insertion était groupée. Les réglages des effets ajoutés
 * (applyParamsPostInsert) puis ceux des intrinsèques (applyExistingOps)
 * passaient chacun par une transaction PAR CLIP, plus une d'interpolation :
 * « 3 effets réglés » sur 3 clips = 4 ⌘Z, sur 500 = 501. Premiere n'en garde
 * que 32 (préférence relevée chez Isma) : le 1ᵉʳ ⌘Z laissait les effets aux
 * valeurs par défaut et, au-delà de 16 à 32 clips, l'ajout lui-même n'était
 * plus annulable. Et le booléen d'executeTransaction n'était pas lu : une
 * transaction refusée était annoncée « tout posé » (HUD vert, rien au journal).
 *
 * CORRECTION, en une seule passe pour les effets ajoutés ET les intrinsèques :
 *  a. lectures async hors verrou, clip par clip : in/out, noms de la chaîne,
 *     index des composants, adaptation au cadrage — rien que des nombres et des
 *     chaînes (AGENTS §3.1 items 1-2) ;
 *  b. juste avant le verrou, chaînes de TOUS les clips relues à la suite, sans
 *     autre await (même motif que l'insertion groupée, éprouvée sur 783 clips) ;
 *  c. UN lockedAccess : T1 = réglages de tous les clips, actions créées DANS le
 *     callback, un try/catch PAR CLIP (objet périmé → ce clip est repris seul,
 *     aucune de ses actions n'entre dans T1) ; T2 = interpolations HOLD/bézier
 *     des clips réussis, seulement s'il en reste ;
 *  d. clips à reprendre, ou T1 refusée : repli clip par clip (idempotent :
 *     même valeur, keyframe au même temps) ;
 *  e. `paramsSet` compté seulement après une transaction réussie ; sinon les
 *     réglages vont dans `paramsSkipped`, le clip dans
 *     `fidelity.paramsFailedClips`, raison PARAMS_NOT_SET (contrat §4.1).
 * Risque connu (à valider par T-01/T-06 dans Premiere) : une chaîne périmée
 * dans la transaction groupée — couverte par le try/catch par clip et le repli. */

/* Temps d'un TickTime en nombre (ticksNumber, sinon la chaîne ticks) ; null si
 * illisible. */
function ticksOf(time) {
  if (time == null) return null;
  let n = Number(time.ticksNumber);
  if (!isFinite(n)) n = Number(time.ticks);
  return isFinite(n) ? n : null;
}

function paramCountOf(ops) {
  let n = 0;
  for (const op of ops || []) n += op && op.params ? op.params.length : 0;
  return n;
}

function isAnimated(p) {
  return !!(p && Array.isArray(p.keyframes) && p.keyframes.length > 0);
}

/* Noms (matchNames) de la chaîne d'un clip, relus dans l'ordre. */
async function readChainNames(item) {
  const chain = await item.getComponentChain();
  if (!chain) throw new Error("chaîne d'effets absente");
  const total = chain.getComponentCount();
  const names = [];
  for (let i = 0; i < total; i++) names.push(await chain.getComponentAtIndex(i).getMatchName());
  return names;
}

/* Fidélité locale à UN clip : versée dans le rapport global une fois le sort du
 * clip connu, pour ne jamais compter deux fois un clip repris seul. */
function clipFidelity() {
  return { paramsSkipped: 0, detail: [], namesDiffer: 0, baked: 0, interpSkipped: 0 };
}

function mergeFidelity(into, from) {
  into.paramsSkipped += from.paramsSkipped;
  if (from.namesDiffer) into.namesDiffer = (into.namesDiffer || 0) + from.namesDiffer;
  if (from.baked) into.baked = (into.baked || 0) + from.baked;
  if (from.interpSkipped) into.interpSkipped = (into.interpSkipped || 0) + from.interpSkipped;
  for (const d of from.detail) {
    // Un seul exemple de « nom d'une autre langue » pour toute l'application.
    if (d.reason === "NAME_DIFFERS_SAME_STRUCTURE" &&
        into.detail.some((x) => x.reason === "NAME_DIFFERS_SAME_STRUCTURE")) continue;
    into.detail.push(d);
  }
}

/* a. Lectures hors verrou pour un clip → { clip, timeCtx, jobs, paramTotal } ou
 * null. Un job = un composant de la chaîne et les réglages à y poser. */
async function readParamContext(clip, operations, existingOps, fidelity, relative, markParamsFailed) {
  const item = clip.item;
  let inTicks = null;
  let durTicks = 0;
  try { inTicks = ticksOf(await item.getInPoint()); } catch (e) { inTicks = null; }
  try {
    const out = ticksOf(await item.getOutPoint());
    if (inTicks != null && out != null) durTicks = Math.max(0, out - inTicks);
  } catch (e) { /* durée inconnue : les ancrages Échelle/Sortie retombent sur l'entrée */ }
  const inKnown = inTicks != null;
  const timeCtx = { inTicks: inKnown ? inTicks : 0, durTicks: inKnown ? durTicks : 0, inKnown };

  let names = clip.names;
  if (!names) {
    try { names = await readChainNames(item); } catch (err) {
      const lost = paramCountOf(operations) + paramCountOf(existingOps);
      fidelity.paramsSkipped += lost;
      markParamsFailed(clip);
      fidelity.detail.push({ clip: clip.name, params: lost, message: err.message,
        reason: operations.length > 0 ? "POST_INSERT_READBACK_FAILED" : "EXISTING_READBACK_FAILED" });
      return null;
    }
  }

  const jobs = [];
  if (operations.some((op) => op.params && op.params.length > 0)) {
    // Bloc que NOUS venons d'insérer, retrouvé par suite de matchNames (il
    // n'est plus en queue depuis qu'on insère en haut de pile).
    const base = clip.base != null ? clip.base : locateInserted(names, operations, clip.insertIndex);
    if (base < 0) {
      const lost = paramCountOf(operations);
      fidelity.paramsSkipped += lost;
      markParamsFailed(clip);
      fidelity.detail.push({ reason: "INSERTED_RUN_NOT_FOUND", clip: clip.name, params: lost });
    } else {
      operations.forEach((op, k) => {
        if (op.params && op.params.length > 0) jobs.push({ componentIndex: base + k, op, params: op.params });
      });
    }
  }
  // Effets INTRINSÈQUES du preset (Opacity, Motion…) : non ajoutables, déjà
  // présents sur chaque clip → réglages posés sur le composant EXISTANT, ciblé
  // par matchName. Sans ça, le fondu/mouvement du preset serait perdu.
  if (existingOps.length > 0) {
    const nameToIndex = {};
    names.forEach((mn, i) => { if (nameToIndex[mn] === undefined) nameToIndex[mn] = i; });
    for (const op of existingOps) {
      if (!op.params || op.params.length === 0) continue;
      const idx = nameToIndex[op.effect.matchName];
      if (idx === undefined) {
        // Ex. un preset Vector Motion sur un clip vidéo : réglages comptés
        // sautés (avant : silence, HUD vert).
        fidelity.paramsSkipped += op.params.length;
        fidelity.detail.push({ effect: op.effect.matchName, reason: "INTRINSIC_NOT_ON_CLIP", clip: clip.name, params: op.params.length });
        continue;
      }
      jobs.push({ componentIndex: idx, op, params: op.params, intrinsic: true });
    }
  }

  // P-06 (2026-10-09) : in-point illisible → les keyframes partiraient de 0,
  // soit une heure trop tôt sur un sous-titre. On ne pose pas les réglages
  // ANIMÉS de ce clip ; les valeurs fixes, elles, ne dépendent pas du temps.
  if (!inKnown) {
    let dropped = 0;
    for (const job of jobs) {
      const keep = job.params.filter((p) => !isAnimated(p));
      dropped += job.params.length - keep.length;
      job.params = keep;
    }
    if (dropped > 0) {
      fidelity.paramsSkipped += dropped;
      fidelity.detail.push({ clip: clip.name, reason: "IN_POINT_UNREADABLE", params: dropped });
    }
  }

  // ADAPTATION AU CLIP : lectures ASYNC des valeurs courantes AVANT le verrou
  // (rien d'asynchrone n'est permis dans la transaction). Ne produit que des
  // nombres → aucun objet UXP ne traverse la frontière.
  if (relative && jobs.some((job) => job.intrinsic && job.params.length > 0)) {
    let readChain = null;
    try { readChain = await item.getComponentChain(); } catch (e) { readChain = null; }
    if (readChain) {
      for (const job of jobs) {
        if (!job.intrinsic || job.params.length === 0) continue;
        try {
          // Composant et paramètre relus depuis la chaîne à chaque lecture.
          const getParam = (index) => readChain.getComponentAtIndex(job.componentIndex).getParam(index);
          const out = [];
          for (const p of job.params) out.push(await adjustParamToClip(getParam, p, timeCtx));
          job.params = out;
        } catch (e) { /* lecture impossible : on garde les valeurs absolues */ }
      }
    }
  }

  const live = jobs.filter((job) => job.params.length > 0);
  return { clip, timeCtx, jobs: live, paramTotal: paramCountOf(live.map((job) => ({ params: job.params }))) };
}

/* Plafond d'actions (keyframes + modes) par clip et par application (audit
 * P-09, 2026-10-09) : au-delà, les réglages trop lourds sont sautés
 * (TOO_MANY_KEYFRAMES) plutôt que de figer Premiere. */
const MAX_ACTIONS_PER_CLIP = 2000;

/* Actions de réglages d'UN clip, créées depuis `chain` (appelé DANS le callback
 * d'executeTransaction). Lève si la chaîne est périmée : le clip sera repris
 * seul. */
function buildClipActions(ctx, chain, timebase) {
  const fid = clipFidelity();
  const budget = { used: 0, max: MAX_ACTIONS_PER_CLIP };
  const actions = [];
  const program = []; // { componentIndex, interpolations } — nombres seuls
  let count = 0;
  for (const job of ctx.jobs) {
    const component = chain.getComponentAtIndex(job.componentIndex);
    if (!component) throw new Error(`composant ${job.componentIndex} introuvable`);
    const built = buildParamActions(component, job.params, fid, ctx.timeCtx, job.op.anchor, timebase, job.op.paramCount, budget);
    for (const action of built.actions) actions.push(action);
    count += built.built;
    if (built.interpolations.length > 0) {
      program.push({ componentIndex: job.componentIndex, interpolations: built.interpolations });
    }
  }
  return { actions, program, count, fid };
}

/* Transaction 2 d'un clip : actions d'interpolation sur ses keyframes posés. */
function buildClipInterpolations(program, chain, fid) {
  const actions = [];
  for (const entry of program) {
    let component;
    try { component = chain.getComponentAtIndex(entry.componentIndex); } catch (err) {
      fid.interpSkipped += entry.interpolations.length;
      fid.detail.push({ reason: "INTERP_REJECTED", message: err.message });
      continue;
    }
    for (const action of buildInterpolationActions(component, entry.interpolations, fid)) actions.push(action);
  }
  return actions;
}

function interpolationCount(program) {
  let n = 0;
  for (const entry of program || []) n += entry.interpolations.length;
  return n;
}

/* Rend true si Premiere a accepté la transaction. `false` = refusée, rien
 * d'écrit (API UXP) ; une exception compte aussi comme un refus. */
function accepted(result) {
  return result !== false;
}

/* d. Repli : réglages d'UN clip, seul, avec une chaîne fraîche. */
async function applyParamsAlone(project, ctx, fidelity, label, timebase, markParamsFailed) {
  let ok = false;
  let built = null;
  let message = null;
  let t2 = null;
  const interpFid = clipFidelity();
  try {
    const chain = await ctx.clip.item.getComponentChain();
    if (!chain) throw new Error("chaîne d'effets absente");
    project.lockedAccess(() => {
      ok = accepted(project.executeTransaction((compoundAction) => {
        built = buildClipActions(ctx, chain, timebase);
        for (const action of built.actions) compoundAction.addAction(action);
      }, label));
      if (!ok || built.program.length === 0) return;
      try {
        t2 = accepted(project.executeTransaction((compoundAction) => {
          for (const action of buildClipInterpolations(built.program, chain, interpFid)) compoundAction.addAction(action);
        }, label));
      } catch (err) { t2 = false; interpFid.detail.push({ reason: "INTERP_REJECTED", message: err.message }); }
    });
  } catch (err) { message = err.message; }

  if (ok && built) {
    fidelity.transactions += 1;
    mergeFidelity(fidelity, built.fid);
    fidelity.paramsSet += built.count;
    if (t2 === true) {
      fidelity.transactions += 1;
      mergeFidelity(fidelity, interpFid);
    } else if (t2 === false) {
      fidelity.interpSkipped = (fidelity.interpSkipped || 0) + interpolationCount(built.program);
      fidelity.detail.push({ clip: ctx.clip.name, reason: "INTERP_REJECTED", message: "transaction d'interpolation refusée" });
    }
    return;
  }
  // Refusée ou en panne : aucun réglage de ce clip n'est écrit.
  if (built) mergeFidelity(fidelity, built.fid); // réglages déjà sautés à la construction
  const lost = built ? built.count : ctx.paramTotal;
  fidelity.paramsSkipped += lost;
  markParamsFailed(ctx.clip);
  fidelity.detail.push({ clip: ctx.clip.name, reason: "PARAMS_NOT_SET", params: lost,
    message: message || "transaction refusée par Premiere" });
}

/* Pose les réglages de tous les clips (voir l'en-tête de section). Rend
 * { perClip } : true si au moins un clip est passé par le repli. */
async function applyParams(project, clips, operations, existingOps, fidelity, label, timebase, relative) {
  const report = { perClip: false };
  if (paramCountOf(operations) + paramCountOf(existingOps) === 0) return report;

  const failedOnce = new Set();
  const markParamsFailed = (clip) => {
    if (failedOnce.has(clip)) return;
    failedOnce.add(clip);
    fidelity.paramsFailedClips.push(clip.name);
  };

  // a. Lectures hors verrou.
  const contexts = [];
  for (const clip of clips) {
    const ctx = await readParamContext(clip, operations, existingOps, fidelity, relative, markParamsFailed);
    if (ctx && ctx.jobs.length > 0) contexts.push(ctx);
  }
  if (contexts.length === 0) return report;

  // b. Chaînes de TOUS les clips relues à la suite, juste avant le verrou.
  for (const ctx of contexts) {
    try { ctx.chain = await ctx.clip.item.getComponentChain(); } catch (e) { ctx.chain = null; }
  }

  // c. UN verrou : T1 pour tous les clips, puis T2 s'il reste des interpolations.
  const grouped = contexts.filter((ctx) => ctx.chain);
  const retry = contexts.filter((ctx) => !ctx.chain);
  const t2Batch = [];
  const interpFid = clipFidelity();
  let t1 = false;
  let t2 = null;
  let t2Message = null;
  try {
    project.lockedAccess(() => {
      t1 = accepted(project.executeTransaction((compoundAction) => {
        for (const ctx of grouped) {
          try {
            const built = buildClipActions(ctx, ctx.chain, timebase);
            for (const action of built.actions) compoundAction.addAction(action);
            ctx.built = built;
          } catch (err) {
            ctx.built = null; // objet périmé… : ce clip sera repris seul
          }
        }
      }, label));
      if (!t1) return;
      for (const ctx of grouped) if (ctx.built && ctx.built.program.length > 0) t2Batch.push(ctx);
      if (t2Batch.length === 0) return;
      try {
        t2 = accepted(project.executeTransaction((compoundAction) => {
          for (const ctx of t2Batch) {
            for (const action of buildClipInterpolations(ctx.built.program, ctx.chain, interpFid)) compoundAction.addAction(action);
          }
        }, label));
      } catch (err) { t2 = false; t2Message = err.message; }
    });
  } catch (err) {
    /* T1 ou le verrou a levé avant d'aboutir : t1 reste false → repli */
  }

  if (t1) {
    fidelity.transactions += 1;
    for (const ctx of grouped) {
      if (!ctx.built) { retry.push(ctx); continue; }
      mergeFidelity(fidelity, ctx.built.fid);
      fidelity.paramsSet += ctx.built.count;
    }
    if (t2 === true) {
      fidelity.transactions += 1;
      mergeFidelity(fidelity, interpFid);
    } else if (t2 === false) {
      let lost = 0;
      for (const ctx of t2Batch) lost += interpolationCount(ctx.built.program);
      fidelity.interpSkipped = (fidelity.interpSkipped || 0) + lost;
      fidelity.detail.push({ reason: "INTERP_REJECTED", interpolations: lost,
        message: t2Message || "transaction d'interpolation refusée" });
    }
  } else {
    for (const ctx of grouped) { ctx.built = null; retry.push(ctx); }
  }

  // d. Repli clip par clip.
  for (const ctx of retry) {
    report.perClip = true;
    await applyParamsAlone(project, ctx, fidelity, label, timebase, markParamsFailed);
  }
  return report;
}

/* mode "insert" (défaut) : pose en HAUT de la pile utilisateur, comme le natif.
 * mode "append" : ancien comportement, gardé comme filet de sécurité si
 * l'insertion indexée est refusée sur un clip. */
function runTransaction(project, label, stepGroups, mode) {
  let success = false;
  project.lockedAccess(() => {
    success = project.executeTransaction((compoundAction) => {
      for (const steps of stepGroups) {
        for (const s of steps) {
          const add = (mode === "append" || s.index == null)
            ? s.chain.createAppendComponentAction(s.component)
            : s.chain.createInsertComponentAction(s.component, s.index);
          compoundAction.addAction(add);
          for (const action of s.paramActions || []) {
            compoundAction.addAction(action);
          }
        }
      }
    }, label);
  });
  return success;
}

/* Insertion des effets du plan sur tous les clips préparés, puis vérification
 * clip par clip. Rend { applied, failed, perClip }. */
async function insertEffects(project, clips, operations, addable, label, fidelity) {
  const N = operations.length;
  const applied = [];
  const failed = [];
  let perClip = false;

  // 1) Transaction d'insertion groupée : un ⌘Z retire les effets de TOUS les
  // clips (les réglages ont leur propre transaction groupée, voir applyParams).
  try {
    if (accepted(runTransaction(project, label, clips.map((c) => c.steps), "insert"))) fidelity.transactions += 1;
  } catch (err) { /* vérification ci-dessous, pas de confiance au booléen */ }

  // 2) VÉRIFICATION par clip : la transaction groupée peut renvoyer « succès »
  // alors que certains clips (graphiques, sous-titres…) n'ont rien reçu. On
  // relit chaque chaîne et on réapplique individuellement les manquants.
  //
  // 2026-10-09 (audit P-07) : la vérification ne compte plus seulement les
  // composants. CAUSE : « reçu » = nombre ≥ avant + N, toute exception = « pas
  // reçu », puis on réinsérait les N effets. Une insertion PARTIELLE (2 des 3
  // effets sur un clip : composant périmé, AGENTS §3.1 item 3) ou une relecture
  // qui levait une fois donnaient des effets EN DOUBLE, les rescapés aux
  // valeurs par défaut, et une réponse « succès ». CORRECTION : on relit les
  // matchNames ; delta = nombre − avant :
  //   - delta ≥ N et la suite du plan retrouvée (locateInserted) → reçu ;
  //   - delta = 0 et relecture réussie → rien reçu : réinsertion (insert puis
  //     append, comme avant) ;
  //   - 0 < delta < N (ou suite introuvable) → PARTIAL_INSERT ; relecture
  //     impossible (après un 2ᵉ essai) → READBACK_FAILED : on ne réinsère RIEN,
  //     le clip est annoncé en échec. Mieux vaut un clip signalé qu'un doublon.
  for (const clip of clips) {
    let state = await inspectInsertion(clip, operations);
    if (state.status === "none") {
      // Réapplication ciblée avec des composants neufs : d'abord en insertion
      // (haut de pile), puis en append si le clip refuse l'insertion indexée —
      // mieux vaut un effet au mauvais rang que pas d'effet du tout.
      perClip = true;
      for (const mode of ["insert", "append"]) {
        try {
          const fresh = await prepareClip(clip.item, operations, addable);
          if (fresh) {
            if (accepted(runTransaction(project, label, [fresh.steps], mode))) fidelity.transactions += 1;
            clip.insertIndex = mode === "append" ? null : fresh.insertIndex;
          }
        } catch (e) { /* vérifié juste après */ }
        state = await inspectInsertion(clip, operations);
        if (state.status === "none") continue;
        if (state.status === "received" && mode === "append") {
          fidelity.detail.push({ clip: clip.name, reason: "INSERT_FELL_BACK_TO_APPEND" });
        }
        break;
      }
    }
    if (state.status === "received") {
      // Noms et position du bloc gardés pour la pose des réglages (pas de
      // 2ᵉ relecture de la chaîne).
      clip.names = state.names;
      clip.base = state.base;
      applied.push(clip);
      continue;
    }
    // Diagnostic : type de média relevé pour ce clip (un échec sur un item
    // classé « video » est un vrai problème d'insertion, pas de l'audio).
    const reason = state.status === "partial" ? "PARTIAL_INSERT"
      : state.status === "unreadable" ? "READBACK_FAILED" : "EFFECT_NOT_RECEIVED";
    const entry = { clip: clip.name, reason,
      kind: clip.cls && clip.cls.kind, via: clip.cls && clip.cls.via, mediaType: clip.cls && clip.cls.raw };
    if (state.status === "partial") { entry.added = state.delta; entry.expected = N; }
    if (state.message) entry.message = state.message;
    fidelity.detail.push(entry);
    clip.failReason = reason;
    failed.push(clip);
  }
  return { applied, failed, perClip };
}

/* État de l'insertion sur un clip, relu par matchNames (audit P-07) :
 * { status: "received" | "none" | "partial" | "unreadable", names, base, delta }. */
async function inspectInsertion(clip, operations) {
  const N = operations.length;
  let names = null;
  let lastError = null;
  // Une relecture qui lève UNE fois ne doit pas conclure à « rien reçu » (ce
  // qui déclenchait la réinsertion) : 2ᵉ essai avant de déclarer l'échec.
  for (let attempt = 0; attempt < 2 && names == null; attempt++) {
    try { names = await readChainNames(clip.item); } catch (err) { lastError = err; }
  }
  if (names == null) {
    return { status: "unreadable", message: lastError ? lastError.message : "relecture impossible" };
  }
  const delta = names.length - clip.baseline;
  if (delta === 0) return { status: "none", delta, names };
  if (delta >= N) {
    const base = locateInserted(names, operations, clip.insertIndex);
    if (base >= 0) return { status: "received", delta, names, base };
  }
  return { status: "partial", delta, names };
}

async function apply(plan, options) {
  const relative = !(options && options.relativeToClip === false); // défaut : ON
  const started = Date.now();
  const existingOps = Array.isArray(plan.existingOperations) ? plan.existingOperations : [];
  const hasAppend = Array.isArray(plan.operations) && plan.operations.length > 0;

  let applicable = [];
  let missing = [];
  let known = null;
  if (hasAppend) {
    ({ applicable, missing, known } = await partitionOperations(plan));
  } else if (existingOps.length === 0) {
    throw new CmdError(CODES.INTERNAL, "ApplyPlan vide");
  }
  plan = { ...plan, operations: applicable };

  const project = await requireProject();
  const sequence = await requireSequence(project);
  const items = await selectionItems(sequence);
  if (items.length === 0) {
    throw new CmdError(CODES.NO_SELECTION, "Aucun clip sélectionné");
  }

  const N = plan.operations.length;
  const addable = known instanceof Set ? known : new Set();

  // Timebase (ticks/frame) : cadence la cuisson d'ease sur les frames de la
  // séquence → courbe exacte au rendu, keyframes minimaux. Repli 30 fps.
  let timebase = Math.round(TPS_APPLY / 30);
  try {
    const tb = await sequence.getTimebase();
    const raw = tb && typeof tb === "object" ? (tb.ticksPerFrame != null ? tb.ticksPerFrame : tb.ticks) : tb;
    const n = Number(raw);
    if (isFinite(n) && n > 0) timebase = Math.round(n);
  } catch (e) { /* repli 30 fps */ }

  // Préparation par clip (hors transaction) + relevé du nombre de composants
  // AVANT (baseline) pour vérifier ensuite que l'effet a réellement été posé.
  // paramsFailedClips / transactions : contrat §4.1 (audit P-06 / P-02).
  const fidelity = { paramsSet: 0, paramsSkipped: 0, detail: missing, paramsFailedClips: [], transactions: 0 };
  const clips = []; // { item, name, steps, baseline }
  const prepareFailed = []; // clips vidéo (ou indécis) impossibles à préparer
  let skippedNonVideo = 0;
  for (let index = 0; index < items.length; index++) {
    const item = items[index];
    let name = "(sans nom)";
    try { name = await item.getName(); } catch (e) { /* non bloquant */ }
    // Piste AUDIO liée (même nom que la vidéo) : hors périmètre → écartée AVANT
    // toute tentative, sinon faux « non appliqué » + transaction groupée cassée.
    const cls = await classifyTrackItem(item);
    if (cls.kind === "audio") { skippedNonVideo += 1; continue; }
    if (cls.kind === "unknown") {
      fidelity.detail.push({ clip: name, reason: "MEDIA_TYPE_UNKNOWN", mediaType: cls.raw, via: cls.via });
    }
    // 2026-10-09 (audit P-11, A1#11) : préparation protégée CLIP PAR CLIP.
    // CAUSE : un clip vidéo dont la chaîne était illisible ou dont
    // createComponent rendait null était compté avec les pistes audio
    // (NON_VIDEO, que l'app tait) : ignoré sans un mot ; une exception de
    // createComponent faisait échouer TOUTE l'application (INTERNAL) ; et si
    // tous échouaient, le monteur lisait « Sélectionne un clip vidéo » alors
    // qu'il en avait sélectionné. CORRECTION : l'échec va dans failedClips
    // (PREPARE_FAILED), les autres clips continuent ; NO_APPLICABLE_CLIP est
    // réservé au cas « que de l'audio », sinon TRANSACTION_FAILED.
    try {
      const chain = await item.getComponentChain();
      if (!chain) throw new Error("chaîne d'effets absente");
      const baseline = chain.getComponentCount();
      // 2026-10-09 (audit P-02, B3#10) : preset 100 % intrinsèque (rien à
      // insérer) → ni préparation (deux lectures de chaîne par clip pour rien)
      // ni transaction d'insertion VIDE (une entrée d'annulation qui ne fait rien).
      if (N === 0) { clips.push({ item, name, index, steps: [], insertIndex: null, baseline, cls }); continue; }
      const prepared = await prepareClip(item, plan.operations, addable);
      if (!prepared) throw new Error("préparation impossible (chaîne illisible ou effet non créé)");
      clips.push({ item, name, index, steps: prepared.steps, insertIndex: prepared.insertIndex, baseline, cls });
    } catch (err) {
      prepareFailed.push({ item, name, index, cls, failReason: "PREPARE_FAILED" });
      fidelity.detail.push({ clip: name, reason: "PREPARE_FAILED", message: err.message,
        kind: cls.kind, via: cls.via, mediaType: cls.raw });
    }
  }
  if (clips.length === 0) {
    if (prepareFailed.length > 0) {
      throw new CmdError(CODES.TRANSACTION_FAILED,
        `Aucun clip n'a pu être préparé (${prepareFailed.length}) : ${fidelity.detail.filter((d) => d.reason === "PREPARE_FAILED").map((d) => d.message)[0]}`);
    }
    throw new CmdError(CODES.NO_APPLICABLE_CLIP, "Sélection sans clip vidéo applicable");
  }

  const label = plan.label || "Khanjar";
  let applied = clips;
  let failed = [];
  let transaction = "single";
  if (N > 0) {
    const insertion = await insertEffects(project, clips, plan.operations, addable, label, fidelity);
    applied = insertion.applied;
    failed = insertion.failed;
    if (insertion.perClip) transaction = "per-clip";
  }

  if (applied.length === 0) {
    throw new CmdError(CODES.TRANSACTION_FAILED, "Aucun clip n'a pu recevoir l'effet");
  }

  // Réglages des effets insérés ET des intrinsèques (Opacity/Motion) : une
  // transaction groupée pour tous les clips (+ une d'interpolation si besoin).
  const params = await applyParams(project, applied, plan.operations, existingOps, fidelity, label, timebase, relative);
  if (params.perClip) transaction = "per-clip";

  // Clips en échec (préparation puis insertion), dans l'ordre de la sélection ;
  // `reason` = celle du premier (PREPARE_FAILED, PARTIAL_INSERT,
  // READBACK_FAILED ou EFFECT_NOT_RECEIVED), le détail porte les autres.
  const allFailed = prepareFailed.concat(failed).sort((a, b) => a.index - b.index);
  return {
    applied: { clips: applied.length, clipNames: applied.map((c) => c.name) },
    skipped: {
      items: skippedNonVideo + allFailed.length,
      reason: allFailed.length ? (allFailed[0].failReason || "EFFECT_NOT_RECEIVED") : (skippedNonVideo ? "NON_VIDEO" : undefined),
      failedClips: allFailed.map((c) => c.name),
    },
    fidelity,
    transaction,
    latencyMs: Date.now() - started,
  };
}

module.exports = { apply, classifyTrackItem, buildParamActions, relativeKind, sameParamName };
