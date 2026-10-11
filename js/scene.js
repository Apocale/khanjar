// Khanjar's night: the 3D world of the hero and of the last screen (from the Isma Plugins landing page, its left world).
// Stars, a crescent moon, volcanic ridges in a moonlit haze, lava in the cracks, embers, and the Khanjar dagger planted
// in a faceted stone. One WebGL canvas moves between the two sections, and only draws while one of them is on screen.
// The dagger answers the keystroke: ⌘J (or "Try it") draws it out of the stone and drives it back in; the impact runs
// through the lava as a ring of light. Hovering Download wakes the lava. Without WebGL the CSS night stays.
import * as THREE from 'three';
import { makeSky } from './world/sky.js';
import { makeTerrain, lavaSpots, CAM_Z, ROCK } from './world/terrain.js';
import { makeProps, fireEnv, STONE } from './world/props.js';
import { makeEmbers } from './world/particles.js';

const html = document.documentElement;
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const hosts = [...document.querySelectorAll('[data-world]')];
const deg = THREE.MathUtils.degToRad;
const sstep = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
const easeOut = x => 1 - Math.pow(1 - x, 3);
const easeIn = x => x * x * x;

function start() {
  if (!hosts.length) return false;
  const canvas = document.createElement('canvas');
  canvas.className = 'world-gl';
  canvas.setAttribute('aria-hidden', 'true');
  const ctx = canvas.getContext('webgl2', { alpha: false, antialias: true, depth: true, stencil: false, powerPreference: 'high-performance' });
  if (!ctx) return false;
  let renderer;
  try { renderer = new THREE.WebGLRenderer({ canvas, context: ctx, antialias: true }); } catch (e) { return false; }
  renderer.setClearColor(0x0b0b0c, 1);
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  let dead = false;
  const fail = () => { dead = true; html.classList.remove('gl'); canvas.remove(); };
  renderer.debug.onShaderError = fail;

  const scene = new THREE.Scene();
  scene.environment = fireEnv(THREE, renderer);
  const camera = new THREE.PerspectiveCamera(32, 1, .1, 400);
  camera.rotation.order = 'YXZ';

  // the whole sky is night; the day (Isma Organizer's side on the landing page) stays beyond the right edge, close
  // enough to leave a warm dusk on the horizon there
  const shared = {
    uRes: { value: new THREE.Vector2(1, 1) }, uSeam: { value: new THREE.Vector4(1.24, 1.34, .17, .11) },
    uMode: { value: 0 }, uTime: { value: 0 }, uLavaAir: { value: new THREE.Vector3(.2, .5, 1) },
  };
  const phoneAtStart = innerWidth <= 760;
  const sky = makeSky(THREE, shared);
  const ground = makeTerrain(THREE, shared, phoneAtStart ? { cols: 220, rows: 140 } : { cols: 340, rows: 190 });
  const props = makeProps(THREE);
  const embers = makeEmbers(THREE, shared, lavaSpots(phoneAtStart ? 50 : 110));
  scene.add(ground.mesh, sky.mesh, props.group, embers.points);
  ground.uniforms.uFoot.value.set(STONE.foot[0], STONE.foot[1], STONE.yaw);
  ground.uniforms.uMoonDir.value.set(-.55, .62, .4).normalize();
  sky.uniforms.uInvProj.value = camera.projectionMatrixInverse;
  sky.uniforms.uCamWorld.value = camera.matrixWorld;

  // ---- framing ----
  const pitchFor = (vfov, horizonY) => Math.atan((horizonY - .5) * 2 * Math.tan(deg(vfov / 2)));
  const dirAt = (cam, fx, fy) => new THREE.Vector3(fx * 2 - 1, 1 - fy * 2, .5).unproject(cam).sub(cam.position).normalize();
  const azel = v => [Math.atan2(v.x, -v.z), Math.asin(v.y)];
  const aim = (cam, fov, aspect, pos, yaw, pitch) => {
    cam.fov = fov; cam.aspect = aspect; cam.position.copy(pos); cam.rotation.set(pitch, yaw, 0);
    cam.updateProjectionMatrix(); cam.updateMatrixWorld(true); return cam;
  };
  const tmp = new THREE.PerspectiveCamera(32, 1, .1, 400); tmp.rotation.order = 'YXZ';
  const pommel = new THREE.Vector3(), foot = props.top.clone().add(new THREE.Vector3(0, -.55, 0));
  { const box = new THREE.Box3().setFromObject(props.holder); pommel.set(props.top.x, box.max.y + .9, props.top.z); }
  const pv2 = new THREE.Vector3();
  const screenY = (cam, v) => (1 - pv2.copy(v).project(cam).y) / 2;

  let host = null, W = 1, H = 1, dpr = 1, quality = 1, phone = phoneAtStart, fov = 32, basePitch = 0, baseYaw = 0;
  const basePos = new THREE.Vector3();
  let wordsRect = [0, 0, 0, 0];

  function layout() {
    if (!host) return;
    phone = innerWidth <= 760;
    W = host.clientWidth || innerWidth; H = host.clientHeight || innerHeight;
    dpr = Math.min(devicePixelRatio || 1, phone ? 1.5 : 2) * quality;
    renderer.setPixelRatio(dpr); renderer.setSize(W, H, false);
    const buf = renderer.getDrawingBufferSize(new THREE.Vector2());
    shared.uRes.value.copy(buf);
    embers.uniforms.uDpr.value = dpr;
    const aspect = W / H, kind = host.dataset.world;
    const words = host.parentElement.querySelector('[data-words]');
    const hr = host.getBoundingClientRect();
    if (words) { const r = words.getBoundingClientRect(); wordsRect = [r.left - hr.left, r.top - hr.top, r.right - hr.left, r.bottom - hr.top]; }
    let moon, clouds, moonR;
    if (!phone) {
      // the camera of the landing page, turned a little to the right: the summit stands right of the words
      fov = aspect >= 1.55 ? 32 : Math.min(48, 2 * THREE.MathUtils.radToDeg(Math.atan(Math.tan(deg(25.6)) / aspect)));
      baseYaw = kind === 'final' ? -.035 : -.02;
      basePos.set(kind === 'final' ? .8 : 0, kind === 'final' ? 1.75 : 2, kind === 'final' ? CAM_Z - 3 : CAM_Z);
      basePitch = pitchFor(fov, kind === 'final' ? .6 : .63);
      // keep the pommel clear of the top of the section (the nav sits there in the hero)
      for (let i = 0; i < 12; i++) {
        aim(tmp, fov, aspect, basePos, baseYaw, basePitch);
        if (screenY(tmp, pommel) > (kind === 'hero' ? .16 : .1)) break;
        basePitch += deg(.6);
      }
      moon = kind === 'final' ? [.62, .17] : [.54, .15]; moonR = .0155;
      clouds = [[.66, .1, .1, 1], [.9, .3, .09, 2]];
    } else {
      // a camera near the stone: the dagger above the words
      fov = 50;
      basePos.set(props.top.x - 2.2, 2.5, props.top.z + 12.6);
      baseYaw = Math.atan2(-(props.top.x - basePos.x), -(props.top.z - basePos.z)) + .02;
      basePitch = deg(3);
      const blockTop = words ? wordsRect[1] / H : .5, navY = 76 / H;
      // the stone's foot just above the words; if the pommel then goes under the nav, widen the view
      for (let i = 0; i < 24; i++) {
        aim(tmp, fov, aspect, basePos, baseYaw, basePitch);
        const over = screenY(tmp, foot) - (blockTop - .03);
        if (over > .003) { basePitch -= Math.atan(over * 2 * Math.tan(deg(fov / 2))); continue; }
        if (screenY(tmp, pommel) < navY + .02 && fov < 74) { fov += 2; continue; }
        break;
      }
      moon = [.78, .1]; moonR = .028;
      clouds = [[.2, .16, .32, 2], [.86, .3, .28, 1]];
    }
    const cam = aim(tmp, fov, aspect, basePos, baseYaw, basePitch);
    const [maz, mel] = azel(dirAt(cam, moon[0], moon[1]));
    sky.uniforms.uMoon.value.set(maz, mel, moonR);
    const hfov = 2 * Math.atan(Math.tan(deg(fov / 2)) * aspect);
    for (let i = 0; i < 5; i++) {
      const c = clouds[i];
      if (!c) { sky.uniforms.uClouds.value[i].set(0, 0, 0, 0); continue; }
      const [az, el] = azel(dirAt(cam, c[0], c[1]));
      sky.uniforms.uClouds.value[i].set(az, el, c[2] * hfov, c[3]);
    }
    const lv = new THREE.Vector3(ROCK.x - 2, 0, ROCK.z).sub(cam.position).normalize();
    shared.uLavaAir.value.set(Math.atan2(lv.x, -lv.z), phone ? .35 : .55, 1);
    sky.uniforms.uSkyTop.value = ground.uniforms.uSkyTop.value = basePitch + deg(fov / 2);
    sky.uniforms.uHorizon.value = ground.uniforms.uHorizon.value = deg(phone ? 2 : 1.2);
    sky.uniforms.uPx.value = (H / 2) / Math.tan(deg(fov / 2));
    draw(0);
  }

  // ---- the strike: the blade comes out of the stone and goes back in ----
  const strike = { t: -1, from: 0, peak: .62, onImpact: null, hit: false };
  const shock = { t: -1 };
  let lift = 0, tilt = 0, burst = 0, shake = 0;
  const heat = { x: reduce ? .15 : -.55, goal: .15 };
  function doStrike(fromAbove) {
    if (dead) return Promise.resolve();
    if (reduce) { wake(); return Promise.resolve(); }
    return new Promise(res => {
      strike.t = 0; strike.from = lift; strike.hit = false; strike.onImpact = res;
      strike.peak = fromAbove ? fromAbove : .62;
      strike.skipRise = !!fromAbove;
      wake();
    });
  }
  function stepStrike(dt) {
    if (strike.t < 0) return;
    strike.t += dt;
    const RISE = strike.skipRise ? 0 : .2, DROP = .085, SETTLE = .32;
    const s = strike.t;
    if (s < RISE) { const k = easeOut(s / RISE); lift = strike.from + (strike.peak - strike.from) * k; tilt = -.05 * k; }
    else if (s < RISE + DROP) { const k = easeIn((s - RISE) / DROP); lift = strike.peak + (-.13 - strike.peak) * k; tilt = -.05 * (1 - k); }
    else {
      if (!strike.hit) {
        strike.hit = true; shock.t = 0; burst = 1.25; shake = 1;
        if (strike.onImpact) { strike.onImpact(); strike.onImpact = null; }
        document.dispatchEvent(new CustomEvent('khanjar:impact'));
      }
      const k = Math.min(1, (s - RISE - DROP) / SETTLE);
      lift = -.13 * (1 - easeOut(k)); tilt = .012 * Math.sin(k * 9) * (1 - k);
      if (k >= 1) { strike.t = -1; lift = 0; tilt = 0; }
    }
  }

  // ---- one frame ----
  const ptr = { x: .5, y: .5, in: false }, par = { x: 0, y: 0 };
  const sv = new THREE.Vector3();
  let t = 0, hostTop = 0;
  const meteor = { t: -1, next: 6 + Math.random() * 6, dur: .85 };
  function update(dt) {
    t += dt; shared.uTime.value = t;
    stepStrike(dt);
    heat.x += (heat.goal - heat.x) * (1 - Math.exp(-dt * (heat.x < 0 ? 1.4 : 4)));
    burst *= Math.exp(-dt * 2.2); shake *= Math.exp(-dt * 9);
    const h = Math.max(-.6, heat.x) + burst;
    ground.uniforms.uHeat.value = embers.uniforms.uHeat.value = Math.max(0, h);
    props.place(lift + Math.max(0, heat.x - .15) * .25, tilt);
    const hl = Math.max(0, 1 + h * .9);
    props.lava.intensity = props.base.lava * hl; props.lava2.intensity = props.base.lava2 * hl;
    props.slot.material.color.setRGB(2.2, .78, .3).multiplyScalar(Math.max(.2, 1 + h * .8));
    props.seep.value = (.75 + .25 * Math.sin(t * 1.15)) * Math.max(.15, 1 + h);
    if (shock.t >= 0) {
      shock.t += dt;
      const k = shock.t / 1.25;
      ground.uniforms.uShock.value.set(.7 + k * 11, Math.max(0, 1 - k) * 1.6);
      if (k >= 1) { shock.t = -1; ground.uniforms.uShock.value.set(0, 0); }
    }
    // the camera: a few centimetres of parallax with the mouse, a jolt on impact
    const gx = ptr.in && !reduce && !phone ? (ptr.x - .5) * 2 : 0, gy = ptr.in && !reduce && !phone ? (ptr.y - .5) * 2 : 0;
    par.x += (gx - par.x) * (1 - Math.exp(-dt * 2.5)); par.y += (gy - par.y) * (1 - Math.exp(-dt * 2.5));
    const j = shake * .045;
    aim(camera, fov, W / H, sv.set(basePos.x + par.x * .3 + Math.sin(t * 61) * j, basePos.y - par.y * .07 + Math.cos(t * 53) * j, basePos.z),
      baseYaw - par.x * .016, basePitch - par.y * .01);
    // the words keep the lava calm behind them (device px, origin bottom-left)
    const top = wordsRect[1], bot = wordsRect[3];
    ground.uniforms.uScrim.value.set(wordsRect[0] * dpr, (H - bot) * dpr, wordsRect[2] * dpr, (H - top) * dpr);
    ground.uniforms.uCam.value.copy(camera.position);
    // a shooting star now and then
    if (!reduce) {
      if (meteor.t < 0 && t > meteor.next) {
        const fx = .08 + Math.random() * .84, fy = .05 + Math.random() * .2;
        const [az, el] = azel(dirAt(camera, fx, fy)), right = Math.random() < .6;
        sky.uniforms.uMeteor.value.set(az, el, right ? -(.35 + Math.random() * .45) : Math.PI + .35 + Math.random() * .45, 0);
        meteor.t = 0;
      }
      if (meteor.t >= 0) {
        meteor.t += dt; sky.uniforms.uMeteor.value.w = meteor.t / meteor.dur;
        if (meteor.t >= meteor.dur) { meteor.t = -1; meteor.next = t + 10 + Math.random() * 10; sky.uniforms.uMeteor.value.w = -1; }
      }
    }
  }
  function draw(dt) { update(dt); renderer.render(scene, camera); }

  // ---- the loop: only while one of the two sections is seen ----
  let raf = 0, last = 0, slow = 0;
  const visible = new Map();
  let finalStruck = false;
  const loop = now => {
    raf = 0;
    if (dead || document.hidden || !host) return;
    const dt = Math.min((now - last) / 1000, 1 / 20); last = now;
    if (dt > .028) { if (++slow > 45 && quality > .55) { quality -= .2; slow = 0; layout(); } } else slow = Math.max(0, slow - 2);
    draw(dt);
    if (!reduce || strike.t >= 0) raf = requestAnimationFrame(loop);
  };
  function wake() {
    if (dead || !host) return;
    if (reduce && strike.t < 0) { requestAnimationFrame(() => draw(0)); return; }
    if (!raf && !document.hidden) { last = performance.now(); raf = requestAnimationFrame(loop); }
  }
  function pickHost() {
    const next = hosts.find(h => visible.get(h)) || null;
    if (next === host) { if (host) wake(); return; }
    host = next;
    if (!host) return;
    host.appendChild(canvas);
    layout(); wake();

  }
  const io = new IntersectionObserver(es => { es.forEach(e => visible.set(e.target, e.isIntersecting)); pickHost(); }, { rootMargin: '80px 0px' });
  hosts.forEach(h => io.observe(h));
  // reaching the last screen ("Press ⌘J. Keep cutting."), the dagger strikes once
  const fin = hosts.find(h => h.dataset.world === 'final');
  if (fin && !reduce) new IntersectionObserver(es => {
    if (es[0].isIntersecting && !finalStruck && host === fin) { finalStruck = true; setTimeout(() => doStrike(0), 350); }
  }, { threshold: .6 }).observe(fin);
  document.addEventListener('visibilitychange', wake);
  let rt = 0;
  addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(layout, 80); });
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => layout());
  addEventListener('pointermove', e => { if (e.pointerType === 'touch') return; ptr.x = e.clientX / innerWidth; ptr.y = e.clientY / innerHeight; ptr.in = true; wake(); }, { passive: true });
  html.addEventListener('mouseleave', () => { ptr.in = false; });
  canvas.addEventListener('webglcontextlost', e => { e.preventDefault(); fail(); });
  // reaching for Download wakes the lava
  document.querySelectorAll('[data-heat]').forEach(a => {
    const on = () => { heat.goal = 1; wake(); }, off = () => { heat.goal = .15; wake(); };
    a.addEventListener('pointerenter', on); a.addEventListener('pointerleave', off);
    a.addEventListener('focus', on); a.addEventListener('blur', off);
  });

  window.KhanjarWorld = { strike: () => doStrike(0), ready: true };
  html.classList.add('gl');
  // the opening: the blade waits above the stone, the lava is dark, then the strike lights it
  if (!reduce) { lift = 1.25; setTimeout(() => doStrike(1.25), 520); }
  return true;
}

if (!start()) html.classList.add('no-gl');
