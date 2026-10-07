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
 * (double lissage) au lieu d'une droite — cassait les presets « d'ailleurs ». */
function hasEase(k0, k1) {
  if (!k0 || !k1) return false;
  if (k0.i === MODE_HOLD || k0.i === MODE_LINEAR) return false;
  const ov = k0.ov || 0, iv = k1.iv || 0, oi = k0.oi || 0, ii = k1.ii || 0;
  const present = (k0.oi != null || k0.ov != null || k1.ii != null || k1.iv != null);
  return present && (Math.abs(ov) > 1e-9 || Math.abs(iv) > 1e-9 || oi > 1e-6 || ii > 1e-6);
}

/* Paramètres temporels communs d'un segment. */
function segEase(k0, k1) {
  return {
    oi: clamp01(k0.oi != null ? k0.oi : 1 / 3),
    ii: clamp01(k1.ii != null ? k1.ii : 1 / 3),
    ov: k0.ov != null ? k0.ov : 0,
    iv: k1.iv != null ? k1.iv : 0,
  };
}

/* Valeur d'un paramètre SCALAIRE au temps-fraction fx∈[0,1] du segment. */
function scalarAt(fx, k0, k1, dtSec) {
  const v0 = k0.value, v1 = k1.value;
  const { oi, ii, ov, iv } = segEase(k0, k1);
  const y1 = v0 + ov * oi * dtSec;      // poignée sortante (valeur)
  const y2 = v1 - iv * ii * dtSec;      // poignée entrante (valeur)
  return cubic(solveU(fx, oi, 1 - ii), v0, y1, y2, v1);
}

/* Progression s∈[0,1] le long du chemin au temps-fraction fx (paramètre de
 * POINT : la vitesse est une vitesse scalaire le long du chemin). Le point est
 * ensuite interpolé linéairement entre P0 et P1 par s — exact pour un chemin
 * axial (slide/appear) ; la courbure spatiale (tangentes) est différée. */
function progressionAt(fx, k0, k1, dtSec) {
  const { oi, ii, ov, iv } = segEase(k0, k1);
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

/* Cuit un paramètre keyframé en une liste dense [{ ticks, value }] LINÉAIRE.
 *   keyframes : [{ t(offset), value(nombre|{x,y}), iv,ii,ov,oi }]
 *   mapTick   : offset(ticks) → tick final (applique l'ancrage keyframeTicks)
 *   timebase  : ticks/frame de la séquence (aligne la densité sur les frames)
 * Retour { baked, points } — baked=false si aucun segment n'a d'ease (le caller
 * retombe alors sur le tracé natif keyframe-par-keyframe). */
function bakeParam(keyframes, mapTick, timebase, clip) {
  const kfs = keyframes.slice().sort((a, b) => Number(a.t) - Number(b.t));
  if (kfs.length < 2 || !kfs.some((_, i) => i > 0 && hasEase(kfs[i - 1], kfs[i]))) {
    return { baked: false, points: [] };
  }
  const isPoint = isPointValue(kfs[0].value);
  const step = Math.max(1, Math.round(timebase || TPS / 30));
  // BUDGET GLOBAL par paramètre (et non par segment) : un preset long (shake de
  // 12 min) produisait des dizaines de milliers de keyframes dans UNE
  // transaction synchrone → Premiere figé. On borne le TOTAL, et on n'échantillonne
  // que la fenêtre réellement visible du clip (`clip`), le reste étant hors écran.
  const BUDGET = 400;
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
    if (!seg.bake) { push(seg.T1, seg.k1.value); continue; } // linéaire / maintien : tracé natif
    const { k0, k1, T0, T1 } = seg;
    const dtSec = (Number(k1.t) - Number(k0.t)) / TPS; // durée preset (invariante au stretch)
    for (let tf = (Math.floor(seg.a / s) + 1) * s; tf < seg.b; tf += s) {
      push(tf, valueAt((tf - T0) / (T1 - T0), k0, k1, dtSec, isPoint));
    }
    push(T1, k1.value);
  }
  return { baked: true, points: out };
}

module.exports = { bakeParam, scalarAt, progressionAt, valueAt, solveU, cubic, TPS, hasEase };
