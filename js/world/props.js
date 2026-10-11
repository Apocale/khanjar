// The dagger planted in a cut stone on the summit, like a sword in the stone, its steel lit from below by the
// lava and touched by the moon; the lava seeps out at the stone's foot. (From the Isma Plugins landing page.)
import { ConvexGeometry } from 'three/addons/geometries/ConvexGeometry.js';
import { makeDagger } from '../shared/dagger.js';
import { ROCK, PLATEAU } from './terrain.js';

// what the steel reflects: the night above, the lava's glow rising to the horizon all around, the moon, and thin strips
// of cold light that draw the edges. The flat of the blade looks at the horizon on the left: lava at its foot, the moon higher.
export function fireEnv(THREE, renderer) {
  const pmrem = new THREE.PMREMGenerator(renderer);
  const env = new THREE.Scene();
  env.add(new THREE.Mesh(new THREE.SphereGeometry(30, 48, 24), new THREE.ShaderMaterial({
    side: THREE.BackSide, depthWrite: false,
    vertexShader: 'varying vec3 vP; void main(){ vP = normalize(position); gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.); }',
    fragmentShader: `varying vec3 vP; void main(){
      float y = vP.y;
      vec3 fire = vec3(2.3, .52, .14);
      vec3 c = mix(fire * 1.1, fire * .5, smoothstep(-.9, -.05, y));                 // the lava, all around below
      c = mix(c, vec3(.03, .034, .055), smoothstep(-.03, .13, y));                     // its glow ends just over the horizon
      c += vec3(.05, .06, .1) * smoothstep(.05, .6, y) * smoothstep(.3, -.9, vP.x);   // the moonlit night on the left
      c += vec3(.02, .025, .05) * smoothstep(.4, 1., y);
      float w = smoothstep(.55, .9, -vP.x);                                            // where the flat of the blade looks
      vec3 band = mix(vec3(2.1, .5, .13), vec3(.2, .04, .02), smoothstep(.0, .07, y));
      band = mix(band, vec3(.03, .036, .065), smoothstep(.06, .1, y));
      band += vec3(.06, .07, .12) * smoothstep(.1, .3, y);
      band += vec3(1.2, 1.3, 1.5) * smoothstep(.115, .128, y) * smoothstep(.155, .142, y);
      c = mix(c, band, w * smoothstep(-.1, .02, y) * (1. - smoothstep(.34, .42, y)));
      gl_FragColor = vec4(c, 1.); }`,
  })));
  const panel = (w, h, x, y, z, k, color) => {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ color: new THREE.Color(color).multiplyScalar(k), side: THREE.DoubleSide }));
    m.position.set(x, y, z); m.lookAt(0, 0, 0); env.add(m);
  };
  panel(16, .32, 0, 9, 2, 7, 0xe2e8ff);        // a thin cold line overhead
  panel(.32, 14, 9, 2, 6, 6, 0xe2e8ff);        // and one on the right, in front: the edges and the ridge
  panel(.3, 12, -7, 3, -8, 4, 0xb4c2ec);       // behind on the left: a rim on the back edge
  panel(4, 1.4, -3, -1.2, 9, 2.4, 0xff6a30);   // embers low in front
  const moon = new THREE.Mesh(new THREE.CircleGeometry(1.15, 40), new THREE.MeshBasicMaterial({ color: new THREE.Color(0xe8ecf6).multiplyScalar(3.4), side: THREE.DoubleSide }));
  moon.position.set(-23.5, 5.2, 6.2); moon.lookAt(0, 0, 0); env.add(moon);   // the moon, high on the flat of the blade
  const tex = pmrem.fromScene(env, .015).texture;
  pmrem.dispose();
  return tex;
}

// a seeded random, so the stone is the same on every visit
function rand(seed) { let s = seed >>> 0; return () => (s = (s * 1664525 + 1013904223) >>> 0) / 4294967296; }

export const STONE = { yaw: -.55, foot: [.74, .57] };   // turned like the blade: its long side takes the blade's curve   // its turn, and the half sizes of its foot where it meets the summit

export function makeProps(THREE) {
  const group = new THREE.Group();

  // the stone: a cut block, tapered, its corners chamfered, every edge sharp (the hull of a few jittered rings)
  const r = rand(11), pts = [];
  for (const [y, hx, hz] of [[-.66, 1, .78], [-.18, .96, .74], [.24, .8, .62], [.5, .56, .44]]) {
    for (let i = 0; i < 8; i++) {
      const a = i / 8 * Math.PI * 2 + (r() - .5) * .3, cx = Math.cos(a), cz = Math.sin(a);
      const k = 1 / Math.max(Math.abs(cx), Math.abs(cz)) * (i % 2 ? .86 : 1) * (.9 + .1 * r());
      pts.push(new THREE.Vector3(cx * k * hx, y + (r() - .5) * .07 + (y > .4 ? cx * .05 : 0), cz * k * hz));
    }
  }
  const S = .76;
  const seep = { value: 1 };
  const stoneMat = new THREE.MeshStandardMaterial({ color: 0x24252c, roughness: .4, metalness: .3, flatShading: true, envMapIntensity: .8 });
  const baseY = PLATEAU + .66 * S - .07;                         // its foot a little sunk in the plateau
  stoneMat.onBeforeCompile = sh => {             // the lava light seeping at its foot
    sh.uniforms.uSeep = seep;
    sh.vertexShader = sh.vertexShader.replace('#include <common>', '#include <common>\nvarying float vLy;')
      .replace('#include <begin_vertex>', '#include <begin_vertex>\nvLy = position.y;');
    sh.fragmentShader = sh.fragmentShader.replace('#include <common>', '#include <common>\nvarying float vLy;\nuniform float uSeep;')
      .replace('#include <emissivemap_fragment>', '#include <emissivemap_fragment>\ntotalEmissiveRadiance += vec3(1., .3, .07) * uSeep * smoothstep(-.56, -.64, vLy) * 1.6;');
  };
  const stone = new THREE.Mesh(new ConvexGeometry(pts), stoneMat);
  stone.scale.setScalar(S);
  stone.rotation.y = STONE.yaw;
  stone.position.set(ROCK.x, baseY, ROCK.z);
  group.add(stone);
  const top = new THREE.Vector3(ROCK.x, baseY + .5 * S, ROCK.z);

  // the slot where the blade enters, still hot
  const slot = new THREE.Mesh(new THREE.BoxGeometry(.4, .03, .11), new THREE.MeshBasicMaterial({ color: new THREE.Color(0xff5a2a).multiplyScalar(2.2) }));
  slot.position.copy(top).add(new THREE.Vector3(0, .004, 0)); slot.rotation.y = -.55;
  group.add(slot);

  // the dagger, tip down in the stone, the handle up, leaning a little; its flat turned to catch the fire
  const { pivot, dagger, materials } = makeDagger(THREE);
  materials.steel.envMapIntensity = 1.5; materials.steel.roughness = .1;
  const entry = new THREE.Object3D(); entry.position.set(2.55, .34, 0); dagger.add(entry);   // where the blade meets the stone (the tip stays inside)
  const holder = new THREE.Group();
  holder.add(pivot);
  pivot.rotation.set(0, 0, -Math.PI / 2 + .13);
  holder.rotation.y = -.55;
  holder.scale.setScalar(1.12);
  group.add(holder);
  const place = (lift, tilt = 0) => {             // lift: how far the blade is drawn out of the stone; tilt: its lean while it strikes
    holder.rotation.set(0, -.55, tilt);
    holder.position.set(0, 0, 0); holder.updateMatrixWorld(true);
    const at = entry.getWorldPosition(new THREE.Vector3());
    holder.position.copy(top).sub(at).add(new THREE.Vector3(0, -.08 + lift, 0));
  };
  place(0);

  // the light: the lava under the summit, a little fire on the other side, the moon behind, a cold fill
  const lava = new THREE.PointLight(0xff5a24, 3.2, 12, 1.8); lava.position.copy(top).add(new THREE.Vector3(.8, -1.35, 2.4));
  const lava2 = new THREE.PointLight(0xff3a12, 2, 8, 1.8); lava2.position.copy(top).add(new THREE.Vector3(-1.5, -.9, .6));
  const moon = new THREE.DirectionalLight(0xb7c4ff, 2.3); moon.position.set(ROCK.x - 7, 12, ROCK.z - 8); moon.target.position.copy(top);
  const fill = new THREE.DirectionalLight(0xdfe6ff, .22); fill.position.set(ROCK.x + 3, top.y + 3, ROCK.z + 12); fill.target.position.copy(top);
  group.add(lava, lava2, moon, moon.target, fill, fill.target);

  return { group, holder, place, top, lava, lava2, slot, stone, seep, base: { lava: lava.intensity, lava2: lava2.intensity } };
}
