/* Exécution d'un ApplyPlan (PROTOCOL.md §apply).
 *
 * Contrat :
 *  - target "selection" uniquement — jamais de repli sur un clip non sélectionné ;
 *  - toute la préparation (créations de composants) est asynchrone et se fait
 *    AVANT la transaction (le callback d'executeTransaction est synchrone) ;
 *  - une seule transaction nommée plan.label couvrant tous les clips ; si elle
 *    échoue, repli automatique en transactions par-clip (même nom), signalé
 *    par result.transaction = "per-clip" ;
 *  - un composant ne sert qu'une fois : une instance par (clip × opération).
 */
const { ppro, requireProject, requireSequence, selectionItems } = require("./context");
const { CmdError, CODES } = require("./errors");
const { bakeParam, TPS: TPS_APPLY } = require("./ease");

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
 * allemand dans un Premiere allemand restait sinon en valeurs absolues. */
const SCALE_RE = /scale|echelle|échelle|skalier|escala|scala|dimensionar|zoom|taille|スケール|비율|масштаб|缩放/i;
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

/* Lit la valeur courante du paramètre sur le clip et transpose le preset.
 * Retourne le paramètre inchangé si la lecture échoue ou si rien à ajuster. */
async function adjustParamToClip(component, p, timeCtx) {
  const sample = (p.keyframes && p.keyframes.length > 0) ? p.keyframes[0].value : p.value;
  if (sample == null) return p;
  let kind = null;
  let current;
  try {
    const cp = component.getParam(p.index);
    kind = relativeKind([p.name, cp && cp.displayName], sample);
    if (!kind) return p;
    const at = ppro.TickTime.createWithTicks(String(Math.round(timeCtx.inTicks || 0)));
    let v = await cp.getValueAtTime(at);
    for (let u = 0; u < 3 && v && typeof v === "object" && "value" in v; u++) v = v.value;
    current = v;
  } catch (e) { return p; }

  let k;
  if (kind === "offset") {
    if (!current || typeof current !== "object" || !("x" in current)) return p;
    k = { x: current.x - sample.x, y: current.y - sample.y };
    if (Math.abs(k.x) < 1e-9 && Math.abs(k.y) < 1e-9) return p;
  } else if (kind === "factor") {
    if (typeof current !== "number" || Math.abs(sample) < 1e-6) return p;
    k = current / sample;
    if (!isFinite(k) || Math.abs(k - 1) < 1e-9) return p;
  } else {
    if (typeof current !== "number") return p;
    k = current - sample;
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
 * (~9e14) restent < 2^53, exacts en Number. */
function keyframeTicks(t, anchor, timeCtx) {
  const srcDur = Number(anchor && anchor.srcDur) || 0;
  const type = anchor ? anchor.type : 1;
  if (type === 0 && srcDur > 0 && timeCtx.durTicks > 0) {
    return timeCtx.inTicks + t * (timeCtx.durTicks / srcDur);
  }
  if (type === 2 && srcDur > 0 && timeCtx.durTicks > 0) {
    return Math.max(timeCtx.inTicks, timeCtx.inTicks + timeCtx.durTicks - (srcDur - t));
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
 * sous un même lockedAccess. */
function buildParamActions(component, params, fidelity, timeCtx, anchor, timebase, expectedCount) {
  const actions = [];
  const interpolations = [];
  if (!params || params.length === 0) return { actions, interpolations };
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
    return { actions, interpolations };
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
        actions.push(cp.createSetTimeVaryingAction(true));
        const mapTick = (offset) => keyframeTicks(offset, anchor, timeCtx);
        // CUISSON : si le preset porte de l'ease, on trace la courbe native en
        // keyframes LINÉAIRES denses (le mode bézier seul ne courbe rien — cf.
        // AGENTS.md §3.1). Sinon, tracé keyframe-par-keyframe avec le mode stocké.
        const baked = bakeParam(p.keyframes, mapTick, timebase, timeCtx);
        if (baked.baked) {
          for (const pt of baked.points) {
            const keyframe = cp.createKeyframe(toNativeValue(pt.value));
            keyframe.position = ppro.TickTime.createWithTicks(String(pt.ticks));
            actions.push(cp.createAddKeyframeAction(keyframe));
            // Keyframes linéaires (défaut) : aucune action d'interpolation.
          }
          fidelity.paramsSet += 1;
          fidelity.baked = (fidelity.baked || 0) + 1;
          continue;
        }
        for (const k of p.keyframes) {
          const keyframe = cp.createKeyframe(toNativeValue(k.value));
          const ticks = Math.round(keyframeTicks(Number(k.t), anchor, timeCtx));
          keyframe.position = ppro.TickTime.createWithTicks(String(ticks));
          actions.push(cp.createAddKeyframeAction(keyframe));
          const mode = mapMode(k.i);
          if (mode != null) interpolations.push({ paramIndex: p.index, ticks, mode });
        }
        fidelity.paramsSet += 1;
        continue;
      }
      const keyframe = cp.createKeyframe(toNativeValue(p.value));
      actions.push(cp.createSetValueAction(keyframe, true));
      fidelity.paramsSet += 1;
    } catch (err) {
      fidelity.paramsSkipped += 1;
      fidelity.detail.push({ param: p.name, reason: "VALUE_REJECTED", message: err.message });
    }
  }
  return { actions, interpolations };
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

/* Après l'insertion : retrouve dans la chaîne relue le bloc des N composants
 * que nous venons de poser (par matchName, à partir de l'index d'insertion —
 * ils ne sont PLUS en queue depuis qu'on insère en haut de pile), puis pose
 * les valeurs dans une seconde transaction (même libellé). */
async function applyParamsPostInsert(project, clips, operations, fidelity, label, timebase) {
  const wantParams = operations.some((op) => op.params && op.params.length > 0);
  if (!wantParams) return;

  for (const clip of clips) {
    // Lectures async AVANT le verrou (in-point d'abord, chaîne en dernier =
    // objet le plus « frais » pour l'usage synchrone qui suit).
    let timeCtx = { inTicks: 0, durTicks: 0 };
    let chain = null;
    const names = [];
    try {
      try {
        const ip = await clip.item.getInPoint();
        const op = await clip.item.getOutPoint();
        timeCtx = { inTicks: ip.ticksNumber, durTicks: Math.max(0, op.ticksNumber - ip.ticksNumber) };
      } catch (e) { /* contexte temporel indisponible : offsets relatifs */ }
      const scan = await clip.item.getComponentChain();
      const total = scan.getComponentCount();
      for (let i = 0; i < total; i++) names.push(await scan.getComponentAtIndex(i).getMatchName());
      chain = await clip.item.getComponentChain();
    } catch (err) {
      fidelity.detail.push({ reason: "POST_INSERT_READBACK_FAILED", message: err.message });
      continue;
    }
    const base = locateInserted(names, operations, clip.insertIndex);
    if (base < 0) {
      fidelity.detail.push({ reason: "INSERTED_RUN_NOT_FOUND", clip: clip.name });
      continue;
    }
    // CRITIQUE (26.3) : les actions de paramètres (createKeyframe /
    // createSetValueAction…) doivent être créées À L'INTÉRIEUR du callback
    // executeTransaction, pas avant — sinon « The script object is no longer
    // valid » (constaté 2026-07-19, 17/24 params rejetés à l'échelle).
    try {
      const program = []; // { componentIndex, interpolations } — nombres seuls
      project.lockedAccess(() => {
        project.executeTransaction((compoundAction) => {
          for (let k = 0; k < operations.length; k++) {
            const op = operations[k];
            if (!op.params || op.params.length === 0) continue;
            const componentIndex = base + k;
            const component = chain.getComponentAtIndex(componentIndex);
            const built = buildParamActions(component, op.params, fidelity, timeCtx, op.anchor, timebase, op.paramCount);
            for (const action of built.actions) compoundAction.addAction(action);
            if (built.interpolations.length > 0) {
              program.push({ componentIndex, interpolations: built.interpolations });
            }
          }
        }, label);
        // Transaction 2 : les keyframes existent maintenant → le mode se pose.
        if (program.length > 0) {
          project.executeTransaction((compoundAction) => {
            for (const entry of program) {
              const component = chain.getComponentAtIndex(entry.componentIndex);
              for (const action of buildInterpolationActions(component, entry.interpolations, fidelity)) {
                compoundAction.addAction(action);
              }
            }
          }, label);
        }
      });
    } catch (err) {
      fidelity.detail.push({ reason: "PARAM_TRANSACTION_FAILED", message: err.message });
    }
  }
}

/* Effets INTRINSÈQUES du preset (Opacity, Motion…) : non ajoutables, déjà
 * présents sur chaque clip → on pose leurs params/keyframes sur le composant
 * EXISTANT, ciblé par matchName. Sans ça, le fondu/mouvement du preset est
 * perdu (« AP - SLIDE », « Blur Fade », etc.). */
async function applyExistingOps(project, clips, existingOps, fidelity, label, timebase, relative) {
  for (const clip of clips) {
    let timeCtx = { inTicks: 0, durTicks: 0 };
    let chain = null;
    try {
      try {
        const ip = await clip.item.getInPoint();
        const op = await clip.item.getOutPoint();
        timeCtx = { inTicks: ip.ticksNumber, durTicks: Math.max(0, op.ticksNumber - ip.ticksNumber) };
      } catch (e) { /* contexte temporel indisponible : offsets relatifs */ }
      chain = await clip.item.getComponentChain();
    } catch (err) {
      fidelity.detail.push({ reason: "EXISTING_READBACK_FAILED", message: err.message });
      continue;
    }
    // Carte matchName → index (uniquement des NOMBRES, pas d'objet stale).
    const nameToIndex = {};
    try {
      const count = chain.getComponentCount();
      for (let i = 0; i < count; i++) {
        const mn = await chain.getComponentAtIndex(i).getMatchName();
        if (nameToIndex[mn] === undefined) nameToIndex[mn] = i;
      }
    } catch (err) {
      fidelity.detail.push({ reason: "EXISTING_SCAN_FAILED", message: err.message });
      continue;
    }
    // ADAPTATION AU CLIP : lectures ASYNC des valeurs courantes AVANT le verrou
    // (rien d'asynchrone n'est permis dans la transaction). Ne produit que des
    // nombres → aucun objet UXP ne traverse la frontière.
    const tuned = {};
    if (relative) {
      for (const op of existingOps) {
        const idx = nameToIndex[op.effect.matchName];
        if (idx === undefined) continue;
        try {
          const comp = chain.getComponentAtIndex(idx);
          const out = [];
          for (const p of op.params) out.push(await adjustParamToClip(comp, p, timeCtx));
          tuned[op.effect.matchName] = out;
        } catch (e) { /* lecture impossible : on garde les valeurs absolues */ }
      }
    }
    // Chaîne fraîche pour l'usage synchrone dans la transaction.
    let freshChain;
    try { freshChain = await clip.item.getComponentChain(); } catch (e) { continue; }
    try {
      const program = [];
      project.lockedAccess(() => {
        project.executeTransaction((compoundAction) => {
          for (const op of existingOps) {
            const idx = nameToIndex[op.effect.matchName];
            if (idx === undefined) {
              fidelity.detail.push({ effect: op.effect.matchName, reason: "INTRINSIC_NOT_ON_CLIP" });
              continue;
            }
            const component = freshChain.getComponentAtIndex(idx);
            const params = tuned[op.effect.matchName] || op.params;
            const built = buildParamActions(component, params, fidelity, timeCtx, op.anchor, timebase, op.paramCount);
            for (const action of built.actions) compoundAction.addAction(action);
            if (built.interpolations.length > 0) {
              program.push({ componentIndex: idx, interpolations: built.interpolations });
            }
          }
        }, label);
        if (program.length > 0) {
          project.executeTransaction((compoundAction) => {
            for (const entry of program) {
              const component = freshChain.getComponentAtIndex(entry.componentIndex);
              for (const action of buildInterpolationActions(component, entry.interpolations, fidelity)) {
                compoundAction.addAction(action);
              }
            }
          }, label);
        }
      });
    } catch (err) {
      fidelity.detail.push({ reason: "EXISTING_TRANSACTION_FAILED", message: err.message });
    }
  }
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
  const fidelity = { paramsSet: 0, paramsSkipped: 0, detail: missing };
  const clips = []; // { item, name, steps, baseline }
  let skippedNonVideo = 0;
  for (const item of items) {
    let name = "(sans nom)";
    try { name = await item.getName(); } catch (e) { /* non bloquant */ }
    // Piste AUDIO liée (même nom que la vidéo) : hors périmètre → écartée AVANT
    // toute tentative, sinon faux « non appliqué » + transaction groupée cassée.
    const cls = await classifyTrackItem(item);
    if (cls.kind === "audio") { skippedNonVideo += 1; continue; }
    if (cls.kind === "unknown") {
      fidelity.detail.push({ clip: name, reason: "MEDIA_TYPE_UNKNOWN", mediaType: cls.raw, via: cls.via });
    }
    let baseline = -1;
    try {
      const chain = await item.getComponentChain();
      baseline = chain ? chain.getComponentCount() : -1;
    } catch (e) { baseline = -1; }
    if (baseline < 0) { skippedNonVideo += 1; continue; } // clip audio / non applicable
    const prepared = await prepareClip(item, plan.operations, addable);
    if (prepared) clips.push({ item, name, steps: prepared.steps, insertIndex: prepared.insertIndex, baseline, cls });
    else skippedNonVideo += 1;
  }
  if (clips.length === 0) {
    throw new CmdError(CODES.NO_APPLICABLE_CLIP, "Sélection sans clip vidéo applicable");
  }

  const label = plan.label || "Khanjar";

  // 1) Transaction groupée (un seul Cmd+Z si tout passe).
  let transaction = "single";
  try {
    runTransaction(project, label, clips.map((c) => c.steps), "insert");
  } catch (err) { /* vérification ci-dessous, pas de confiance au booléen */ }

  // 2) VÉRIFICATION par clip : le nombre de composants a-t-il augmenté de N ?
  // C'est le cœur du correctif multi-clips : la transaction groupée peut
  // renvoyer « succès » alors que certains clips (graphiques, sous-titres…)
  // n'ont rien reçu. On relit et on réapplique individuellement les manquants.
  async function receivedEffect(clip) {
    try {
      const chain = await clip.item.getComponentChain();
      return chain && chain.getComponentCount() >= clip.baseline + N;
    } catch (e) { return false; }
  }

  const applied = [];
  const failed = [];
  for (const clip of clips) {
    if (await receivedEffect(clip)) { applied.push(clip); continue; }
    // Réapplication ciblée avec des composants neufs : d'abord en insertion
    // (haut de pile), puis en append si le clip refuse l'insertion indexée —
    // mieux vaut un effet au mauvais rang que pas d'effet du tout.
    transaction = "per-clip";
    let received = false;
    for (const mode of ["insert", "append"]) {
      try {
        const fresh = await prepareClip(clip.item, plan.operations, addable);
        if (fresh) {
          runTransaction(project, label, [fresh.steps], mode);
          clip.insertIndex = mode === "append" ? null : fresh.insertIndex;
        }
      } catch (e) { /* vérifié juste après */ }
      if (await receivedEffect(clip)) {
        received = true;
        if (mode === "append") fidelity.detail.push({ clip: clip.name, reason: "INSERT_FELL_BACK_TO_APPEND" });
        break;
      }
    }
    if (!received) {
      // Diagnostic : type de média relevé pour ce clip (un échec sur un item
      // classé « video » est un vrai problème d'insertion, pas de l'audio).
      fidelity.detail.push({ clip: clip.name, reason: "EFFECT_NOT_RECEIVED",
        kind: clip.cls && clip.cls.kind, via: clip.cls && clip.cls.via, mediaType: clip.cls && clip.cls.raw });
    }
    (received ? applied : failed).push(clip);
  }

  if (applied.length === 0) {
    throw new CmdError(CODES.TRANSACTION_FAILED, "Aucun clip n'a pu recevoir l'effet");
  }

  // M4 : pose des paramètres sur les composants insérés (2e transaction)
  if (plan.operations.length > 0) {
    await applyParamsPostInsert(project, applied, plan.operations, fidelity, label, timebase);
  }

  // Effets intrinsèques (Opacity/Motion) : params sur les composants EXISTANTS.
  if (existingOps.length > 0) {
    await applyExistingOps(project, applied, existingOps, fidelity, label, timebase, relative);
  }

  return {
    applied: { clips: applied.length, clipNames: applied.map((c) => c.name) },
    skipped: {
      items: skippedNonVideo + failed.length,
      reason: failed.length ? "EFFECT_NOT_RECEIVED" : (skippedNonVideo ? "NON_VIDEO" : undefined),
      failedClips: failed.map((c) => c.name),
    },
    fidelity,
    transaction,
    latencyMs: Date.now() - started,
  };
}

module.exports = { apply, classifyTrackItem, buildParamActions, relativeKind, sameParamName };
