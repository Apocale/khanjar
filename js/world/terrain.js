// Khanjar's ground (adapted from the Isma Plugins landing page, its left world): volcanic ridges across the whole
// width, layered ranges far behind them, basalt facets edged by the moon and lava running in the valleys.
// The curvature (crests and folds, valleys) is measured once, here: lava pools in the valleys.
// The summit where the dagger is planted sits right of centre, clear of the words on the left.
import { NOISE, TOD, SKY } from './glsl.js';

export const CAM_Z = 16;                         // the desktop camera stands at (0, 2, 16), looking down -z
export const ROCK = { x: 4.5, z: -4 };            // the summit where the dagger is planted (right of centre)

// ---- the land (CPU, once) ----
function makeNoise(seed) {
  const p = new Uint8Array(512), perm = new Uint8Array(256);
  for (let i = 0; i < 256; i++) perm[i] = i;
  let s = seed >>> 0; const rnd = () => (s = (s * 1664525 + 1013904223) >>> 0) / 4294967296;
  for (let i = 255; i > 0; i--) { const j = Math.floor(rnd() * (i + 1)); const t = perm[i]; perm[i] = perm[j]; perm[j] = t; }
  for (let i = 0; i < 512; i++) p[i] = perm[i & 255];
  const GX = [1, -1, 1, -1, 1, -1, 0, 0], GY = [1, 1, -1, -1, 0, 0, 1, -1];
  const F2 = .5 * (Math.sqrt(3) - 1), G2 = (3 - Math.sqrt(3)) / 6;
  return (x, y) => {
    const t0 = (x + y) * F2, i = Math.floor(x + t0), j = Math.floor(y + t0), t = (i + j) * G2;
    const x0 = x - i + t, y0 = y - j + t, i1 = x0 > y0 ? 1 : 0, j1 = 1 - i1;
    const x1 = x0 - i1 + G2, y1 = y0 - j1 + G2, x2 = x0 - 1 + 2 * G2, y2 = y0 - 1 + 2 * G2;
    const ii = i & 255, jj = j & 255;
    let n = 0, a, g;
    a = .5 - x0 * x0 - y0 * y0; if (a > 0) { g = p[ii + p[jj]] & 7; a *= a; n += a * a * (GX[g] * x0 + GY[g] * y0); }
    a = .5 - x1 * x1 - y1 * y1; if (a > 0) { g = p[ii + i1 + p[jj + j1]] & 7; a *= a; n += a * a * (GX[g] * x1 + GY[g] * y1); }
    a = .5 - x2 * x2 - y2 * y2; if (a > 0) { g = p[ii + 1 + p[jj + 1]] & 7; a *= a; n += a * a * (GX[g] * x2 + GY[g] * y2); }
    return 70 * n;
  };
}
const nA = makeNoise(7), nB = makeNoise(19), nC = makeNoise(31);
const sstep = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };

// where a point lies across the view, seen from just behind the desktop camera: < 0 on Khanjar's side, > 0 on Organizer's
const azOf = (x, z) => Math.atan2(x, CAM_Z + 4 - z);
const g2 = (x, z, cx, cz, sx, sz) => { const dx = (x - cx) / sx, dz = (z - cz) / sz; return Math.exp(-(dx * dx + dz * dz)); };
const range = (x, o) => { const v = 1 - Math.abs(nB(x * .07 + o, o * .37)); return v * v * (.55 + .45 * (nA(x * .02, o) * .5 + .5)); };

// soft rolls, a far range and the summit where the dagger stands: under both the rock and the hills
function baseH(x, z) {
  const fz = (z + 52) / 13;
  return -.25 + .8 * (nC(x * .03, z * .045) * .5 + .5) + 1.2 * g2(x, z, 2, -12, 11, 7) + 1.6 * g2(x, z, -9, -24, 13, 8)
    + 3 * Math.exp(-fz * fz) * (.65 + .35 * nB(x * .035, 7.1)) + 2.5 * g2(x, z, ROCK.x, ROCK.z, 5.06, 4.08);
}

// Frutiger Aero's rolling hills, layered so their folds show
const HILLS = [   // x, z, height, spread x, spread z
  [1.5, -2, 1.5, 6, 4.5], [5.5, -8, 3.3, 7, 5], [13, -18, 4.2, 9, 6], [9, 1, 1.6, 6, 4],
  [6, -34, 4.4, 12, 7], [22, -30, 5, 12, 8], [38, -22, 4.4, 12, 8], [8, 7.5, .7, 10, 6],
];

function rawH(x, z) {
  const az = azOf(x, z), R = 0, b = baseH(x, z);   // rock everywhere: the night has no Organizer side here
  let rock = b, hill = b;
  if (R < 1) {
    const r = Math.hypot(x, z - CAM_Z), far = sstep(11, 42, r), near = 1 - sstep(7, 24, r);
    let h = 0, a = 1, f = .075;
    for (let o = 0; o < 4; o++) { const v = 1 - Math.abs(nA(x * f, z * f * 1.25)); h += a * v * v * v; a *= .42; f *= 2.05; }
    const fine = near * (.55 + .45 * sstep(.05, -.25, az));
    if (fine > 0) { const v = 1 - Math.abs(nA(x * 1.5 + 31, z * 1.8)); h += .32 * fine * v * v * v; }   // finer facets near the camera
    rock = (h - .4) * (.35 + 2.4 * far) + 1.8 * far * (nB(x * .02, z * .02) * .5 + .5) - .2;
    rock += 2.4 * range(x, 11) * g2(0, z, 0, -31, 1, 6) + 4.4 * range(x * .7, 23) * g2(0, z, 0, -64, 1, 9);   // two ranges behind
    const dx = (x - ROCK.x) / 6.8, dz = (z - ROCK.z) / 5.4, k = Math.max(0, 1 - Math.sqrt(dx * dx + dz * dz));
    if (k > 0) rock = Math.max(rock, 2.7 * Math.pow(k, 1.2) + (h - .55) * .45 * k);
  }
  if (R > 0) {
    hill = -.25 + .45 * nC(x * .025, z * .035);
    for (let i = 0; i < HILLS.length; i++) { const c = HILLS[i]; hill += c[2] * g2(x, z, c[0], c[1], c[3], c[4]); }
    hill = b + (hill - b) * sstep(-.05, .2, az);
  }
  return rock + (hill - rock) * R;
}
// the summit is cut flat where the stone sits
export const PLATEAU = rawH(ROCK.x, ROCK.z) - .22;
export function groundH(x, z) {
  const h = rawH(x, z), r = Math.hypot(x - ROCK.x, z - ROCK.z);
  return r > 1.5 ? h : h + (PLATEAU - h) * sstep(1.5, .85, r);
}

// a coarse grid (1.25 units) of the land, read back bilinearly: the far land comes from it (a unit there is a few
// pixels), and so does the curvature at a 2.5-unit scale (the valleys where the lava pools)
let coarseGrid = null;
function coarse() {
  if (coarseGrid) return coarseGrid;
  const S = 1.25, x0 = -104, z0 = -112, nx = 168, nz = 108, Hc = new Float32Array(nx * nz);
  for (let j = 0; j < nz; j++) for (let i = 0; i < nx; i++) Hc[j * nx + i] = groundH(x0 + i * S, z0 + j * S);
  const L = new Float32Array(nx * nz);
  for (let j = 2; j < nz - 2; j++) for (let i = 2; i < nx - 2; i++) {
    const c = j * nx + i;
    L[c] = (Hc[c - 2] + Hc[c + 2] + Hc[c - 2 * nx] + Hc[c + 2 * nx] - 4 * Hc[c]) / (4 * S * S);
  }
  const read = (A, x, z) => {
    const fx = Math.min(nx - 1.001, Math.max(0, (x - x0) / S)), fz = Math.min(nz - 1.001, Math.max(0, (z - z0) / S));
    const i = Math.floor(fx), j = Math.floor(fz), u = fx - i, v = fz - j, c = j * nx + i;
    return (A[c] * (1 - u) + A[c + 1] * u) * (1 - v) + (A[c + nx] * (1 - u) + A[c + nx + 1] * u) * v;
  };
  return (coarseGrid = { h: (x, z) => read(Hc, x, z), lap: (x, z) => read(L, x, z) });
}

// where the lava pools near the camera, for the embers to rise from: valleys on Khanjar's side, and round the stone
export function lavaSpots(n, rnd = Math.random) {
  const G = coarse(), out = [];
  for (let tries = 0; out.length < n && tries < n * 60; tries++) {
    const pool = rnd() < .3;
    const x = pool ? ROCK.x + (rnd() - .5) * 3.4 : -15 + rnd() * 30, z = pool ? ROCK.z + (rnd() - .5) * 2.6 : -12 + rnd() * 18;
    if (!pool && G.lap(x, z) < .2) continue;
    out.push([x, groundH(x, z), z]);
  }
  return out;
}

// ---- the shaders ----
const vertexShader = /* glsl */`
attribute vec4 aNd;
attribute float aLn;
varying vec3 vW, vN;
varying vec2 vL;
void main(){
  vec4 w = modelMatrix * vec4(position, 1.);
  vW = w.xyz; vN = aNd.xyz; vL = vec2(aNd.w, aLn);
  gl_Position = projectionMatrix * viewMatrix * w;
}`;

const fragmentShader = /* glsl */`
${NOISE}
${TOD}
${SKY}
uniform vec3 uCam, uSunDir, uMoonDir, uRock, uFoot;   // uFoot: half sizes of the stone's foot, its turn
uniform float uHeat, uShine, uSkyTop, uHorizon;
uniform vec2 uShock;      // the strike: x = radius of the ring of light running out from the stone, y = its strength
uniform vec4 uScrim;
varying vec3 vW, vN;
varying vec2 vL;

// distance to the nearest cell border (the lava runs along the borders)
float cracks(vec2 x){
  vec2 n = floor(x), f = fract(x), mg, mr;
  float md = 8.;
  for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++){
    vec2 g = vec2(i, j), r = g + hash22(n + g) - f;
    float d = dot(r, r);
    if (d < md){ md = d; mr = r; mg = g; }
  }
  md = 8.;
  for (int j = -2; j <= 2; j++) for (int i = -2; i <= 2; i++){
    vec2 g = mg + vec2(i, j), r = g + hash22(n + g) - f;
    if (dot(mr - r, mr - r) > 1e-5) md = min(md, dot(.5 * (mr + r), normalize(r - mr)));
  }
  return md;
}

void main(){
  float d = dayAt(gl_FragCoord.xy), s = seamDist(gl_FragCoord.xy);
  vec3 V = normalize(uCam - vW);
  float dist = length(uCam - vW);
  vec3 Nf = normalize(cross(dFdx(vW), dFdy(vW)));
  if (Nf.y < 0.) Nf = -Nf;
  float fwW = length(fwidth(vW.xz));                    // derivatives here, outside the branches below
  vec3 Ns = normalize(vN);
  vec3 N = normalize(mix(Nf, Ns, smoothstep(.3, .8, d)));
  vec2 sq = smoothstep(uScrim.xy - 110., uScrim.xy + 30., gl_FragCoord.xy) * (1. - smoothstep(uScrim.zw - 30., uScrim.zw + 110., gl_FragCoord.xy));
  float scrim = sq.x * sq.y;
  float crest = smoothstep(-.03, -.14, vL.y), fold = smoothstep(.03, .14, vL.y);
  float sil = smoothstep(.17, .02, dot(N, V));
  float pr = length(vW.xz - uRock.xz);
  float pulse = .7 + .3 * sin(uTime * 1.15 + vW.x * .55 - vW.z * .35);   // the lava breathes, in slow waves

  // ---- night: basalt facets edged by the moon, lava in the valleys lighting the rock around it ----
  vec3 night = vec3(0.);
  if (d < .5){
    vec3 alb = vec3(.011, .0105, .013) * (.7 + .6 * vnoise(vW.xz * 2.3));
    vec3 moon = vec3(.34, .4, .62);
    float ml = max(dot(Nf, uMoonDir), 0.);
    night = alb * (ml * ml * moon * 3.4 + vec3(.008, .008, .012));
    night += moon * pow(max(dot(Nf, normalize(uMoonDir + V)), 0.), 48.) * .11 * (1. - smoothstep(22., 55., dist));
    float mask = smoothstep(.06, .3, vL.y) * (.4 + .6 * smoothstep(.25, .65, vnoise(vW.xz * .12 + 3.)));
    mask = max(mask, smoothstep(4., 1.2, pr) * .9) * (1. - .97 * scrim);
    if (mask > .01){
      vec2 cp = vW.xz * .62 + (vec2(vnoise(vW.xz * .6), vnoise(vW.xz * .6 + 9.)) - .5) * .9;
      float edge = cracks(cp), fw = fwW * .37;
      float near = smoothstep(95., 25., dist);
      float flow = .5 + .5 * vnoise(vW.xz * .45 + vec2(uTime * .11, -uTime * .07));
      float lava = mask * (.4 + .8 * flow) * pulse * (1. + uHeat * .9);
      float core = 1. - smoothstep(0., .016 + fw, edge), crack = 1. - smoothstep(0., .05 + fw, edge);
      night += (vec3(1., .55, .16) * core * 2. * near + vec3(1., .1, .03) * crack * 1.1 * near + vec3(.5, .04, .01) * exp(-edge * 22.) * .3) * lava;
      night += vec3(1., .26, .07) * lava * exp(-edge * 6.5) * (.2 + .8 * (1. - Nf.y)) * .3;      // the faces next to the cracks
    }
    // the lava seeping round the foot of the stone (an ellipse turned with it)
    vec2 lp = vW.xz - uRock.xz, cs = vec2(cos(uFoot.z), sin(uFoot.z)); lp = vec2(lp.x * cs.x - lp.y * cs.y, lp.x * cs.y + lp.y * cs.x);
    float ring = length(lp / uFoot.xy);
    night += vec3(1., .36, .08) * exp(-pow((ring - 1.08) / .18, 2.)) * (.8 + .4 * pulse) * (1. + uHeat) * 1.4;
    // the strike: a ring of light runs out through the cracks from the foot of the stone
    if (uShock.y > .001){
      float sw = exp(-pow((pr - uShock.x) / (.35 + uShock.x * .08), 2.)) * uShock.y;
      night += vec3(1., .42, .12) * sw * (.25 + 1.6 * mask) * smoothstep(40., 12., dist);
    }
    vec3 toFire = normalize(uRock + vec3(0., -1.4, 1.6) - vW);
    night += alb * vec3(1., .22, .07) * 22. * exp(-pr * .6) * (.3 + .7 * max(dot(Nf, toFire), 0.)) * (1. + uHeat * .8) * (1. - .6 * scrim);
    night *= 1. - .35 * scrim;
  }

  // ---- dusk and day ----
  vec3 day = vec3(0.), duskc = vec3(0.);
  if (d > .001){
    float up = Ns.y;
    vec3 alb = mix(toLin(vec3(.1, .45, .13)), toLin(vec3(.33, .74, .19)), smoothstep(.55, .92, up));
    alb = mix(alb, toLin(vec3(.74, .93, .38)), crest * smoothstep(.86, .99, up));
    alb *= 1. - .4 * fold;
    // dusk: a dark land, the last light along the ridges turned to the horizon
    float back = clamp(dot(N, normalize(vec3(0., .3, -1.))) + .2, 0., 1.);
    float rim = pow(1. - max(dot(N, V), 0.), 8.) * back;
    duskc = vec3(.008, .007, .011) + alb * .018 + vec3(1., .46, .3) * (rim * .3 + crest * sil * .7);
    if (d > .5){
      float sl = max(dot(N, uSunDir), 0.);
      day = alb * (toLin(vec3(.66, .84, 1.)) * (.55 + .55 * up) + vec3(1., .95, .82) * sl * .7);
      day += vec3(1.) * crest * (smoothstep(.93, 1., up) * (1. - sil) * .24 + sil * 1.1) * (1. + .5 * uShine);   // the white crest
      day += toLin(vec3(.85, .95, 1.)) * pow(max(dot(reflect(-V, N), normalize(vec3(.25, .5, -1.))), 0.), 14.) * .14;
      day *= mix(vec3(.5, .4, .34), vec3(1.), smoothstep(.55, .97, d));   // late light near the dusk: lower, warmer
    }
  }
  vec3 col = mix(mix(night, duskc, smoothstep(0., .5, d)), day, smoothstep(.5, 1., d));
  col = toSRGB(col / (1. + col * .12));

  // aerial perspective: by night a moonlit blue-violet haze layers the ranges; by day the far hills pale into the sky
  float el = asin(clamp(-V.y, -1., 1.)), az = atan(-V.x, V.z);
  vec3 fogC = airAt(d, s, clamp((el - uHorizon) / (uSkyTop - uHorizon), 0., 1.), az);
  float fog = mix(1. - exp(-max(dist - 21., 0.) * .03), 1. - exp(-pow(max(dist - 14., 0.) * .0125, 1.5)), d);
  fog = max(fog, smoothstep(85., 122., dist));
  gl_FragColor = vec4(mix(col, fogC, clamp(fog, 0., 1.)), 1.);
}`;

export function makeTerrain(THREE, shared, { cols = 360, rows = 200 } = {}) {
  const oz = 20, rMin = 4.5, rMax = 125, aMax = 52 * Math.PI / 180, C = cols + 1;
  const n = C * (rows + 1), G = coarse(), dA = 2 * aMax / cols;
  const pos = new Float32Array(n * 3), nd = new Float32Array(n * 4), ln = new Float32Array(n);
  const rr = new Float64Array(rows + 1);
  for (let j = 0, k = 0; j <= rows; j++) {
    const r = rr[j] = rMin * Math.pow(rMax / rMin, j / rows);
    for (let i = 0; i <= cols; i++, k++) {
      const a = (i / cols * 2 - 1) * aMax, x = Math.sin(a) * r, z = oz - Math.cos(a) * r;
      pos[k * 3] = x; pos[k * 3 + 1] = r < 32 ? groundH(x, z) : G.h(x, z); pos[k * 3 + 2] = z;
      ln[k] = G.lap(x, z);
    }
  }
  // the normal and the curvature, from the neighbours on the grid (polar: around the fan's origin)
  const Y = k => pos[k * 3 + 1];
  for (let j = 0, k = 0; j <= rows; j++) {
    const j0 = Math.max(0, j - 1), j1 = Math.min(rows, j + 1), r = rr[j], r0 = rr[j0], r1 = rr[j1];
    for (let i = 0; i <= cols; i++, k++) {
      const i0 = Math.max(0, i - 1), i1 = Math.min(cols, i + 1);
      const ka0 = j * C + i0, ka1 = j * C + i1, kr0 = j0 * C + i, kr1 = j1 * C + i;
      const tax = pos[ka1 * 3] - pos[ka0 * 3], tay = Y(ka1) - Y(ka0), taz = pos[ka1 * 3 + 2] - pos[ka0 * 3 + 2];
      const trx = pos[kr1 * 3] - pos[kr0 * 3], trY = Y(kr1) - Y(kr0), trz = pos[kr1 * 3 + 2] - pos[kr0 * 3 + 2];
      let nx = trY * taz - trz * tay, ny = trz * tax - trx * taz, nz = trx * tay - trY * tax;
      if (ny < 0) { nx = -nx; ny = -ny; nz = -nz; }
      const l = Math.hypot(nx, ny, nz) || 1;
      nd[k * 4] = nx / l; nd[k * 4 + 1] = ny / l; nd[k * 4 + 2] = nz / l;
      let lap = 0;
      if (j > 0 && j < rows && i > 0 && i < cols) {
        const f = Y(k), h0 = r - r0, h1 = r1 - r;
        const frr = 2 * (Y(kr1) * h0 + Y(kr0) * h1 - f * (h0 + h1)) / (h0 * h1 * (h0 + h1));
        const fr = (Y(kr1) - Y(kr0)) / (h0 + h1), faa = (Y(ka1) - 2 * f + Y(ka0)) / (dA * dA);
        lap = frr + fr / r + faa / (r * r);
      }
      nd[k * 4 + 3] = lap;
    }
  }
  const idx = new Uint32Array(cols * rows * 6);
  let q = 0;
  for (let j = 0; j < rows; j++) for (let i = 0; i < cols; i++) {
    const a = j * C + i, b = a + 1, c = a + C, d = c + 1;
    idx[q++] = a; idx[q++] = b; idx[q++] = c; idx[q++] = b; idx[q++] = d; idx[q++] = c;   // counter-clockwise seen from above
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  geo.setAttribute('aNd', new THREE.BufferAttribute(nd, 4));
  geo.setAttribute('aLn', new THREE.BufferAttribute(ln, 1));
  geo.setIndex(new THREE.BufferAttribute(idx, 1));
  geo.boundingSphere = new THREE.Sphere(new THREE.Vector3(0, 0, -40), 200);

  const uniforms = {
    ...shared,
    uCam: { value: new THREE.Vector3() },
    uSunDir: { value: new THREE.Vector3(0, 1, 0) }, uMoonDir: { value: new THREE.Vector3(0, 1, 0) },
    uRock: { value: new THREE.Vector3(ROCK.x, 0, ROCK.z) }, uFoot: { value: new THREE.Vector3(.74, .57, .5) }, uScrim: { value: new THREE.Vector4(-1e4, -1e4, -1e4, -1e4) },
    uHeat: { value: 0 }, uShine: { value: 0 }, uSkyTop: { value: .5 }, uHorizon: { value: 0 }, uShock: { value: new THREE.Vector2(0, 0) },
  };
  const mesh = new THREE.Mesh(geo, new THREE.ShaderMaterial({ uniforms, vertexShader, fragmentShader }));
  mesh.frustumCulled = false;
  return { mesh, uniforms };
}
