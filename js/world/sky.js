// The sky, one quad behind everything: night with stars, a crescent moon and the odd shooting star on the left,
// Isma Organizer's day on the right (sun, rays, the same clouds as its site), and between them a real dusk:
// a quiet blue-violet high up, the sunset's glow hugging the horizon.
import { NOISE, TOD, SKY } from './glsl.js';

// the three cloud shapes of the Isma Organizer site (its SVG circles, in units of the cloud's width; y goes down)
const CLOUDS = /* glsl */`
float sdRect(vec2 p, vec2 a, vec2 b, float r){
  vec2 c = (a + b) * .5, h = (b - a) * .5 - r, q = abs(p - c) - h;
  return length(max(q, 0.)) + min(max(q.x, q.y), 0.) - r;
}
float cloudSD(vec2 p, float k){
  float d;
  if (k < .5){
    d = length(p - vec2(.283, .317)) - .117;
    d = min(d, length(p - vec2(.425, .23)) - .153);
    d = min(d, length(p - vec2(.593, .25)) - .133);
    d = min(d, length(p - vec2(.733, .32)) - .097);
    d = min(d, length(p - vec2(.167, .353)) - .07);
    d = min(d, length(p - vec2(.842, .357)) - .06);
    d = min(d, sdRect(p, vec2(.133, .327), vec2(.883, .403), .038));
  } else if (k < 1.5){
    d = length(p - vec2(.304, .326)) - .122;
    d = min(d, length(p - vec2(.465, .243)) - .157);
    d = min(d, length(p - vec2(.643, .296)) - .126);
    d = min(d, length(p - vec2(.778, .348)) - .083);
    d = min(d, length(p - vec2(.187, .365)) - .07);
    d = min(d, sdRect(p, vec2(.143, .33), vec2(.861, .413), .041));
  } else {
    d = length(p - vec2(.344, .25)) - .119;
    d = min(d, length(p - vec2(.516, .194)) - .144);
    d = min(d, length(p - vec2(.681, .2625)) - .1);
    d = min(d, sdRect(p, vec2(.1875, .244), vec2(.8125, .338), .047));
  }
  return d;
}
`;

const vertexShader = /* glsl */`
uniform mat4 uInvProj, uCamWorld;
varying vec3 vDir;
void main(){
  vec4 v = uInvProj * vec4(position.xy, 1., 1.);
  vDir = mat3(uCamWorld) * (v.xyz / v.w);
  gl_Position = vec4(position.xy, .99999, 1.);
}`;

const fragmentShader = /* glsl */`
${NOISE}
${TOD}
${SKY}
${CLOUDS}
uniform float uSkyTop, uHorizon, uPx, uShine;
uniform vec3 uSun, uMoon;                 // sun: azimuth, elevation, brightness; moon: azimuth, elevation, angular radius
uniform vec4 uClouds[5];                  // azimuth, elevation, width (radians), shape
uniform vec4 uMeteor;                     // a shooting star: start azimuth, start elevation, heading, progress (0..1)
varying vec3 vDir;

vec3 stars(vec2 sp){
  vec3 acc = vec3(0.);
  for (int l = 0; l < 2; l++){
    float sc = l == 0 ? 95. : 41.;
    vec2 g = sp * sc, id = floor(g) + float(l) * 91.7, f = fract(g);
    float h = hash12(id);
    if (h < (l == 0 ? .58 : .8)) continue;
    vec2 pos = .22 + .56 * hash22(id + 3.1), o = (f - pos) / sc * uPx;     // offset in CSS pixels
    float b = pow(hash12(id + 7.7), l == 0 ? 3. : 1.5);
    float tw = .72 + .28 * sin(uTime * (.8 + 2.6 * h) + h * 40.);
    float r = l == 0 ? .55 + .5 * b : .8 + .7 * b;
    vec3 tint = mix(vec3(.78, .84, 1.), vec3(1., .86, .72), hash12(id + 1.3));
    float core = exp(-dot(o, o) / (r * r));
    float spike = l == 1 ? exp(-abs(o.x) * 1.6) * exp(-abs(o.y) * .5) + exp(-abs(o.y) * 1.6) * exp(-abs(o.x) * .5) : 0.;
    acc += tint * (core * (l == 0 ? .25 + .9 * b : .7 + .5 * b) + spike * b * .22) * tw;
  }
  return acc;
}

void main(){
  vec3 dir = normalize(vDir);
  float el = asin(clamp(dir.y, -1., 1.)), az = atan(dir.x, -dir.z);
  float e = clamp((el - uHorizon) / (uSkyTop - uHorizon), 0., 1.);
  float d = dayAt(gl_FragCoord.xy), s = seamDist(gl_FragCoord.xy);
  vec3 col = airAt(d, s, e, az);
  float night = 1. - smoothstep(.0, .6, d), day = smoothstep(.4, .9, d);
  float lum = dot(col, vec3(.3, .55, .15));

  // stars, going out one by one as the sky brightens
  float sv = night * smoothstep(.02, .2, e) * (1. - smoothstep(.06, .32, lum));
  if (sv > .002) col += stars(vec2(az * cos(el), el)) * sv;

  // a shooting star, now and then: thin and quick
  if (uMeteor.w > 0. && uMeteor.w < 1. && sv > .01){
    vec2 hd = vec2(cos(uMeteor.z), sin(uMeteor.z));
    vec2 pp = vec2((az - uMeteor.x) * cos(el), el - uMeteor.y) - hd * .26 * uMeteor.w;
    float along = -dot(pp, hd), across = abs(dot(pp, vec2(-hd.y, hd.x))) * uPx;
    float trail = smoothstep(.11, 0., along) * smoothstep(-.003, .0, along);
    col += vec3(.86, .9, 1.) * exp(-across * across / .45) * trail * sin(3.1416 * uMeteor.w) * sv * 1.4;
  }

  // the crescent moon: steel, its lit edge turned towards the day
  vec2 mp = vec2((az - uMoon.x) * cos(el), el - uMoon.y);
  float r = uMoon.z, aa = 1.2 / uPx, dm = length(mp);
  float disc = smoothstep(r + aa, r - aa, dm);
  float lit = disc * smoothstep(r * .9 - aa, r * .9 + aa, length(mp + vec2(r * .5, -r * .16)));
  col = mix(col, vec3(.035, .04, .06), disc * night * .9);
  col += (vec3(.86, .89, .95) * lit + vec3(.45, .55, .85) * exp(-max(dm - r, 0.) / (r * 1.4)) * .07) * night;

  // the sun of Isma Organizer: its white core, its halo and its slow rays
  if (day > .002 && uSun.z > .002){
    vec2 sp = vec2((az - uSun.x) * cos(el), el - uSun.y);
    float ds = length(sp);
    float glow = smoothstep(.013, .009, ds) + exp(-ds / .02) * .55 + exp(-ds / .07) * .3 + exp(-ds / .2) * .16;
    float fr = fract((atan(sp.y, sp.x) + uTime * .024) / .2094);
    float ray = smoothstep(0., .04, fr) * smoothstep(.21, .17, fr) * (1. - smoothstep(.0, .3, ds)) * smoothstep(.012, .05, ds);
    col = mix(col, vec3(1.), clamp((glow * (1. + .3 * uShine) + ray * .16) * day * uSun.z, 0., 1.));
    col += vec3(.12, .1, .02) * exp(-ds / .03) * day * uSun.z;
  }

  // the clouds: dark with a cold rim under the moon, gold and pink underneath at dusk, white by day
  for (int i = 0; i < 5; i++){
    vec4 c = uClouds[i];
    if (c.z <= 0.) continue;
    vec2 p = vec2((az - c.x - sin(uTime * .012 + float(i) * 2.) * .012) * cos(el), c.y - el) / c.z + vec2(.5, .27);
    if (p.x < -.06 || p.x > 1.06 || p.y < -.06 || p.y > .52) continue;
    vec2 q = p + .11 * (vec2(fbm(p * 12. + float(i) * 4.1), fbm(p * 12. + 7.3 - float(i))) - .5);
    float sd = cloudSD(q, c.w);
    float soft = max(.0035, 1.4 / (c.z * uPx));
    float a = smoothstep(soft, -soft, sd);
    float top = c.w < 1.5 ? .08 : .05, bottom = c.w < .5 ? .403 : c.w < 1.5 ? .413 : .338;
    float y = clamp((q.y - top) / (bottom - top), 0., 1.);
    if (c.w < 1.5 && d > .5){                                  // by day, the flat blue-grey base under the big ones
      float base = length((q - vec2(.5, bottom - .016)) / vec2(.42, .068)) - 1.;
      col = mix(col, vec3(.83, .89, .96), smoothstep(.04, -.04, base) * (1. - a) * .9 * smoothstep(.5, .85, d));
    }
    if (a < .002) continue;
    float edge = smoothstep(-.04, -.004, sd);
    float moonlit = clamp((cloudSD(q + vec2(-.016, -.02), c.w) - sd) / .026, 0., 1.) * edge;
    float under = clamp((cloudSD(q + vec2(0., .024), c.w) - sd) / .024, 0., 1.) * smoothstep(-.06, -.004, sd);
    vec3 dayC = mix(vec3(1.), vec3(.86, .91, .965), smoothstep(.58, 1., y));
    vec3 duskC = mix(vec3(.36, .31, .45), vec3(1., .64, .46), clamp(smoothstep(.3, 1., y) * .75 + under * .6, 0., 1.));
    vec3 nightC = vec3(.04, .045, .078) + vec3(.48, .56, .8) * moonlit * .5;
    vec3 cc = d < .5 ? mix(nightC, duskC, smoothstep(.12, .5, d)) : mix(duskC, dayC, smoothstep(.5, .85, d));
    col = mix(col, cc, a * mix(.94, 1., d));
  }
  gl_FragColor = vec4(col, 1.);
}`;

export function makeSky(THREE, shared) {
  const uniforms = {
    ...shared,
    uInvProj: { value: new THREE.Matrix4() }, uCamWorld: { value: new THREE.Matrix4() },
    uSkyTop: { value: .5 }, uHorizon: { value: 0 }, uPx: { value: 1000 }, uShine: { value: 0 },
    uSun: { value: new THREE.Vector3(0, 0, 1) }, uMoon: { value: new THREE.Vector3() },
    uClouds: { value: [0, 1, 2, 3, 4].map(() => new THREE.Vector4()) }, uMeteor: { value: new THREE.Vector4(0, 0, 0, -1) },
  };
  const mesh = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), new THREE.ShaderMaterial({ uniforms, vertexShader, fragmentShader, depthWrite: false }));
  mesh.frustumCulled = false;
  mesh.renderOrder = 5;            // after the ground and the rock: the sky only fills what is left
  return { mesh, uniforms };
}
