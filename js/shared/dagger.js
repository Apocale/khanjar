// The Khanjar dagger, the same one as on apocale.github.io/khanjar (its code, unchanged in shape):
// a curved khanjar blade with a ridge, a crescent guard with a red stone, a horn handle.
// makeDagger(THREE) returns { pivot, dagger, tip }: the pivot is centred on the dagger; tip marks the point of the blade.
// studioEnv(THREE, renderer) returns an environment map: a black studio with softboxes, for crisp steel highlights.

export function studioEnv(THREE, renderer) {
  const pmrem = new THREE.PMREMGenerator(renderer);
  const env = new THREE.Scene();
  env.background = new THREE.Color(0x1a1a1d);
  const panel = (w, h, x, y, z, intensity, color = 0xffffff) => {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ color: new THREE.Color(color).multiplyScalar(intensity), side: THREE.DoubleSide }));
    m.position.set(x, y, z); m.lookAt(0, 0, 0); env.add(m);
  };
  panel(16, 3.5, 0, 7, 1, 3.2);          // wide top softbox
  panel(3.5, 12, -8, 0.5, 2, 2.6);       // left tall softbox
  panel(2.2, 10, 8, 0, -1.5, 2.0);       // right edge light
  panel(16, 2, 0, -6, 3, .7);            // floor bounce
  panel(4, 4, -2, 1, -8, 1.4, 0xff5a3a); // warm accent behind
  const gc = document.createElement('canvas'); gc.width = 4; gc.height = 256;
  const g = gc.getContext('2d'), grad = g.createLinearGradient(0, 0, 0, 256);
  grad.addColorStop(0, '#ffffff'); grad.addColorStop(.45, '#8a8f99'); grad.addColorStop(1, '#0a0a0c');
  g.fillStyle = grad; g.fillRect(0, 0, 4, 256);
  const tex = new THREE.CanvasTexture(gc); tex.colorSpace = THREE.SRGBColorSpace;
  const front = new THREE.Mesh(new THREE.PlaneGeometry(44, 26), new THREE.MeshBasicMaterial({ map: tex, color: new THREE.Color(1.6, 1.65, 1.75), side: THREE.DoubleSide }));
  front.position.set(0, 2, 7); front.lookAt(0, 0, 0); env.add(front);
  const t = pmrem.fromScene(env, 0.015).texture;
  pmrem.dispose();
  return t;
}

export function makeDagger(THREE) {
  const steel = new THREE.MeshPhysicalMaterial({ color: 0xdfe3e8, metalness: 1, roughness: .2, clearcoat: 1, clearcoatRoughness: .04, envMapIntensity: 1.3 });
  const darkSteel = new THREE.MeshPhysicalMaterial({ color: 0x8c9097, metalness: 1, roughness: .32, envMapIntensity: 1.1 });
  const horn = new THREE.MeshPhysicalMaterial({ color: 0x111112, metalness: .1, roughness: .38, clearcoat: 1, clearcoatRoughness: .2, sheen: .4, sheenColor: new THREE.Color(0x553322) });
  const gem = new THREE.MeshPhysicalMaterial({ color: 0xff4d2e, metalness: 0, roughness: .08, clearcoat: 1, emissive: 0x5a0f04, emissiveIntensity: .6 });
  const dagger = new THREE.Group();

  // blade: curved khanjar profile, hilt at x=0, tip curving up
  const s = new THREE.Shape();
  s.moveTo(0, -0.19);
  s.bezierCurveTo(1.25, -0.24, 2.45, -0.06, 3.15, 0.82);
  s.bezierCurveTo(2.55, 0.30, 1.45, 0.19, 0, 0.19);
  s.lineTo(0, -0.19);
  const bladeGeo = new THREE.ExtrudeGeometry(s, { depth: 0.02, bevelEnabled: true, bevelThickness: 0.05, bevelSize: 0.045, bevelSegments: 10, curveSegments: 96 });
  bladeGeo.translate(0, 0, -0.01);
  dagger.add(new THREE.Mesh(bladeGeo, steel));

  // central ridge catching the light
  const ridgePts = [];
  for (let i = 0; i <= 24; i++) { const t = i / 24; ridgePts.push(new THREE.Vector3(0.05 + t * 2.75, Math.pow(t, 2.6) * 0.62 - 0.01, 0)); }
  const ridge = new THREE.Mesh(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(ridgePts), 80, 0.014, 8, false), steel);
  ridge.scale.z = 4.2; dagger.add(ridge);

  // crescent guard curving towards the blade, with ball ends, and the red stone
  const GR = 0.6, GT = 0.56, gx = -0.04;
  const guard = new THREE.Mesh(new THREE.TorusGeometry(GR, 0.05, 20, 80, GT * 2), darkSteel);
  guard.rotation.z = Math.PI - GT; guard.position.set(gx + GR, 0, 0); guard.scale.z = .9; dagger.add(guard);
  [-1, 1].forEach(sg => {
    const end = new THREE.Mesh(new THREE.SphereGeometry(0.07, 24, 12), darkSteel);
    end.position.set(gx + GR - GR * Math.cos(GT), sg * GR * Math.sin(GT), 0); dagger.add(end);
  });
  const boss = new THREE.Mesh(new THREE.SphereGeometry(0.115, 32, 16), darkSteel);
  boss.position.set(-0.04, 0, 0); boss.scale.set(.8, 1, .9); dagger.add(boss);
  const stone = new THREE.Mesh(new THREE.SphereGeometry(0.055, 32, 16), gem);
  stone.position.set(-0.04, 0, 0.09); stone.scale.z = .6; dagger.add(stone);

  // handle (lathe around y, then laid along -x)
  const prof = [[0.0, 0], [0.085, 0], [0.095, 0.05], [0.112, 0.3], [0.092, 0.58], [0.104, 0.86], [0.13, 1.02], [0.2, 1.13], [0.17, 1.2], [0.0, 1.22]]
    .map(([r, y]) => new THREE.Vector2(r, y));
  const handle = new THREE.Mesh(new THREE.LatheGeometry(prof, 64), horn);
  handle.rotation.z = Math.PI / 2; handle.position.x = -0.1; dagger.add(handle);
  [0.36, 0.78].forEach(y => {
    const ring = new THREE.Mesh(new THREE.TorusGeometry(0.104, 0.02, 16, 64), darkSteel);
    ring.rotation.y = Math.PI / 2; ring.position.x = -0.1 - y; dagger.add(ring);
  });
  const cap = new THREE.Mesh(new THREE.SphereGeometry(0.1, 32, 16), darkSteel);
  cap.position.x = -1.32; cap.scale.set(.6, 1, 1); dagger.add(cap);

  const tip = new THREE.Object3D(); tip.position.set(3.12, 0.8, 0); dagger.add(tip);
  const pivot = new THREE.Group();
  dagger.position.x = -0.92;      // the dagger is about 4.5 units long; this centres it on the pivot
  pivot.add(dagger);
  return { pivot, dagger, tip, materials: { steel, darkSteel, horn, gem } };
}
