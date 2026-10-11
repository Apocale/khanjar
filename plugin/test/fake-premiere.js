/* Faux module « premierepro » partagé par les tests du plugin (hors Premiere).
 *
 * Données SYNTHÉTIQUES uniquement : aucun preset, index ni journal réel.
 * Modèle repris (recopié, pas importé) des simulations de l'audit du
 * 2026-10-08 (A1 et B3) :
 *  - chaque appel async est un aller-retour hôte (setImmediate) : deux
 *    traitements concurrents s'entrelacent aux `await`, comme dans UXP ;
 *  - executeTransaction exécute les actions de l'action composée ; si UNE
 *    action lève, TOUTE la transaction est annulée et rend false (tout ou rien) ;
 *  - une transaction réussie et non vide = une entrée d'annulation (⌘Z).
 * Crochets (`hooks`) pour injecter les pannes décrites par l'audit :
 * transaction refusée, action perdue, chaîne périmée, relecture qui lève…
 *
 * Usage : `const fake = require("./fake-premiere");` AVANT de charger le code
 * du plugin (le module est inscrit sous le nom « premierepro »). */
const Module = require("module");

const TPS = 254016000000;
const MediaType = { AUDIO: "audio-guid", VIDEO: "video-guid" };

const stats = {};
function resetStats() {
  Object.assign(stats, {
    tx: 0, txOk: 0, txOkNonEmpty: 0, txFailed: 0, txThrew: 0,
    actions: 0, kinds: {}, labels: [], maxActions: 0,
    awaits: 0, createComponent: 0, locks: 0,
  });
}
resetStats();

const hooks = {};
function resetHooks() { for (const k of Object.keys(hooks)) delete hooks[k]; }

async function host(v) {
  stats.awaits += 1;
  await new Promise((r) => setImmediate(r));
  return v;
}

function tick(n) { return { ticksNumber: Number(n), ticks: String(n) }; }
function ticksOf(time) {
  if (time == null) return 0;
  return Number(time.ticksNumber != null ? time.ticksNumber : time.ticks);
}

function lerp(a, b, f) {
  if (typeof a === "number" && typeof b === "number") return a + (b - a) * f;
  if (a && b && typeof a === "object") return { x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f };
  return a;
}

let actionSeq = 0;
function makeAction(kind, item, run, extra) {
  return Object.assign({ kind, item, run, seq: ++actionSeq }, extra || {});
}

/* ── Paramètres, composants, chaînes ─────────────────────────────────── */

class Param {
  constructor(component, index, def) {
    this.component = component;
    this.index = index;
    this.def = def || {};
    this.displayName = this.def.name;
    this.value = clone(this.def.value);
    this.keyframes = new Map(); // ticks (Number) → valeur
    this.modes = new Map();     // ticks → mode d'interpolation posé
    this.varying = false;
    if (Array.isArray(this.def.keyframes)) {
      for (const [t, v] of this.def.keyframes) this.keyframes.set(Number(t), clone(v));
      this.varying = this.keyframes.size > 0;
    }
    // Premiere plus ancien sans isTimeVarying : le plugin doit retomber sur
    // la comparaison in/out.
    if (this.def.noIsTimeVarying) this.isTimeVarying = undefined;
  }
  isTimeVarying() { return this.varying; }
  valueAt(ticks) {
    if (!this.varying || this.keyframes.size === 0) return this.value;
    const ts = [...this.keyframes.keys()].sort((a, b) => a - b);
    if (ticks <= ts[0]) return this.keyframes.get(ts[0]);
    for (let i = 1; i < ts.length; i++) {
      if (ticks <= ts[i]) {
        const f = (ticks - ts[i - 1]) / (ts[i] - ts[i - 1]);
        return lerp(this.keyframes.get(ts[i - 1]), this.keyframes.get(ts[i]), f);
      }
    }
    return this.keyframes.get(ts[ts.length - 1]);
  }
  async getValueAtTime(time) {
    if (this.def.readThrows) throw new Error("valeur illisible");
    return host(clone(this.valueAt(ticksOf(time))));
  }
  createKeyframe(value) {
    if (hooks.createKeyframe) hooks.createKeyframe(this, value); // peut lever
    return { value, position: null };
  }
  createSetValueAction(kf) {
    return makeAction("set", this.component.item, () => {
      const old = this.value;
      this.value = kf.value;
      return () => { this.value = old; };
    }, { param: this });
  }
  createSetTimeVaryingAction(on) {
    return makeAction("tv", this.component.item, () => {
      const old = this.varying;
      this.varying = !!on;
      return () => { this.varying = old; };
    }, { param: this });
  }
  createAddKeyframeAction(kf) {
    const t = ticksOf(kf.position);
    return makeAction("kf", this.component.item, () => {
      if (!kf.position) throw new Error("keyframe sans position");
      const had = this.keyframes.has(t);
      const old = this.keyframes.get(t);
      this.keyframes.set(t, kf.value);
      return () => { if (had) this.keyframes.set(t, old); else this.keyframes.delete(t); };
    }, { param: this, at: t, value: kf.value });
  }
  createSetInterpolationAtKeyframeAction(position, mode) {
    const t = ticksOf(position);
    return makeAction("interp", this.component.item, () => {
      if (!this.keyframes.has(t)) throw new Error("no keyframe at time");
      const had = this.modes.has(t);
      const old = this.modes.get(t);
      this.modes.set(t, mode);
      return () => { if (had) this.modes.set(t, old); else this.modes.delete(t); };
    }, { param: this, at: t, mode });
  }
}

class Component {
  constructor(matchName, paramDefs, opts) {
    this.matchName = matchName;
    this.opts = opts || {};
    this.item = null;
    this.params = (paramDefs || []).map((d, i) => new Param(this, i, d));
  }
  async getMatchName() {
    if (hooks.getMatchName) hooks.getMatchName(this); // peut lever
    return host(this.matchName);
  }
  async getDisplayName() { return host(this.matchName); }
  getParamCount() {
    // Vérifié dans Premiere (2026-07-07) : un composant neuf n'expose pas ses
    // paramètres avant son insertion.
    if (!this.item && this.opts.preInsertNoParams) throw new Error("composant non inséré");
    return this.params.length;
  }
  getParam(i) {
    if (i < 0 || i >= this.params.length) throw new Error("param hors limites");
    return this.params[i];
  }
  param(name) { return this.params.find((p) => p.displayName === name); }
}

class Chain {
  constructor(item) {
    this.item = item;
    this.stale = false;
    item.chains.push(this);
  }
  check() { if (this.stale) throw new Error("The script object is no longer valid"); }
  getComponentCount() { this.check(); return this.item.components.length; }
  getComponentAtIndex(i) {
    this.check();
    const c = this.item.components[i];
    if (!c) throw new Error(`composant ${i} introuvable`);
    return c;
  }
  createInsertComponentAction(component, index) {
    this.check();
    const item = this.item;
    return makeAction("insert", item, () => {
      if (item.refuseInsert) throw new Error("insertion refusée");
      if (index > item.components.length) throw new Error("index hors limites");
      item.components.splice(index, 0, component);
      component.item = item;
      return () => {
        const at = item.components.indexOf(component);
        if (at >= 0) item.components.splice(at, 1);
        component.item = null;
      };
    }, { component, index });
  }
  createAppendComponentAction(component) {
    this.check();
    const item = this.item;
    return makeAction("append", item, () => {
      if (item.refuseAppend) throw new Error("ajout refusé");
      item.components.push(component);
      component.item = item;
      return () => {
        const at = item.components.indexOf(component);
        if (at >= 0) item.components.splice(at, 1);
        component.item = null;
      };
    }, { component });
  }
}

/* Paramètres des composants intrinsèques (noms anglais, ordre de Premiere 26.x :
 * Motion 11 paramètres, Opacity 3 avec le masque — ici 2, sans importance). */
function motionDefs(over) {
  const o = over || {};
  return [
    { name: "Position", value: o.position || { x: 0.5, y: 0.5 }, keyframes: o.positionKeyframes, noIsTimeVarying: o.noIsTimeVarying },
    { name: "Scale", value: o.scale != null ? o.scale : 100, keyframes: o.scaleKeyframes, noIsTimeVarying: o.noIsTimeVarying },
    { name: "Scale Width", value: o.scaleWidth != null ? o.scaleWidth : 100, noIsTimeVarying: o.noIsTimeVarying },
    { name: "Uniform Scale", value: true },
    { name: "Rotation", value: o.rotation != null ? o.rotation : 0, noIsTimeVarying: o.noIsTimeVarying },
    { name: "Anchor Point", value: o.anchor || { x: 0.5, y: 0.5 }, noIsTimeVarying: o.noIsTimeVarying },
    { name: "Anti-flicker Filter", value: 0 },
    { name: "Crop Left", value: 0 }, { name: "Crop Top", value: 0 },
    { name: "Crop Right", value: 0 }, { name: "Crop Bottom", value: 0 },
  ];
}
function opacityDefs() { return [{ name: "Opacity", value: 100 }, { name: "Blend Mode", value: 0 }]; }

const effectDefs = new Map();
function defineEffect(matchName, paramDefs) { effectDefs.set(matchName, paramDefs); }

/* Opération de plan au format du protocole (SearchItem.protocolPayload). */
function op(matchName, params, opts) {
  const o = opts || {};
  const defs = effectDefs.get(matchName) || [];
  return {
    effect: { matchName },
    anchor: o.anchor || { type: 1, srcDur: "0" },
    paramCount: o.paramCount != null ? o.paramCount : defs.length,
    params: (params || []).map((p) => Object.assign({ keyframes: [] }, p)),
  };
}
function plan(label, operations, existingOperations) {
  return { label, target: "selection", operations: operations || [], existingOperations: existingOperations || [] };
}

class TrackItem {
  constructor(opts) {
    const o = opts || {};
    this.name = o.name || "clip";
    this.kind = o.kind || "video";
    this.inTicks = o.inTicks != null ? o.inTicks : 0;
    this.durTicks = o.durTicks != null ? o.durTicks : 3 * TPS;
    this.refuseInsert = !!o.refuseInsert;
    this.refuseAppend = !!o.refuseAppend;
    this.inPointThrows = !!o.inPointThrows;
    this.outPointThrows = !!o.outPointThrows;
    this.chains = [];
    this.components = [];
    const list = o.components || (this.kind === "audio"
      ? [new Component("Internal Volume", []), new Component("Internal Channel Volume", [])]
      : [new Component("AE.ADBE Opacity", opacityDefs()), new Component("AE.ADBE Motion", motionDefs(o.motion))]);
    for (const c of list) { c.item = this; this.components.push(c); }
  }
  async getName() { return host(this.name); }
  async getMediaType() { return host(this.kind === "audio" ? MediaType.AUDIO : MediaType.VIDEO); }
  async getComponentChain() {
    if (hooks.getComponentChain) hooks.getComponentChain(this); // peut lever
    return host(new Chain(this));
  }
  async getInPoint() {
    if (this.inPointThrows) throw new Error("in-point illisible");
    return host(tick(this.inTicks));
  }
  async getOutPoint() {
    if (this.outPointThrows) throw new Error("out-point illisible");
    return host(tick(this.inTicks + this.durTicks));
  }
  /* Pour les vérifications : matchNames de la chaîne réelle. */
  names() { return this.components.map((c) => c.matchName); }
  component(matchName) { return this.components.find((c) => c.matchName === matchName); }
  markChainsStale() { for (const c of this.chains) c.stale = true; }
}

/* ── Projet, séquences, chutier (calque d'effets) ────────────────────── */

function makeBinItem(kind, name, extra) {
  return Object.assign({ kind, name, children: [] }, extra || {});
}
function folder(name, children) { return makeBinItem("folder", name, { children: children || [] }); }
function clipItem(name, extra) { return makeBinItem("clip", name, extra); }
function sequenceItem(name) { return makeBinItem("sequence", name); }

/* Élément de timeline (séquence) pour la recherche du calque et des pistes. */
function timelineItem({ start, end, adjustment = false, projectItem = null, name = "" }) {
  return {
    name,
    async getStartTime() { return host(tick(start)); },
    async getEndTime() { return host(tick(end)); },
    async isAdjustmentLayer() { return host(!!adjustment); },
    async getProjectItem() { return host(projectItem); },
    async getName() { return host(name); },
  };
}

function makeSequence({ name = "Séquence", guid = null, tracks = [], playhead = 0, selection = [] } = {}) {
  const seq = {
    name,
    guid: guid || `seq-${name}`,
    tracks,      // [[timelineItem…], …] — index 0 = V1
    playhead,
    selection,
    overwrites: [],
    async getSelection() { return host({ getTrackItems: async () => host(seq.selection) }); },
    async getTimebase() { return host(String(state.timebase)); },
    async getVideoTrackCount() { return host(seq.tracks.length); },
    async getVideoTrack(i) {
      const items = seq.tracks[i] || [];
      return host({ getTrackItems: async () => host(items.slice()) });
    },
    async getPlayerPosition() { return host(tick(seq.playhead)); },
  };
  return seq;
}

const state = {
  timebase: Math.round(TPS / 25),
  effects: new Set(),
  root: folder("root", []),
  sequences: [],
  activeSequence: null,
};

const project = {
  name: "Projet de test",
  lockedAccess(fn) { stats.locks += 1; fn(); },
  executeTransaction(cb, label) {
    const ctx = { index: stats.tx, label, actions: [] };
    stats.tx += 1;
    if (hooks.beforeTransaction) hooks.beforeTransaction(ctx);
    const compound = {
      addAction(a) {
        if (!a || typeof a.run !== "function") throw new Error("action invalide");
        ctx.actions.push(a);
      },
    };
    try { cb(compound); } catch (e) { stats.txThrew += 1; throw e; }
    stats.maxActions = Math.max(stats.maxActions, ctx.actions.length);
    if (hooks.refuseTransaction && hooks.refuseTransaction(ctx)) { stats.txFailed += 1; return false; }
    const undo = [];
    const done = [];
    for (const a of ctx.actions) {
      if (hooks.dropAction && hooks.dropAction(a, ctx)) continue; // transaction NON atomique (perte silencieuse)
      try {
        const u = a.run();
        if (u) undo.push(u);
        done.push(a);
      } catch (e) {
        for (let i = undo.length - 1; i >= 0; i--) undo[i]();
        stats.txFailed += 1;
        return false;
      }
    }
    stats.txOk += 1;
    if (ctx.actions.length > 0) { stats.txOkNonEmpty += 1; stats.labels.push(label); }
    for (const a of done) { stats.actions += 1; stats.kinds[a.kind] = (stats.kinds[a.kind] || 0) + 1; }
    if (hooks.afterTransaction) hooks.afterTransaction(ctx);
    return true;
  },
  async getActiveSequence() { return host(state.activeSequence); },
  async getRootItem() { return host(FolderItem.cast(state.root)); },
  async getSequences() { return host(state.sequences.slice()); },
};

/* Vues « castées » comme dans UXP : un ProjectItem brut n'a PAS getItems ;
 * FolderItem.cast / ClipProjectItem.cast rendent null pour un autre type. */
const FolderItem = {
  cast(pi) {
    const base = pi && (pi.__base || pi);
    if (!base || base.kind !== "folder") return null;
    return { __base: base, name: base.name, getItems: async () => host(base.children.slice()) };
  },
};
const ClipProjectItem = {
  cast(pi) {
    const base = pi && (pi.__base || pi);
    if (!base || (base.kind !== "clip" && base.kind !== "sequence")) return null;
    return {
      __base: base,
      name: base.name,
      isSequence: async () => host(base.kind === "sequence"),
      getInPoint: base.inTicks != null ? async () => host(tick(base.inTicks)) : undefined,
      getOutPoint: base.outTicks != null ? async () => host(tick(base.outTicks)) : undefined,
    };
  },
};

const SequenceEditor = {
  getEditor(sequence) {
    return {
      createOverwriteItemAction(item, time, videoTrackIndex, audioTrackIndex) {
        return makeAction("overwrite", null, () => {
          if (hooks.overwrite) hooks.overwrite(item, time, videoTrackIndex); // peut lever
          sequence.overwrites.push({ item, at: ticksOf(time), videoTrackIndex, audioTrackIndex });
          return () => { sequence.overwrites.pop(); };
        });
      },
    };
  },
};

const fake = {
  // API simulée
  Project: { getActiveProject: async () => host(project) },
  VideoFilterFactory: {
    getMatchNames: async () => {
      // Premiere lent à répondre (projet lourd) : laisse le temps à une 2ᵉ
      // requête d'arriver pendant que la 1ʳᵉ travaille.
      if (hooks.matchNamesDelayMs) await new Promise((r) => setTimeout(r, hooks.matchNamesDelayMs));
      return host([...state.effects]);
    },
    getDisplayNames: async () => host([...state.effects]),
    createComponent: async (matchName) => {
      stats.createComponent += 1;
      if (hooks.createComponent) {
        const r = hooks.createComponent(matchName, stats.createComponent); // peut lever
        if (r !== undefined) return host(r);
      }
      return host(new Component(matchName, effectDefs.get(matchName) || [], { preInsertNoParams: true }));
    },
  },
  Constants: { MediaType, TrackItemType: { CLIP: 1 } },
  Keyframe: { INTERPOLATION_MODE_LINEAR: 0, INTERPOLATION_MODE_BEZIER: 5, INTERPOLATION_MODE_HOLD: 4 },
  TickTime: { createWithTicks: (t) => tick(t), TIME_ZERO: tick(0) },
  PointF: function (x, y) { this.x = x; this.y = y; },
  Color: function (r, g, b, a) { Object.assign(this, { r, g, b, a }); },
  FolderItem,
  ClipProjectItem,
  SequenceEditor,
};

// Outils de test (préfixés « _ » pour ne pas se confondre avec l'API).
const tools = {
  TPS, MediaType, stats, hooks, state, project,
  resetStats, resetHooks, host, tick,
  Component, TrackItem, Chain, Param,
  defineEffect, motionDefs, opacityDefs, op, plan,
  folder, clipItem, sequenceItem, timelineItem, makeSequence,
  /* Remet l'état à zéro et installe une séquence active portant `selection`. */
  reset({ selection = [], effects = [], timebase } = {}) {
    resetStats();
    resetHooks();
    state.effects = new Set(effects);
    if (timebase) state.timebase = timebase;
    state.root = folder("root", []);
    state.activeSequence = makeSequence({ name: "Active", selection });
    state.sequences = [state.activeSequence];
    return state.activeSequence;
  },
};

const resolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  return request === "premierepro" ? "premierepro" : resolve.call(this, request, ...rest);
};
require.cache.premierepro = { id: "premierepro", filename: "premierepro", loaded: true, exports: fake };

function clone(v) {
  if (v && typeof v === "object") return Array.isArray(v) ? v.slice() : { ...v };
  return v;
}

/* Petit vérificateur commun : `check(cond, libellé)` puis `done()` (code de
 * sortie 1 si un cas échoue). */
function checker(title) {
  let failures = 0;
  return {
    check(cond, label) {
      console.log(`${cond ? "  ✓" : "  ✗"} ${label}`);
      if (!cond) failures += 1;
    },
    done() {
      console.log(failures === 0 ? `${title} OK` : `${title} : ${failures} échec(s)`);
      process.exit(failures === 0 ? 0 : 1);
    },
  };
}

module.exports = Object.assign(tools, { fake, checker });
