/* Reconstruction de courbes eased par « cuisson » en keyframes linéaires denses.
 *
 * POURQUOI (mesuré le 2026-07-21) : passer un keyframe en mode BEZIER via UXP ne
 * courbe RIEN — les poignées par défaut sont alignées sur la corde, la courbe
 * reste exactement linéaire. Et UXP n'expose aucune API de poignées
 * (influence/vitesse). On reproduit donc la courbe native en posant un keyframe
 * LINÉAIRE par frame, sur la valeur eased exacte : comme Premiere rend frame par
 * frame, le mouvement rendu devient identique au natif par construction.
 *
 * Forme d'un keyframe reçu (protocole) : { t(offset ticks), value, i, iv,ii,ov,oi }
 * où value est un NOMBRE (scalaire) ou un objet {x,y} (point, ex. Position).
 * Modèle d'ease = After Effects (décodé, docs/RECHERCHE-FIDELITE-NATIVE §2) :
 * un segment [kf0,kf1] est une bézier cubique en (temps normalisé, valeur), dont
 * les poignées viennent de la vitesse (unités/s) et de l'influence (fraction) de
 * chaque côté : sortie de kf0 (ov, oi), entrée de kf1 (iv, ii).
 */

const TPS = 254016000000; // ticks par seconde (constante Premiere)

/* Bézier cubique 1D en u∈[0,1]. */
function cubic(u, p0, p1, p2, p3) {
  const m = 1 - u;
  return m * m * m * p0 + 3 * m * m * u * p1 + 3 * m * u * u * p2 + u * u * u * p3;
}

/* Inverse le graphe temporel : trouve u tel que X(u) = fx, X monotone croissant
 * (x1=oi, x2=1−ii ∈ [0,1]). Bisection — robuste, ~1e-12 en 40 itérations. */
function solveU(fx, x1, x2) {
  if (fx <= 0) return 0;
  if (fx >= 1) return 1;
  let lo = 0, hi = 1;
  for (let k = 0; k < 40; k++) {
    const mid = (lo + hi) / 2;
    if (cubic(mid, 0, x1, x2, 1) < fx) lo = mid; else hi = mid;
  }
  return (lo + hi) / 2;
}

function clamp01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
function isPointValue(v) { return v && typeof v === "object" && "x" in v && "y" in v; }

/* Modes d'interpolation Premiere (AGENTS.md §3.2) : seul un segment BÉZIER/ease
 * se cuit. LINÉAIRE et MAINTIEN doivent rester tels quels — sinon un « pop »
 * (flash, glitch, apparition image par image) devient une rampe douce. */
const MODE_LINEAR = 0;
const MODE_HOLD = 4;

/* Un segment porte-t-il une ease RÉELLE à reproduire ?
 * ⚠️ Ne PAS se contenter de la présence des clés : le parser émet des valeurs
 * par défaut (0) quand le .prfpset d'un autre outil/version ne porte pas les
 * champs d'ease. Cuire un segment sans ease produisait alors une fausse courbe
 * (double lissage) au lieu d'une droite — cassait les presets « d'ailleurs ».
 *
 * 2026-10-09 (audit P-03) — EASE « À L'ARRIVÉE ». CAUSE : seul le mode du
 * keyframe de DÉPART était regardé (linéaire → jamais cuit). Or la façon la
 * plus courante d'adoucir une arrivée est « clic droit sur le DERNIER keyframe
 * > Ease In » : le 1ᵉʳ reste linéaire, le 2ᵉ porte la décélération. Le segment
 * n'était pas cuit → mouvement linéaire (opacité à mi-course 55 au lieu de
 * 67,3 sur le preset le plus utilisé d'Isma ; 14 presets chez lui, 75 dans les
 * packs relevés). CORRECTION : faux si k0 est HOLD, faux si k0 ET k1 sont
 * LINÉAIRES ; sinon on calcule les deux poignées — un côté linéaire prend la
 * pente de la corde (robuste aux données d'autres outils, cf. segEase) — et
 * on ne cuit que si une poignée s'écarte de la corde. Des champs d'ease absents
 * ou nuls restent sur la corde → non cuits (garde ci-dessus préservée). */
function hasEase(k0, k1) {
  if (!k0 || !k1) return false;
  if (k0.i === MODE_HOLD) return false;
  if (k0.i === MODE_LINEAR && k1.i === MODE_LINEAR) return false;
  const present = (k0.oi != null || k0.ov != null || k1.ii != null || k1.iv != null);
  if (!present) return false;
  const dtSec = (Number(k1.t) - Number(k0.t)) / TPS;
  if (!(dtSec > 0)) return false;
  const isPoint = isPointValue(k0.value) && isPointValue(k1.value);
  const { oi, ii, ov, iv } = segEase(k0, k1, dtSec, isPoint);
  if (isPoint) {
    const dist = Math.hypot(k1.value.x - k0.value.x, k1.value.y - k0.value.y);
    if (!(dist > 1e-12)) return false; // aucun déplacement : rien à adoucir
    const s1 = (ov / dist) * oi * dtSec;
    const s2 = 1 - (iv / dist) * ii * dtSec;
    return Math.abs(s1 - oi) > 1e-4 || Math.abs(s2 - (1 - ii)) > 1e-4;
  }
  if (typeof k0.value !== "number" || typeof k1.value !== "number") return false;
  const v0 = k0.value, d = k1.value - k0.value;
  const y1 = v0 + ov * oi * dtSec;            // poignée sortante
  const y2 = k1.value - iv * ii * dtSec;      // poignée entrante
  const tol = 1e-6 * Math.max(1, Math.abs(d));
  return Math.abs(y1 - (v0 + d * oi)) > tol || Math.abs(y2 - (v0 + d * (1 - ii))) > tol;
}

/* Paramètres temporels communs d'un segment.
 * 2026-10-09 (audit P-03) : un côté LINÉAIRE (mode 0) prend la pente de la
 * corde ((v1 − v0)/dt ; distance/dt pour un point) — sa poignée tombe alors
 * sur la corde quelle que soit son influence. Premiere stocke déjà cette pente
 * (vitesse 308,26 = 90 / 0,292 s relevé par l'audit), mais un autre outil peut
 * ne rien écrire. */
function segEase(k0, k1, dtSec, isPoint) {
  let ov = k0.ov != null ? k0.ov : 0;
  let iv = k1.iv != null ? k1.iv : 0;
  if (dtSec > 0 && (k0.i === MODE_LINEAR || k1.i === MODE_LINEAR)) {
    const slope = isPoint
      ? Math.hypot(k1.value.x - k0.value.x, k1.value.y - k0.value.y) / dtSec
      : (k1.value - k0.value) / dtSec;
    if (k0.i === MODE_LINEAR) ov = slope;
    if (k1.i === MODE_LINEAR) iv = slope;
  }
  return {
    oi: clamp01(k0.oi != null ? k0.oi : 1 / 3),
    ii: clamp01(k1.ii != null ? k1.ii : 1 / 3),
    ov,
    iv,
  };
}

/* Valeur d'un paramètre SCALAIRE au temps-fraction fx∈[0,1] du segment. */
function scalarAt(fx, k0, k1, dtSec) {
  const v0 = k0.value, v1 = k1.value;
  const { oi, ii, ov, iv } = segEase(k0, k1, dtSec, false);
  const y1 = v0 + ov * oi * dtSec;      // poignée sortante (valeur)
  const y2 = v1 - iv * ii * dtSec;      // poignée entrante (valeur)
  return cubic(solveU(fx, oi, 1 - ii), v0, y1, y2, v1);
}

/* Progression s∈[0,1] le long du chemin au temps-fraction fx (paramètre de
 * POINT : la vitesse est une vitesse scalaire le long du chemin). Le point est
 * ensuite interpolé linéairement entre P0 et P1 par s — exact pour un chemin
 * axial (slide/appear) ; la courbure spatiale (tangentes) est différée. */
function progressionAt(fx, k0, k1, dtSec) {
  const { oi, ii, ov, iv } = segEase(k0, k1, dtSec, true);
  const p0 = k0.value, p1 = k1.value;
  const dist = Math.hypot(p1.x - p0.x, p1.y - p0.y);
  let s1 = 0, s2 = 1;
  if (dist > 1e-12) { s1 = (ov / dist) * oi * dtSec; s2 = 1 - (iv / dist) * ii * dtSec; }
  // GARDE-FOU : l'unité de vitesse d'un keyframe de POINT n'est pas garantie
  // homogène à la distance normalisée. Une poignée hors [0,1] ferait sortir
  // l'élément de l'écran avant de revenir (animation cassée). On borne :
  // au-delà du raisonnable, on retombe sur une progression linéaire.
  if (!(s1 >= -0.05 && s1 <= 1.05 && s2 >= -0.05 && s2 <= 1.05)) return fx;
  return cubic(solveU(fx, oi, 1 - ii), 0, clamp01(s1), clamp01(s2), 1);
}

/* Valeur (nombre ou {x,y}) au temps-fraction fx du segment [k0,k1]. */
function valueAt(fx, k0, k1, dtSec, isPoint) {
  if (!isPoint) return scalarAt(fx, k0, k1, dtSec);
  const s = progressionAt(fx, k0, k1, dtSec);
  return { x: k0.value.x + s * (k1.value.x - k0.value.x),
           y: k0.value.y + s * (k1.value.y - k0.value.y) };
}

/* ── PARTIE VISIBLE DU CLIP (2026-10-09, audit P-09 + P-10 ; décision Q6) ──
 *
 * P-09 — CAUSE : le budget de 400 ne bornait que l'échantillonnage DANS le
 * clip ; les extrémités de CHAQUE segment du preset étaient posées même hors du
 * clip, et le chemin non cuit n'avait ni fenêtre ni plafond. Un shake de
 * 12 min posait 10 217 keyframes par clip de 3 s (206 utiles) en une
 * transaction synchrone, Premiere figé. (Le « 151 » annoncé au commit bb81a5e
 * ne comptait que les points DANS le clip ; le total réel était 1 084.)
 * CORRECTION : au-delà de KEYFRAME_BUDGET points pour un réglage, on ne garde
 * que la partie visible — jusqu'à la fin du clip + 1 image — plus un keyframe
 * au bord portant la valeur exacte de la courbe (cuite, linéaire, ou tenue si
 * HOLD). Même règle sur le chemin non cuit, interpolations comprises.
 * Contrepartie (Q6) : rallonger le clip ensuite n'allonge pas le shake.
 *
 * P-10 — CAUSE : l'ancrage « Sortie » d'un preset plus long que le clip était
 * clampé à l'in-point (plusieurs keyframes au même tick, le premier écrasé :
 * un scintillement de 0,3 s démarrait faux), contraire à AGENTS §3.2 0ter ; un
 * offset négatif sur un rush à in-point 0 donnait un temps négatif.
 * CORRECTION : plus de clamp ; tous les keyframes situés AVANT l'in-point sont
 * remplacés par UN keyframe à l'in-point portant la valeur de la courbe à cet
 * instant (la borne basse de la fenêtre P-09 est donc l'in-point, exact). */
const KEYFRAME_BUDGET = 400;

function lerpValue(a, b, f) {
  if (typeof a === "number" && typeof b === "number") return a + (b - a) * f;
  if (isPointValue(a) && isPointValue(b)) return { x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f };
  return f < 1 ? a : b; // valeur non interpolable (booléen…) : tenue
}

/* Valeur de la courbe d'un réglage au tick `ticks` (ancrage appliqué par
 * mapTick) : ease cuite si le segment en porte, maintien si HOLD, sinon
 * linéaire (un bézier sans poignées rend une droite, AGENTS §3.1 item 6). */
function curveValueAt(kfs, mapTick, ticks) {
  const first = kfs[0];
  if (ticks <= mapTick(Number(first.t))) return first.value;
  const isPoint = isPointValue(first.value);
  for (let i = 1; i < kfs.length; i++) {
    const k0 = kfs[i - 1], k1 = kfs[i];
    const T0 = mapTick(Number(k0.t)), T1 = mapTick(Number(k1.t));
    if (ticks >= T1) continue;
    if (!(T1 > T0)) return k1.value;
    if (k0.i === MODE_HOLD) return k0.value;
    const fx = (ticks - T0) / (T1 - T0);
    if (hasEase(k0, k1)) return valueAt(fx, k0, k1, (Number(k1.t) - Number(k0.t)) / TPS, isPoint);
    return lerpValue(k0.value, k1.value, fx);
  }
  return kfs[kfs.length - 1].value;
}

/* Mode du keyframe qui ouvre le segment contenant `ticks`. */
function modeAt(kfs, mapTick, ticks) {
  let mode = kfs[0].i;
  for (const k of kfs) {
    if (mapTick(Number(k.t)) <= ticks) mode = k.i; else break;
  }
  return mode;
}

/* Coupe à l'in-point (P-10) puis, au-delà de KEYFRAME_BUDGET points, fenêtre
 * jusqu'à la fin du clip + 1 image (P-09). points : [{ ticks, value, mode? }].
 * Deux points au même tick : le dernier l'emporte (comme dans Premiere). */
function fitToClip(points, valueAtTick, modeAtTick, clip, step) {
  let out = [];
  for (const p of points.slice().sort((a, b) => a.ticks - b.ticks)) {
    if (out.length > 0 && out[out.length - 1].ticks === p.ticks) out[out.length - 1] = p;
    else out.push(p);
  }
  const result = { points: out, cutAtIn: false, windowed: false };
  if (!clip || !isFinite(clip.inTicks) || clip.inKnown === false) return result;
  const border = (ticks) => {
    const pt = { ticks, value: valueAtTick(ticks) };
    if (modeAtTick) pt.mode = modeAtTick(ticks);
    return pt;
  };
  const lo = Math.round(clip.inTicks);
  if (out.length > 0 && out[0].ticks < lo) {
    const kept = out.filter((p) => p.ticks >= lo);
    if (kept.length === 0 || kept[0].ticks > lo) kept.unshift(border(lo));
    out = kept;
    result.cutAtIn = true;
  }
  if (out.length > KEYFRAME_BUDGET && clip.durTicks > 0) {
    const hi = Math.round(clip.inTicks + clip.durTicks + step);
    if (out[out.length - 1].ticks > hi) {
      const kept = out.filter((p) => p.ticks <= hi);
      if (kept.length === 0 || kept[kept.length - 1].ticks < hi) kept.push(border(hi));
      out = kept;
      result.windowed = true;
    }
  }
  result.points = out;
  return result;
}

/* Chemin NON cuit : un point par keyframe du preset, avec son mode, coupé et
 * fenêtré comme la cuisson (P-09/P-10). Retour { points, cutAtIn, windowed }. */
function plainKeyframes(keyframes, mapTick, timebase, clip) {
  const kfs = keyframes.slice().sort((a, b) => Number(a.t) - Number(b.t));
  const points = kfs.map((k) => ({ ticks: Math.round(mapTick(Number(k.t))), value: k.value, mode: k.i }));
  const step = Math.max(1, Math.round(timebase || TPS / 30));
  return fitToClip(points, (t) => curveValueAt(kfs, mapTick, t), (t) => modeAt(kfs, mapTick, t), clip, step);
}

/* Cuit un paramètre keyframé en une liste dense [{ ticks, value }] LINÉAIRE.
 *   keyframes : [{ t(offset), value(nombre|{x,y}), iv,ii,ov,oi }]
 *   mapTick   : offset(ticks) → tick final (applique l'ancrage keyframeTicks)
 *   timebase  : ticks/frame de la séquence (aligne la densité sur les frames)
 * Retour { baked, points, cutAtIn, windowed } — baked=false si aucun segment
 * n'a d'ease (le caller retombe alors sur le tracé natif, plainKeyframes). */
function bakeParam(keyframes, mapTick, timebase, clip) {
  const kfs = keyframes.slice().sort((a, b) => Number(a.t) - Number(b.t));
  if (kfs.length < 2 || !kfs.some((_, i) => i > 0 && hasEase(kfs[i - 1], kfs[i]))) {
    return { baked: false, points: [] };
  }
  const isPoint = isPointValue(kfs[0].value);
  const step = Math.max(1, Math.round(timebase || TPS / 30));
  // Densité de l'échantillonnage DANS la fenêtre visible du clip, bornée par
  // paramètre (et non par segment) à KEYFRAME_BUDGET points. Les extrémités de
  // segments hors du clip, elles, sont retirées par fitToClip (voir plus haut :
  // ce budget seul ne bornait pas le total).
  const BUDGET = KEYFRAME_BUDGET;
  // Fenêtre visible : [inTicks, inTicks+durTicks] si connue, sinon tout.
  const winA = clip && clip.durTicks > 0 ? clip.inTicks : -Infinity;
  const winB = clip && clip.durTicks > 0 ? clip.inTicks + clip.durTicks : Infinity;

  // Passe 1 : segments cuisibles + coût total à la densité nominale.
  const segs = [];
  let cost = 0;
  for (let i = 1; i < kfs.length; i++) {
    const k0 = kfs[i - 1], k1 = kfs[i];
    const T0 = mapTick(Number(k0.t)), T1 = mapTick(Number(k1.t));
    if (T1 <= T0 || !hasEase(k0, k1)) { segs.push({ k0, k1, T0, T1, bake: false }); continue; }
    const a = Math.max(T0, winA), b = Math.min(T1, winB); // portion visible
    const bake = b > a;
    if (bake) cost += Math.floor((b - a) / step);
    segs.push({ k0, k1, T0, T1, a, b, bake });
  }
  const s = cost > BUDGET ? step * Math.ceil(cost / BUDGET) : step;

  const out = [];
  const push = (ticks, value) => out.push({ ticks: Math.round(ticks), value });
  push(mapTick(Number(kfs[0].t)), kfs[0].value);
  for (const seg of segs) {
    if (!seg.bake) { // linéaire / maintien : tracé natif
      // 2026-10-09 (audit P-03, A1#12) : un HOLD au milieu d'un réglage cuit
      // devenait une RAMPE (tous les points cuits sont linéaires). On pose la
      // valeur de départ 1 tick avant le keyframe suivant : palier, puis coupe.
      if (seg.k0.i === MODE_HOLD && Math.round(seg.T1) - 1 > Math.round(seg.T0)) push(Math.round(seg.T1) - 1, seg.k0.value);
      push(seg.T1, seg.k1.value);
      continue;
    }
    const { k0, k1, T0, T1 } = seg;
    const dtSec = (Number(k1.t) - Number(k0.t)) / TPS; // durée preset (invariante au stretch)
    for (let tf = (Math.floor(seg.a / s) + 1) * s; tf < seg.b; tf += s) {
      push(tf, valueAt((tf - T0) / (T1 - T0), k0, k1, dtSec, isPoint));
    }
    push(T1, k1.value);
  }
  const fitted = fitToClip(out, (t) => curveValueAt(kfs, mapTick, t), null, clip, step);
  return { baked: true, points: fitted.points, cutAtIn: fitted.cutAtIn, windowed: fitted.windowed };
}

module.exports = {
  bakeParam, plainKeyframes, fitToClip, curveValueAt, KEYFRAME_BUDGET,
  scalarAt, progressionAt, valueAt, solveU, cubic, TPS, hasEase,
};
