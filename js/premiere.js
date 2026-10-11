/* Premiere Pro 2026 in the browser, with the Khanjar palette on top: KPR.make(root, options) builds one screen.
   The Premiere screen comes from the Isma Organizer site (the one Isma approved), checked against his own 2026
   screenshots; the palette, its search (a port of Khanjar's Scorer.swift, "command-score") and the HUD copy the app.
   What lands on the clips is drawn from the playhead: a preset's keyframes are read at the current frame, so an
   animated preset only moves when the timeline plays, as in Premiere. A bare effect is applied with Premiere's
   default values (Gaussian Blur at 0 blurs nothing until you set it). Footage: free Pexels clips. */
(function () {
  'use strict';
  var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  var FPS = 25, SEQ = 12, VIEW = 12.6, FOOT = 'assets/footage/';
  // Premiere 2026's label colours, from Isma's preferences
  var LAB = { violet: '#3e0aae', iris: '#004b67', caribbean: '#2a5507', lavender: '#751187', forest: '#3d4a00', mango: '#893a04' };
  var WAVE = { iris: '#9bd3fb', caribbean: '#a9cf84', violet: '#b9a6f2' };
  var esc = function (s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); };
  var clamp = function (x, a, b) { return x < a ? a : x > b ? b : x; };
  var easeOut = function (x) { return 1 - Math.pow(1 - x, 3); };
  var easeInOut = function (x) { return x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function tc(s) { var f = Math.round(s * FPS); return '00:00:' + pad(Math.floor(f / FPS)) + ':' + pad(f % FPS); }
  function rnd(x) { x = Math.sin(x * 12.9898) * 43758.5453; return x - Math.floor(x); }
  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  // ---- icons, redrawn from Premiere 2026's own set (Resources/svg) and SF Symbols for the palette ----
  var I = {
    home: '<path d="M8 1.7l6.6 5.6-.95 1.12-.95-.8V14H9.6v-3.8H6.4V14H3.3V7.62l-.95.8-.95-1.12z"/>',
    ws: '<path d="M2 2.5h12v11H2zm1.3 1.3v8.4h3.6V3.8zm4.9 0v3.6h4.5V3.8zm0 4.9v3.5h4.5V8.7z" fill-rule="evenodd"/>',
    share: '<path d="M8 1.5l3.3 3.3-.95.95L8.7 4.1v6.4H7.3V4.1L5.65 5.75l-.95-.95zM3 8h1.4v4.6h7.2V8H13v6H3z"/>',
    full: '<path d="M2 2h4.4v1.5H3.5v2.9H2zm7.6 0H14v4.4h-1.5V3.5H9.6zM2 9.6h1.5v2.9h2.9V14H2zm10.5 0H14V14H9.6v-1.5h2.9z"/>',
    wrench: '<path d="M10.8 1.6a3.5 3.5 0 0 0-3.3 4.7L1.9 11.9a1.35 1.35 0 0 0 1.9 1.9l5.6-5.6a3.5 3.5 0 0 0 4.7-3.3l-.06-.7-2.06 2.06-1.86-.5-.5-1.86 2.06-2.06z"/>',
    setIn: '<path d="M9.6 2.5h1.6v11H9.6zm0 3.1L5.2 8l4.4 2.4z"/>',
    setOut: '<path d="M4.8 2.5h1.6v11H4.8zm1.6 3.1L10.8 8l-4.4 2.4z"/>',
    goIn: '<path d="M2.6 3h1.6v10H2.6zm10.8 4.25H8.2V5L4.9 8l3.3 3V8.75h5.2z"/>',
    stepB: '<path d="M10.6 3.2L4.4 8l6.2 4.8zm1 0h1.6v9.6h-1.6z"/>',
    play: '<path d="M4.6 2.6v10.8L13.2 8z"/>',
    pause: '<path d="M4.2 3h2.6v10H4.2zm5 0h2.6v10H9.2z"/>',
    stepF: '<path d="M5.4 3.2L11.6 8l-6.2 4.8zM2.8 3.2h1.6v9.6H2.8z"/>',
    goOut: '<path d="M11.8 3h1.6v10h-1.6zM2.6 7.25h5.2V5L11.1 8l-3.3 3V8.75H2.6z"/>',
    camera: '<path d="M1.8 4.8h2.7l1.2-1.6h4.6l1.2 1.6h2.7v8H1.8zM8 6.3a2.6 2.6 0 1 0 0 5.2 2.6 2.6 0 0 0 0-5.2z" fill-rule="evenodd"/>',
    nest: '<path d="M7.25 1.5h1.5v13h-1.5zM2 3.5h4.3v2H2zm7.7 0H14v2H9.7zM3.4 10.5h2.9v2H3.4zm6.3 0h2.9v2H9.7z"/>',
    snap: '<path d="M2.6 13.4V8a5.4 5.4 0 0 1 10.8 0v5.4h-3.2V8a2.2 2.2 0 0 0-4.4 0v5.4z"/>',
    linked: '<path d="M1.6 2.4h7.2v2.1H3.7v6.1H1.6zm5 3.2l7.3 3-3.1 1 2.4 2.9-1.4 1.2-2.4-2.9-1.7 2.9z"/>',
    marker: '<path d="M4.4 2.4h7.2v7L8 13l-3.6-3.6z"/>',
    lock: '<path d="M4.2 7.4h7.6v6.2H4.2z"/><path d="M5.7 7.4V5.3a2.3 2.3 0 0 1 4.4-1" fill="none" stroke="currentColor" stroke-width="1.4"/>',
    sync: '<path d="M2.2 3.4h7v3.2h-7zm4.6 6h7v3.2h-7z" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M7.4 6.6v2.8" stroke="currentColor" stroke-width="1.2"/>',
    eye: '<path d="M8 3.8C4.6 3.8 2.3 6.5 1.5 8c.8 1.5 3.1 4.2 6.5 4.2s5.7-2.7 6.5-4.2C13.7 6.5 11.4 3.8 8 3.8zm0 2.1a2.1 2.1 0 1 1 0 4.2 2.1 2.1 0 0 1 0-4.2z" fill-rule="evenodd"/>',
    mic: '<rect x="5.9" y="1.6" width="4.2" height="7.6" rx="2.1"/><path d="M3.8 7.4a4.2 4.2 0 0 0 8.4 0M8 11.6v2.6M5.5 14.2h5" fill="none" stroke="currentColor" stroke-width="1.3"/>',
    bow: '<path d="M2 3.5l5 4.5-5 4.5zm12 0L9 8l5 4.5z"/>',
    sel: '<path d="M4 1.8l8.6 7.3-3.9.35 2.3 4.4-1.6.85-2.3-4.4L4 13.2z"/>',
    tsel: '<path d="M1.8 3.5h1.5m1.3 0h1.5m-4.3 9h1.5m1.3 0h1.5M1.8 3.5V5m0 1.3v1.5m0 1.3v1.5" stroke="currentColor" stroke-width="1.3" fill="none"/><path d="M6.5 8h6.2m-2.3-2.6L13 8l-2.6 2.6" fill="none" stroke="currentColor" stroke-width="1.5"/>',
    ripple: '<path d="M7.25 1.8h1.5v12.4h-1.5zM1.4 8l3.6-3.2v6.4zm13.2 0L11 4.8v6.4z"/>',
    razor: '<path d="M3.1 14l1.3-5.6 7-6.6 2.8 2.8-6.6 7z"/><circle cx="9.9" cy="6.1" r="1.1" fill="#1d1d1d"/>',
    slip: '<path d="M1.8 4h1.5v8H1.8zm10.9 0h1.5v8h-1.5zM4.8 8l2.6-2.4v4.8zm6.4 0L8.6 5.6v4.8z"/>',
    pen: '<path d="M8 1.6l3.6 5.6-1.4 6.2H5.8L4.4 7.2zm0 3.2a1.2 1.2 0 1 0 0 2.4 1.2 1.2 0 0 0 0-2.4z" fill-rule="evenodd"/>',
    rect: '<rect x="2.5" y="3.5" width="11" height="9" rx=".8" fill="none" stroke="currentColor" stroke-width="1.4"/>',
    hand: '<path d="M5 14.2c-1-1.1-2.6-3.6-3-4.4-.4-.8.4-1.6 1.2-1.1l1.5 1.2V3.6a.9.9 0 0 1 1.8 0V7h.3V2.4a.9.9 0 0 1 1.8 0V7h.3V3a.9.9 0 0 1 1.8 0v4.2h.3V4.6a.9.9 0 0 1 1.8 0v5.2c0 2-.9 3.4-1.6 4.4z"/>',
    type: '<path d="M2.6 2.6h10.8v3h-1.5V4.1H8.75v8.3h1.6v1.5h-4.7v-1.5h1.6V4.1H4.1v1.5H2.6z"/>',
    mag: '<circle cx="6.6" cy="6.6" r="4.6" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M10.2 10.2l4.3 4.3" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
    sbin: '<path d="M1.5 4h5l1.5 1.5h6.5v8.5H1.5z" fill="currentColor"/><circle cx="9.2" cy="9.2" r="2.1" fill="none" stroke="#1d1d1d" stroke-width="1.2"/><path d="M10.7 10.7l1.7 1.7" stroke="#1d1d1d" stroke-width="1.3" stroke-linecap="round"/>',
    folder: '<path d="M1.5 3.5h4.6l1.4 1.5h7v8.5h-13z"/>',
    fxfilm: '<path d="M2 3.5h12v9H2zm1.3 1.2v1.3h1.3V4.7zm0 2.6v1.3h1.3V7.3zm0 2.6v1.3h1.3V9.9zm8.1-5.2v1.3h1.3V4.7zm0 2.6v1.3h1.3V7.3zm0 2.6v1.3h1.3V9.9z" fill-rule="evenodd"/>',
    preset: '<path d="M1.5 5.5h10v8h-10zm1.2 1.1v1.2h1.1V6.6zm0 2.3v1.2h1.1V8.9zm0 2.3v1.2h1.1v-1.2zm6.6-4.6v1.2h1.1V6.6zm0 2.3v1.2h1.1V8.9zm0 2.3v1.2h1.1v-1.2z" fill-rule="evenodd"/><path d="M12.4 1.2l.9 1.9 2 .3-1.5 1.4.4 2-1.8-1-1.8 1 .4-2-1.5-1.4 2-.3z"/>',
    acc: '<path d="M1.5 3h13v10h-13z" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M3.6 6h3.2M3.6 8h2.4M3.6 10h3.2" stroke="currentColor" stroke-width="1.1"/><path d="M8.6 5.4L13 8l-4.4 2.6z"/>',
    b32: '<path d="M1.5 3h13v10h-13z" fill="none" stroke="currentColor" stroke-width="1.2"/><text x="8" y="11" text-anchor="middle" font-size="6.6" font-weight="700" font-family="Source Sans 3,Arial,sans-serif" fill="currentColor">32</text>',
    yuv: '<path d="M1.5 3h13v10h-13z" fill="none" stroke="currentColor" stroke-width="1.2"/><text x="8" y="10.4" text-anchor="middle" font-size="5" font-weight="700" font-family="Source Sans 3,Arial,sans-serif" fill="currentColor">YUV</text>',
    newbin: '<path d="M1.5 3.5h4.6l1.4 1.5h7v8.5h-13z"/>',
    trash: '<path d="M5.8 2h4.4v1.3h3.3v1.4h-11V3.3h3.3z"/><path d="M3.6 6h8.8l-.7 8.2H4.3z"/>',
    sortup: '<path d="M5 9V1.6M1.8 4.6L5 1.4l3.2 3.2" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" transform="scale(1.6)"/>',
    tw: '<path d="M5.4 3L10.6 8l-5.2 5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>'
  };
  function svg(n, cls, vb) { return '<svg class="i' + (cls ? ' ' + cls : '') + '" viewBox="' + (vb || '0 0 16 16') + '" aria-hidden="true">' + I[n] + '</svg>'; }
  // the fx badge of a clip (an italic serif f and x, as in the timeline)
  var FX = '<svg class="fx" viewBox="0 0 13 10" aria-hidden="true"><path d="M2.1 9.6L4 2.6C4.4 1.2 5.2.6 6.6.7" fill="none" stroke="currentColor" stroke-width="1.05" stroke-linecap="round"/><path d="M2.4 3.6h3" stroke="currentColor" stroke-width="1"/><path d="M6.3 3.7l4.2 5.8M10.7 3.7L6 9.5" stroke="currentColor" stroke-width="1.05" stroke-linecap="round"/></svg>';
  var HAM = '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M1 2.5h10M1 6h10M1 9.5h10" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>';
  var CUR = '<svg class="kcur" viewBox="0 0 12 19" aria-hidden="true"><path d="M1 1v15.6l3.7-3.6 2.6 5.7 2.5-1.1-2.6-5.6h5.1z" fill="#fff" stroke="#000" stroke-width="1" stroke-linejoin="round"/></svg>';
  // palette glyphs (SF Symbols: magnifyingglass, square.stack.3d.down.right, link), redrawn
  var KMAG = '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="6.8" cy="6.8" r="5" fill="none" stroke="currentColor" stroke-width="1.7"/><path d="M10.6 10.6l3.9 3.9" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/></svg>';
  var KSTACK = '<svg viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.15" stroke-linejoin="round"><path d="M3.2 3.4l2.6-1.5v8.4l-2.6 1.6z"/><path d="M6.4 4.6L9 3.1v8.4l-2.6 1.6z"/><path d="M9.6 5.8l3.4-2v8.6l-3.4 2.1z" fill="currentColor" fill-opacity=".18"/></svg>';
  var KLINK = '<svg viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M6.9 9.1a2.6 2.6 0 0 0 3.7 0l2.4-2.4a2.6 2.6 0 0 0-3.7-3.7l-.9.9"/><path d="M9.1 6.9a2.6 2.6 0 0 0-3.7 0L3 9.3A2.6 2.6 0 0 0 6.7 13l.9-.9"/></svg>';
  var KCHECK = '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="7.5" fill="#30d158"/><path d="M4.6 8.3l2.2 2.2 4.6-4.8" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  var KWARN = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.2l7.2 13.1H.8z" fill="#ffd60a"/><path d="M8 5.8v4.2" stroke="#1d1d1d" stroke-width="1.7" stroke-linecap="round"/><circle cx="8" cy="12.2" r="1" fill="#1d1d1d"/></svg>';

  // ---- Khanjar's index: the example presets of its own README screenshots, and Premiere 2026's video effects ----
  // (effect names from Premiere's plugin list, Resources/txt/KnownPluginCache.txt; looks: what lands on the monitor)
  var ME = 'Preset · My Presets', TR = 'Preset · Transitions', VE = 'Video effect';
  var PRESETS = [
    { id: 'glowsh', title: 'Glow + Shadow', detail: ME, look: ['glowsh'], fx: 2, kw: ['glow', 'shadow'] },
    { id: 'slideup', title: 'Slide Up Text', detail: ME, look: ['slideup'], fx: 1, anim: 'in' },
    { id: 'grain', title: 'Film Grain', detail: ME, look: ['grain'], fx: 2 },
    { id: 'zoom120', title: 'Zoom In 120%', detail: TR, look: ['zoom120'], fx: 1, anim: 'all' },
    { id: 'cinevig', title: 'Cinematic Vignette', detail: 'Preset · Color', look: ['vignette'], fx: 1 },
    { id: 'tds', title: 'True Drop Shadow', detail: ME, look: ['tds'], fx: 1 },
    { id: 'glitch', title: 'Glitch Reveal', detail: TR, look: ['glitch'], fx: 2, partial: true, anim: 'in' },
    { id: 'glowpulse', title: 'Glow Pulse', detail: ME, look: ['glowpulse'], fx: 1, anim: 'all' },
    { id: 'fbi', title: 'Fast Blur In', detail: 'Adobe preset · Blurs', look: ['blurin'], fx: 1, anim: 'in' },
    { id: 'gbfi', title: 'Gaussian Blur Fade In', detail: TR, look: ['gbfadein'], fx: 1, anim: 'in' },
    { id: 'gbfo', title: 'Gaussian Blur Fade Out', detail: TR, look: ['gbfadeout'], fx: 1, anim: 'out' }
  ];
  var EFFECTS = ['Camera Blur', 'Gaussian Blur', 'Directional Blur', 'Drop Shadow', 'Black & White', 'Tint', 'Invert', 'Horizontal Flip', 'Vertical Flip',
    'Lumetri Color', 'Brightness & Contrast', 'Vignette', 'ASC CDL', 'Color Space Transform', 'Video Limiter', 'Lighting Effects', 'ProcAmp',
    'Sharpen', 'Unsharp Mask', 'Reduce Interlace Flicker', 'Corner Pin', 'Magnify', 'Mirror', 'Rolling Shutter Repair', 'Spherize',
    'Twirl', 'Warp Stabilizer', 'Wave Warp', 'Lens Flare', 'Lightning', 'Ramp', '4-Color Gradient', 'Gradient', 'Chaos', 'Earthquake', 'Flicker', 'Glass',
    'Glitch', 'Grunge', 'Kaleidoscope', 'Liquid Distortion', 'TV Power', 'VHS Damage', 'Channel Mix', 'Rounded Crop', 'Alpha Adjust', 'Color Key',
    'Luma Key', 'Track Matte Key', 'Ultra Key', 'Echo Glow', 'Edge Glow', 'Glint', 'Light Leaks', 'RGB Split', 'Volumetric Rays', 'Wonder Glow',
    'Noise', 'Basic 3D', 'Long Shadow', 'Alpha Glow', 'Brush Strokes', 'Color Emboss', 'Find Edges', 'Mosaic', 'Posterize', 'Replicate',
    'Roughen Edges', 'Strobe Light', 'Text Animator', 'Typewriter', 'Echo', 'Posterize Time', 'Timewarp', '3D Rotate',
    'Auto Reframe', 'Camera Shake', 'Crop', 'Edge Feather', 'Offset', 'Transform', 'Wiggle', 'Cineon Converter', 'SDR Conform', 'Simple Text', 'Stroke'];
  // what Premiere shows with each effect's default settings (the others change nothing until you set them)
  var EFFECT_LOOK = { 'Black & White': 'bw', 'Tint': 'bw', 'Invert': 'invert', 'Horizontal Flip': 'hflip', 'Vertical Flip': 'vflip', 'Drop Shadow': 'ds' };
  var ITEMS = PRESETS.map(function (p) { return Object.assign({ kind: 'preset' }, p); })
    .concat(EFFECTS.map(function (n, i) { return { id: 'e' + i, title: n, kind: 'effect', detail: VE, look: EFFECT_LOOK[n] ? [EFFECT_LOOK[n]] : [], fx: 1 }; }));
  var BY = {}; ITEMS.forEach(function (it) { BY[it.id] = it; });
  // a duo: two presets always chained on the same clip, applied in one go (title and keywords as in SearchItem.swift)
  var DUO = { id: 'duo1', kind: 'duo', title: 'Slide Up Text → Glow + Shadow', parts: ['Slide Up Text', 'Glow + Shadow'], of: ['slideup', 'glowsh'], detail: 'Duo · chained 38 times', kw: ['glow', 'shadow', 'Slide Up Text', 'Glow + Shadow', 'duo'] };
  ITEMS.push(DUO); BY.duo1 = DUO;
  var FREQ = ['glowsh', 'duo1', 'slideup', 'grain', 'zoom120', 'e1', 'cinevig', 'e3'];   // ⌘1 … ⌘8, as on the README's palette

  // ---- the search: Khanjar's scorer (command-score, as in Scorer.swift) ----
  var SC = { cont: 1, space: .9, nonSpace: .8, jump: .17, skip: .999, kase: .9999, notComplete: .99 };
  var GAP = ' /-_()[]·.';
  function fold(s) { return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[-_\/.]/g, ' '); }
  function prep(text) { var o = Array.from(text), f = Array.from(fold(text)); return f.length === o.length ? { o: o, f: f } : { o: f, f: f }; }
  function wordStart(c, i) { if (i === 0) return true; var p = c[i - 1], k = c[i]; if (GAP.indexOf(p) >= 0) return true; return (p === p.toLowerCase() && p !== p.toUpperCase() && k === k.toUpperCase() && k !== k.toLowerCase()) || (!/\d/.test(p) && /\d/.test(k)); }
  function scoreCand(q, cand) {
    var f = cand.f, o = cand.o, n = 0;
    for (var i = 0; i < f.length && n < q.length; i++) if (f[i] === q[n]) n++;
    if (n < q.length) return 0;
    var memo = {};
    function inner(s, qi) {
      if (qi === q.length) return s === o.length ? SC.cont : SC.notComplete;
      var key = s * 100 + qi; if (memo[key] !== undefined) return memo[key];
      var high = 0, idx = f.indexOf(q[qi], s);
      while (idx >= 0) {
        var b = inner(idx + 1, qi + 1);
        if (b > high) {
          if (idx === s) b *= SC.cont; else if (GAP.indexOf(o[idx - 1]) >= 0) b *= SC.space; else if (wordStart(o, idx)) b *= SC.nonSpace; else b *= SC.jump;
          b *= Math.pow(SC.skip, idx - s);
          if (o[idx] !== q[qi]) b *= SC.kase;
          if (b > high) high = b;
        }
        idx = f.indexOf(q[qi], idx + 1);
      }
      memo[key] = high; return high;
    }
    return inner(0, 0);
  }
  ITEMS.forEach(function (it) { it._t = prep(it.title); it._k = (it.kw || []).map(prep); it._c = it.kw ? prep(it.kw.join(' ') + ' ' + it.title) : null; });
  function search(query, limit) {
    var q = Array.from(fold(query.trim())); if (!q.length) return [];
    return ITEMS.map(function (it) {
      var b = scoreCand(q, it._t);
      it._k.forEach(function (k) { b = Math.max(b, scoreCand(q, k) * .7); });
      if (it._c) b = Math.max(b, scoreCand(q, it._c) * .6);
      return { it: it, s: b };
    }).filter(function (r) { return r.s > .05; }).sort(function (a, b) { return b.s - a.s || a.it.title.localeCompare(b.it.title); }).slice(0, limit || 8).map(function (r) { return r.it; });
  }

  // ---- what lands on the monitor, read at the playhead: u = time into the clip, d = its duration ----
  var LOOK = {
    bw: function (L) { L.f.push('grayscale(1)'); },
    invert: function (L) { L.f.push('invert(1)'); },
    hflip: function (L) { L.x.push('scaleX(-1)'); },
    vflip: function (L) { L.x.push('scaleY(-1)'); },
    ds: function (L) { if (L.text) L.sh.push('1.6px 1.6px 0 rgba(0,0,0,.5)'); },
    tds: function (L) { if (L.text) L.sh.push('0 2px 2px rgba(0,0,0,.55)', '0 6px 14px rgba(0,0,0,.75)'); },
    glowsh: function (L) { if (L.text) L.sh.push('0 0 4px rgba(255,255,255,.95)', '0 0 14px rgba(255,228,196,.9)', '0 0 32px rgba(255,186,120,.55)', '2px 4px 7px rgba(0,0,0,.7)'); },
    grain: function (L) { if (!L.text) { L.grain = .78; L.f.push('contrast(1.07) saturate(.86)'); } },
    vignette: function (L) { if (!L.text) { L.vig = 1; L.f.push('contrast(1.12) saturate(1.16) sepia(.1)'); } },
    zoom120: function (L, u, d) { L.x.push('scale(' + (1 + .2 * easeInOut(clamp(u / d, 0, 1))).toFixed(4) + ')'); },
    slideup: function (L, u) { var p = easeOut(clamp(u / .55, 0, 1)); L.x.push('translateY(' + ((1 - p) * 60).toFixed(1) + '%)'); L.o *= clamp(u / .25, 0, 1); },
    blurin: function (L, u) { var b = (1 - clamp(u / .8, 0, 1)) * 14; if (b > .05) L.f.push('blur(' + b.toFixed(2) + 'px)'); },
    blurout: function (L, u, d) { var b = clamp((u - (d - .8)) / .8, 0, 1) * 14; if (b > .05) L.f.push('blur(' + b.toFixed(2) + 'px)'); },
    gbfadein: function (L, u) { var p = clamp(u / .7, 0, 1); if (p < 1) L.f.push('blur(' + ((1 - p) * 10).toFixed(2) + 'px)'); L.o *= p; },
    gbfadeout: function (L, u, d) { var p = clamp((d - u) / .7, 0, 1); if (p < 1) L.f.push('blur(' + ((1 - p) * 10).toFixed(2) + 'px)'); L.o *= p; },
    glitch: function (L, u) {
      if (u > .5) return;
      var k = Math.floor(u * 24), j = (rnd(k + 3) - .5) * 10 * (1 - u / .5);
      L.x.push('translateX(' + j.toFixed(1) + 'px)');
      if (L.text) L.sh.push((-3 * (1 - u / .5)).toFixed(1) + 'px 0 rgba(255,0,90,.85)', (3 * (1 - u / .5)).toFixed(1) + 'px 0 rgba(0,225,255,.85)');
      else L.f.push('hue-rotate(' + Math.round(rnd(k) * 90) + 'deg) saturate(1.6)');
      L.o *= rnd(k + 7) > .25 ? 1 : .35;
    },
    glowpulse: function (L, u) { if (!L.text) return; var a = .5 + .5 * Math.sin(u * 5.2); L.sh.push('0 0 ' + (4 + 10 * a).toFixed(1) + 'px rgba(255,255,255,' + (.45 + .45 * a).toFixed(2) + ')', '0 0 ' + (16 + 18 * a).toFixed(1) + 'px rgba(255,214,170,' + (.25 + .35 * a).toFixed(2) + ')'); }
  };

  // ---- one screen ----
  function make(root, o) {
    o = o || {};
    var layout = o.layout || 'wide', panel = o.panel === undefined ? 'project' : o.panel;
    var api = { root: root };
    var D = layout === 'wide' ? { w: 1240, h: 700, row1: 290, mon: 330 } : layout === 'stage' ? { w: 860, h: 560, row1: 236, mon: 232 } : { w: 430, h: 800, row1: 430, mon: 0 };
    if (o.size) Object.assign(D, o.size);
    var TRK = o.tracks || (layout === 'wide' ? [['V4', 24], ['V3', 28], ['V2', 40], ['V1', 40], ['A1', 36], ['A2', 24], ['A3', 30], ['Mix', 22]]
      : layout === 'stage' ? [['V4', 20], ['V3', 25], ['V2', 34], ['V1', 34], ['A1', 30], ['A3', 24]]
      : [['V4', 22], ['V3', 28], ['V2', 40], ['V1', 40], ['A1', 36], ['A2', 22], ['A3', 30]]);

    // ---------- markup ----------
    function headHTML() {
      return '<div class="pp-head" aria-hidden="true"><span class="lights"><i></i><i></i><i></i></span><div class="hl">' + svg('home') + '<span>Import</span><span class="on">Edit</span><span>Export</span></div>'
        + '<div class="hc">Short 01<span class="ed"> - Edited</span></div><div class="hr"><span class="wsn">VERTICAL</span>' + svg('ws') + svg('share') + svg('full') + '</div></div>';
    }
    function pjHTML() {
      var fxOn = panel === 'effects';
      return '<section class="pg pp-pj' + (fxOn ? ' efx-on' : '') + '" aria-hidden="true"><div class="pg-tabs"><span class="pg-tab t-pj' + (fxOn ? '' : ' on') + '">Project: Short 01' + (fxOn ? '' : HAM) + '</span><span class="pg-tab">Media Browser</span>'
        + '<span class="pg-tab t-fx' + (fxOn ? ' on' : '') + '">Effects' + (fxOn ? HAM : '') + '</span><span class="pg-tab">Effect Controls</span><span class="pg-more">»</span></div>'
        + '<div class="pj-pane"' + (fxOn ? ' hidden' : '') + ' style="display:flex;flex-direction:column;flex:1 1 auto;min-height:0">'
        + '<div class="pj-path">' + svg('folder') + 'Short 01.prproj</div>'
        + '<div class="pj-search"><span class="pj-field">' + svg('mag') + '</span>' + svg('sbin') + '<span class="pj-count">8 items</span></div>'
        + '<div class="pj-frame"><div class="pj-head"><span></span><span>Name' + svg('sortup', '', '0 0 16 16') + '</span><span class="c3">Frame Rate</span><span class="c4">Media Start</span><span class="c5">Media Duration</span></div><div class="pj-list"></div></div></div>'
        + '<div class="efx-pane"' + (fxOn ? '' : ' hidden') + ' style="display:flex;flex-direction:column;flex:1 1 auto;min-height:0">'
        + '<div class="efx-top"><span class="efx-field">' + svg('mag') + '<span class="q"></span><i class="car"></i></span><span class="flt">' + svg('acc') + svg('b32') + svg('yuv') + '</span></div>'
        + '<div class="efx-tree"></div><div class="efx-foot">' + svg('newbin') + svg('trash') + '</div></div></section>';
    }
    function monHTML() {
      return '<section class="pg pp-mon" aria-label="Program monitor"><div class="pg-tabs" aria-hidden="true"><span class="pg-tab on">Program: Short 01' + HAM + '</span></div>'
        + '<div class="mon-view"><div class="mon-frame"><div class="mon-stack"></div></div></div>'
        + '<div class="mon-bar" aria-hidden="true"><span class="tc m-tc">00:00:03:05</span><span class="dd">Fit</span><span class="sp"></span><span class="dd full">Full</span>' + svg('wrench', 'wr') + '<span class="du">00:00:12:00</span></div>'
        + '<div class="mon-rul" aria-hidden="true"><i class="m-cti"></i></div>'
        + '<div class="mon-ctl"><i class="x" aria-hidden="true">' + svg('setIn') + '</i><i class="x" aria-hidden="true">' + svg('setOut') + '</i><i aria-hidden="true">' + svg('goIn') + '</i><i aria-hidden="true">' + svg('stepB') + '</i>'
        + '<button class="play" type="button" aria-label="Play"' + (o.interactive ? '' : ' tabindex="-1"') + '>' + svg('play') + '</button><i aria-hidden="true">' + svg('stepF') + '</i><i aria-hidden="true">' + svg('goOut') + '</i><i class="x" aria-hidden="true">' + svg('camera') + '</i></div></section>';
    }
    function toolsHTML() {
      return '<section class="pg pp-tools" aria-hidden="true"><i class="on">' + svg('sel') + '</i><i>' + svg('tsel') + '</i><i>' + svg('ripple') + '</i><i>' + svg('razor') + '</i><i>' + svg('slip') + '</i><i>' + svg('pen') + '</i><i>' + svg('rect') + '</i><i>' + svg('hand') + '</i><i>' + svg('type') + '</i></section>';
    }
    function tlHTML() {
      return '<section class="pg pp-tl focus" aria-label="Timeline of Short 01"><div class="pg-tabs" aria-hidden="true"><span class="pg-tab on"><span class="x">×</span><i class="lc"></i>Short 01' + HAM + '</span><span class="pg-more">»</span></div>'
        + '<div class="tl-top" aria-hidden="true"><span class="tl-tc">00:00:03:05</span><span class="tl-tools"><i class="on">' + svg('nest') + '</i><i class="on">' + svg('snap') + '</i><i class="on">' + svg('linked') + '</i><i>' + svg('marker') + '</i><i>' + svg('wrench') + '</i></span></div>'
        + '<div class="tlx"><div class="tlx-rul" aria-hidden="true"></div>'
        + TRK.map(function (r) {
          var n = r[0], v = n.charAt(0) === 'V';
          if (n === 'Mix') return '<div class="trk mix" style="--h:' + r[1] + 'px"><div class="th" aria-hidden="true"><span class="sp"></span>' + svg('lock') + '<span>Mix</span><span class="mv">0.0</span>' + svg('bow') + '</div><div class="ln"></div></div>';
          var one = n === 'V1' || n === 'A1', tgt = n !== 'V4';
          return '<div class="trk' + (n === 'V1' ? ' v1' : '') + '" data-t="' + n + '" style="--h:' + r[1] + 'px"><div class="th" aria-hidden="true"><span class="sp' + (one ? ' on' : '') + '">' + n + '</span>' + svg('lock')
            + '<span class="tg' + (tgt ? ' on' : '') + '">' + n + '</span>' + svg('sync', 'sy') + (v ? svg('eye', 'ey') : '<b>M</b><b>S</b>' + svg('mic', 'mc')) + '</div><div class="ln"></div></div>';
        }).join('')
        + '<div class="cti"><svg viewBox="0 0 13 19" aria-hidden="true"><path d="M1.5 0h10A1.5 1.5 0 0 1 13 1.5V11l-6.5 7L0 11V1.5A1.5 1.5 0 0 1 1.5 0z"/></svg></div>'
        + '<div class="tlx-sb" aria-hidden="true"><i></i></div></div></section>';
    }
    function mtrHTML() {
      return '<section class="pg pp-mtr" aria-hidden="true"><div class="sc"><span>0</span><span>-12</span><span>-24</span><span>-36</span><span>-48</span><span>dB</span></div><span class="bar"><i></i></span><span class="bar"><i></i></span></section>';
    }
    function kjHTML() {
      return '<div class="kj"><div class="kp" role="dialog" aria-label="Khanjar palette" hidden><div class="kp-field">' + KMAG
        + '<input type="text" autocomplete="off" spellcheck="false" placeholder="Effect or preset…" aria-label="Search effects and presets"' + (o.interactive ? '' : ' tabindex="-1" readonly') + '></div><div class="kp-sep"></div>'
        + '<div class="kp-body"><div class="kp-head">Frequently used</div><ul class="kp-list" role="listbox"></ul><div class="kp-empty" hidden></div></div>'
        + '<div class="kp-sep"></div><div class="kp-foot">↵ apply  ·  ⌘1–⌘0 direct  ·  esc close</div></div>'
        + '<div class="khud" role="status" aria-live="polite"></div><div class="kkeys" aria-hidden="true"></div><div class="kdrag" aria-hidden="true"></div>' + CUR + '</div>';
    }
    root.className = 'pp';
    root.dataset.layout = layout;
    if (panel) root.dataset.panel = panel;
    root.style.width = D.w + 'px'; root.style.height = D.h + 'px';
    root.style.setProperty('--row1', D.row1 + 'px'); root.style.setProperty('--mon-w', D.mon + 'px');
    root.innerHTML = headHTML() + '<div class="pp-ws">' + (panel && layout !== 'port' || panel === 'effects' ? pjHTML() : '') + (o.monitor === false ? '' : monHTML()) + toolsHTML() + tlHTML() + mtrHTML() + '</div>' + kjHTML();
    if (o.monitor === false) root.querySelector('.pp-ws').style.gridTemplateColumns = layout === 'stage' ? 'minmax(0,1fr)' : '';

    function q(s) { return root.querySelector(s); }
    var tlx = q('.tlx'), rul = q('.tlx-rul'), cti = q('.cti'), ttc = q('.tl-tc');
    var frame = q('.mon-frame'), stack = q('.mon-stack'), mtc = q('.m-tc'), mcti = q('.m-cti'), playB = q('.play');
    var bars = root.querySelectorAll('.pp-mtr .bar i');
    var kp = q('.kp'), kin = q('.kp-field input'), klist = q('.kp-list'), khead = q('.kp-head'), kempty = q('.kp-empty');
    var khud = q('.khud'), kkeys = q('.kkeys'), kcur = q('.kcur'), kdrag = q('.kdrag');
    var lanes = {}, H = {};
    [].forEach.call(root.querySelectorAll('.trk[data-t]'), function (r) { lanes[r.dataset.t] = r.querySelector('.ln'); H[r.dataset.t] = parseFloat(r.style.getPropertyValue('--h')); });
    if (stack) { stack.style.cssText = 'position:absolute;inset:0'; }

    // ---------- the sequence: Short 01, a talking head with B-roll and two titles ----------
    function fresh() {
      return [
        { id: 't1', tr: 'V3', n: 'Where it all started', s: .4, e: 4.4, c: 'lavender', text: 'Where it all\nstarted' },
        { id: 't2', tr: 'V3', n: 'Same three, every day', s: 6.4, e: 10.4, c: 'lavender', text: 'Same three,\nevery day' },
        { id: 'b1', tr: 'V2', n: 'sunset_drive.mp4', s: 1.6, e: 4.6, c: 'violet', src: '14388179', inn: .4, hd: '14388179' },
        { id: 'b2', tr: 'V2', n: 'coffee_pour.mp4', s: 6.2, e: 8.6, c: 'violet', src: '20056043', inn: .6, hd: '20056043' },
        { id: 'b3', tr: 'V2', n: 'ocean_aerial.mp4', s: 9.2, e: 11.8, c: 'violet', src: '29285421', inn: .3, hd: '29285421' },
        { id: 'v1', tr: 'V1', n: 'C0012.MP4', s: 0, e: 6.2, c: 'iris', src: '7261920', inn: 0, hd: '7261920', link: 'a1' },
        { id: 'v2', tr: 'V1', n: 'C0013.MP4', s: 6.2, e: 12, c: 'iris', src: '7261920', inn: 6.2, hd: '7261920-c', link: 'a2' },
        { id: 'a1', tr: 'A1', n: 'C0012.MP4', s: 0, e: 6.2, c: 'iris', w: 'talk', link: 'v1' },
        { id: 'a2', tr: 'A1', n: 'C0013.MP4', s: 6.2, e: 12, c: 'iris', w: 'talk', link: 'v2' },
        { id: 'm1', tr: 'A3', n: 'Lo-fi beat.mp3', s: 0, e: 12, c: 'caribbean', w: 'music' }
      ].map(function (c) { c.fx = []; c.sel = false; return c; });
    }
    var clips = fresh(), byId = {}, t = 3.2, playing = false, last = 0, raf = 0, undo = [], awake = !!o.video, edited = false;
    function index() { byId = {}; clips.forEach(function (c) { byId[c.id] = c; }); }
    index();

    // ---------- the Project panel ----------
    var PRP = {
      seq: '<g fill="#729acc"><rect x="6" y="11" width="6.4" height="4" rx="1"/><rect x="17.6" y="11" width="12" height="4" rx="1"/><rect x="2" y="17" width="10.4" height="4" rx="1"/><rect x="17.6" y="17" width="6.4" height="4" rx="1"/></g><g fill="#29d698"><rect x="5" y="23" width="7.4" height="4" rx="1"/><rect x="17.6" y="23" width="12" height="4" rx="1"/></g><path fill="#fff" fill-opacity=".65" d="M12.5 2h5v5.2L16 8.7V29a1 1 0 0 1-2 0V8.7l-1.5-1.5z"/>',
      video: '<path fill="#a690e0" fill-rule="evenodd" d="M5 3h22a1 1 0 0 1 1 1v24a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zM6.4 5.4V8H9V5.4zm0 5.2v2.6H9v-2.6zm0 5.2v2.6H9v-2.6zm0 5.2v2.6H9V21zm0 4.6v2.4H9v-2.4zM23 5.4V8h2.6V5.4zm0 5.2v2.6h2.6v-2.6zm0 5.2v2.6h2.6v-2.6zm0 5.2v2.6h2.6V21zm0 4.6v2.4h2.6v-2.4zM11.4 14.7v2.6h9.2v-2.6z"/>',
      av: '<path fill="#a690e0" fill-rule="evenodd" d="M1 2h20a1 1 0 0 1 1 1v20a1 1 0 0 1-1 1H1a1 1 0 0 1-1-1V3a1 1 0 0 1 1-1zM2.2 4.2v2h2v-2zm0 4.4v2h2v-2zm0 4.4v2h2v-2zm0 4.4v2h2v-2zM17.8 4.2v2h2v-2zm0 4.4v2h2v-2z"/><rect x="6" y="12" width="25" height="19" rx="1.6" fill="#1d1d1d"/><path fill="#29d698" fill-rule="evenodd" d="M8 13.4h21a1 1 0 0 1 1 1v14.2a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1V14.4a1 1 0 0 1 1-1zM10.4 20.6v1.8H12v-1.8zm3.2-2.6v7h1.6v-7zm3.2-2.4v11.8h1.6V15.6zm3.2 3v5.8h1.6v-5.8zm3.2-1.8v9.4h1.6v-9.4zm3.2 3.4v2.6h1.6v-2.6z"/>',
      audio: '<rect x="2.6" y="7.6" width="26.8" height="16.8" rx="1.4" fill="none" stroke="#29d698" stroke-width="2.2"/><path fill="#29d698" d="M7.4 15h1.6v2H7.4zm3.2-2.6h1.6v7.2h-1.6zm3.2-2.4h1.6v12h-1.6zm3.2 3h1.6v6h-1.6zm3.2-1.8h1.6v9.6h-1.6zm3.2 3.4h1.6v2.8h-1.6z"/>',
      still: '<path fill="#fff" fill-opacity=".65" fill-rule="evenodd" d="M7 2h12l7 7v20a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V3a1 1 0 0 1 1-1zM12.6 14.6a2.6 2.6 0 1 0 0 5.2 2.6 2.6 0 0 0 0-5.2zM9.4 27h13.2l-4.6-7.2-3.2 4.4-1.6-1.8z"/>'
    };
    var PROJECT = [['Adjustment Layer', 'still', 'lavender', '', '00:00:00:00', '00:00:05:00'], ['C0012.MP4', 'av', 'iris', '25.00 fps', '10:24:31:02', '00:01:12:14'],
      ['C0013.MP4', 'av', 'iris', '25.00 fps', '10:26:02:11', '00:00:48:06'], ['coffee_pour.mp4', 'video', 'violet', '30.00 fps', '00:00:00:00', '00:00:06:00'],
      ['Lo-fi beat.mp3', 'audio', 'caribbean', '44100 Hz', '00:00:00:00', '00:02:31:14'], ['ocean_aerial.mp4', 'video', 'violet', '24.00 fps', '00:00:00:00', '00:00:06:00'],
      ['Short 01', 'seq', 'forest', '25.00 fps', '00:00:00:00', '00:00:12:00'], ['sunset_drive.mp4', 'video', 'violet', '30.00 fps', '00:00:00:00', '00:00:07:00']];
    var pjl = q('.pj-list');
    if (pjl) pjl.innerHTML = PROJECT.map(function (r) {
      return '<div class="prw" data-n="' + esc(r[0]) + '"><span class="lab"><i style="background:' + LAB[r[2]] + '"></i></span><span class="nm"><svg class="ic" viewBox="0 0 32 32" aria-hidden="true">' + PRP[r[1]] + '</svg><b>' + esc(r[0]) + '</b></span>'
        + '<span class="c3">' + r[3] + '</span><span class="c4">' + r[4] + '</span><span class="c5">' + r[5] + '</span></div>';
    }).join('');

    // ---------- timeline drawing ----------
    function pps() { var l = lanes.V1; return (l ? l.clientWidth : 600) / VIEW; }
    // a stereo clip's waveform as Premiere 2026 draws it: two channels, each rectified on its own baseline
    function wave(c, w) {
      var n = Math.max(6, Math.round(w / 1.6)), seed = Math.round(c.s * 37) + c.n.length * 7, d = '';
      for (var ch = 0; ch < 2; ch++) {
        var base = ch ? 100 : 50, p = 'M0 ' + base;
        for (var j = 0; j < n; j++) {
          var r = rnd(seed + j * 1.7 + ch * .37), a;
          if (c.w === 'music') a = 18 + 18 * Math.abs(Math.sin(j * .9 + seed)) * (.6 + .4 * r) + (j % 8 === 0 ? 9 : 0);
          else { var env = Math.sin(j * .19 + seed) + Math.sin(j * .057 + seed * .3); a = env > -.5 ? (9 + 30 * r) * (.55 + .45 * Math.abs(Math.sin(j * .7 + seed))) : 1 + 3 * r; }
          p += 'V' + (base - Math.min(46, a)).toFixed(1) + 'H' + (j + 1);
        }
        d += p + 'V' + base + 'Z';
      }
      return '<svg class="wv" viewBox="0 0 ' + n + ' 100" preserveAspectRatio="none" aria-hidden="true"><path d="' + d + '"/></svg><i class="vol"></i>';
    }
    function clipHTML(c, k, h) {
      var x = c.s * k + 1, w = Math.max(4, (c.e - c.s) * k - 1), v = c.tr.charAt(0) === 'V';
      var cls = 'cl' + (c.sel ? ' sel' : '') + (c.fx.length ? ' has-fx' : '') + (c.isNew ? ' new' : '');
      var s = '<div class="' + cls + '" data-id="' + c.id + '" style="left:' + x.toFixed(1) + 'px;width:' + w.toFixed(1) + 'px;--c:' + LAB[c.c] + (c.w ? ';--w:' + WAVE[c.c] : '') + '">';
      if (v && c.hd && h >= 30 && w > 34) s += '<i class="hd" style="background-image:url(' + FOOT + c.hd + '.jpg)"></i>';
      s += '<span class="nm">' + esc(c.n) + '</span>' + FX;
      if (!v) s += wave(c, w);
      return s + '</div>';
    }
    function draw() {
      var k = pps(); if (!k) return;
      var h = '', step = k * 2 >= 92 ? 2 : 4;
      for (var i = 0; i <= VIEW * 2; i++) {
        var s = i / 2, x = (s * k).toFixed(1), maj = s % step === 0;
        h += '<i' + (maj ? ' class="l"' : '') + ' style="left:' + x + 'px"></i>' + (maj ? '<span style="left:' + x + 'px">' + tc(s) + '</span>' : '');
      }
      rul.innerHTML = h + '<b class="rbar" style="width:' + (SEQ * k).toFixed(1) + 'px"></b>';
      Object.keys(lanes).forEach(function (n) {
        lanes[n].innerHTML = clips.filter(function (c) { return c.tr === n; }).map(function (c) { return clipHTML(c, k, H[n]); }).join('');
      });
      clips.forEach(function (c) { c.isNew = false; });
      placeCTI();
    }
    function placeCTI() {
      if (lanes.V1) cti.style.transform = 'translateX(' + (lanes.V1.offsetLeft + t * pps()).toFixed(1) + 'px)';
      ttc.textContent = tc(t);
      if (mtc) { mtc.textContent = tc(t); mcti.style.left = (t / SEQ * 100).toFixed(2) + '%'; }
    }
    function clipEl(id) { return root.querySelector('.cl[data-id="' + id + '"]'); }
    function paintSel() { clips.forEach(function (c) { var el = clipEl(c.id); if (el) { el.classList.toggle('sel', c.sel); el.classList.toggle('has-fx', !!c.fx.length); } }); }

    // ---------- the Program monitor ----------
    var layers = {}, titles = {};
    function layer(src) {
      var L = layers[src];
      if (!L) {
        var el = document.createElement('div'); el.className = 'ly';
        el.innerHTML = '<img alt="" src="' + FOOT + src + '.jpg" draggable="false"><i class="grain"></i><i class="vig"></i>';
        stack.appendChild(el);
        L = layers[src] = { el: el, v: null, grain: el.querySelector('.grain'), vig: el.querySelector('.vig') };
      }
      if (awake && !L.v) {
        var v = document.createElement('video');
        v.muted = true; v.playsInline = true; v.preload = 'auto'; v.setAttribute('muted', ''); v.setAttribute('playsinline', ''); v.src = FOOT + src + '.mp4';
        v.addEventListener('loadeddata', function () { L.el.classList.add('ready'); sync(true); });
        L.el.insertBefore(v, L.grain); L.v = v;
      }
      return L;
    }
    function title(c) {
      var T = titles[c.id];
      if (!T) { var el = document.createElement('div'); el.className = 'ttl'; el.textContent = c.text; stack.appendChild(el); T = titles[c.id] = el; }
      return T;
    }
    function lookOf(c, text, at) {
      var L = { f: [], x: [], sh: [], o: 1, grain: 0, vig: 0, text: text }, u = at - c.s, d = c.e - c.s;
      c.fx.forEach(function (a) { if (a.look) (a.look || []).forEach(function (n) { if (LOOK[n]) LOOK[n](L, u, d); }); });
      return L;
    }
    function applyLook(el, L) {
      el.style.filter = L.f.length ? L.f.join(' ') : '';
      el.style.transform = L.x.length ? L.x.join(' ') : '';
      el.style.opacity = L.o < 1 ? L.o.toFixed(3) : '';
      if (L.text) el.style.textShadow = L.sh.length ? L.sh.join(',') : '';
    }
    function render() {
      if (!stack) return;
      var at = Math.min(t, SEQ - .02), video = null, adj = [];
      ['V4', 'V3', 'V2', 'V1'].forEach(function (tr) {
        clips.forEach(function (c) {
          if (c.tr !== tr || at < c.s || at >= c.e) return;
          if (c.adj) adj.push(c);
          else if (c.src && !video) video = c;
        });
      });
      Object.keys(layers).forEach(function (s) { layers[s].el.classList.toggle('on', !!video && video.src === s); });
      if (video) {
        var L = layer(video.src); L.el.classList.add('on');
        var lk = lookOf(video, false, at);
        applyLook(L.el, lk);
        L.grain.style.opacity = lk.grain; L.vig.style.opacity = lk.vig;
        L.grain.style.transform = playing ? 'translate(' + Math.round(rnd(Math.floor(at * 24)) * 40) + 'px,' + Math.round(rnd(Math.floor(at * 24) + 9) * 40) + 'px)' : '';
      }
      clips.forEach(function (c) {
        if (!c.text) return;
        var on = at >= c.s && at < c.e, T = title(c);
        T.classList.toggle('on', on);
        if (on) applyLook(T, lookOf(c, true, at));
      });
      // an adjustment layer acts on everything under it
      var A = { f: [], x: [], sh: [], o: 1, grain: 0, vig: 0, text: false };
      adj.forEach(function (c) { var l = lookOf(c, false, at); A.f = A.f.concat(l.f); A.x = A.x.concat(l.x); });
      stack.style.filter = A.f.join(' '); stack.style.transform = A.x.join(' ');
      sync(false);
    }
    function sync(force) {
      if (!awake) return;
      var at = Math.min(t, SEQ - .02), cur = null;
      ['V4', 'V3', 'V2', 'V1'].forEach(function (tr) { clips.forEach(function (c) { if (!cur && c.tr === tr && c.src && at >= c.s && at < c.e) cur = c; }); });
      Object.keys(layers).forEach(function (s) {
        var L = layers[s]; if (!L.v) return;
        if (!cur || cur.src !== s) { if (!L.v.paused) L.v.pause(); return; }
        var off = at - cur.s + (cur.inn || 0); if (L.v.duration) off = Math.min(off, L.v.duration - .05);
        try {
          if (playing) { if (L.v.paused) { L.v.currentTime = off; var pr = L.v.play(); if (pr && pr.catch) pr.catch(function () {}); } else if (Math.abs(L.v.currentTime - off) > .3) L.v.currentTime = off; }
          else { if (!L.v.paused) L.v.pause(); if (force || Math.abs(L.v.currentTime - off) > .03) L.v.currentTime = off; }
        } catch (e) {}
      });
    }
    function meter(on, now) {
      for (var i = 0; i < bars.length; i++) {
        var lv = on ? .5 + .32 * Math.abs(Math.sin(now / (160 + i * 41))) * (.65 + .35 * rnd(Math.floor(now / 90) + i)) : 0;
        bars[i].style.setProperty('--lv', lv.toFixed(3));
      }
    }
    var stopAt = SEQ;
    function tick(now) {
      if (!playing) return;
      t += Math.min(.1, Math.max(0, (now - last) / 1000)); last = now;
      if (t >= stopAt) { t = Math.min(stopAt, SEQ); placeCTI(); render(); stop(); return; }
      placeCTI(); render(); meter(true, now);
      raf = requestAnimationFrame(tick);
    }
    function play(until) {
      if (playing) return;
      if (t >= SEQ - .04) t = 0;
      stopAt = until || SEQ;
      playing = true; last = performance.now();
      if (playB) { playB.innerHTML = svg('pause'); playB.setAttribute('aria-label', 'Stop'); }
      raf = requestAnimationFrame(tick);
    }
    function stop() {
      if (!playing) return;
      playing = false; cancelAnimationFrame(raf);
      if (playB) { playB.innerHTML = svg('play'); playB.setAttribute('aria-label', 'Play'); }
      meter(false); render();
    }
    function seek(s) { t = clamp(s, 0, SEQ); placeCTI(); render(); }

    // ---------- selection ----------
    function setSel(ids, add) {
      if (!add) clips.forEach(function (c) { c.sel = false; });
      ids.forEach(function (id) { var c = byId[id]; if (!c) return; c.sel = true; if (c.link && byId[c.link]) byId[c.link].sel = true; });
      paintSel();
      if (o.onSelect) o.onSelect(selected());
    }
    function toggleSel(id) {
      var c = byId[id]; if (!c) return;
      var on = !c.sel; c.sel = on; if (c.link && byId[c.link]) byId[c.link].sel = on;
      paintSel(); if (o.onSelect) o.onSelect(selected());
    }
    function selected() { return clips.filter(function (c) { return c.sel; }); }

    // ---------- applying, as Khanjar does: one grouped transaction, video clips only ----------
    function hud(text, kind, ms) {
      khud.innerHTML = (kind === 'ok' ? KCHECK : kind === 'warn' ? KWARN : '') + '<span>' + esc(text) + '</span>';
      khud.classList.add('show'); clearTimeout(hud.t);
      hud.t = setTimeout(function () { khud.classList.remove('show'); }, ms || (kind === 'warn' ? 4000 : kind === 'ok' ? 1400 : 1800));
    }
    function apply(item, onlyIds, silent) {
      var sel = onlyIds ? onlyIds.map(function (id) { return byId[id]; }) : selected();
      var vids = sel.filter(function (c) { return c.tr.charAt(0) === 'V'; });
      if (!sel.length) { if (!silent) hud('Select a clip in the timeline first', 'warn'); return 0; }
      if (!vids.length) { if (!silent) hud('Select a video clip (not just audio)', 'warn'); return 0; }
      var parts = item.kind === 'duo' ? item.of.map(function (id) { return BY[id]; }) : [item];
      var steps = 0;
      parts.forEach(function (p) {
        vids.forEach(function (c) { c.fx.push({ id: p.id, look: p.look, preset: p.kind === 'preset' }); });
        steps += p.kind === 'preset' ? 2 : 1;
      });
      undo.push({ ids: vids.map(function (c) { return c.id; }), n: parts.length, steps: steps, left: steps, preset: parts.some(function (p) { return p.kind === 'preset'; }) });
      paintSel();
      if (!silent || silent === 'flash') vids.forEach(function (c) { var el = clipEl(c.id); if (el) { el.classList.remove('flash'); void el.offsetWidth; el.classList.add('flash'); } });
      if (!edited) { edited = true; root.classList.add('edited'); }
      render();
      if (!silent) hud(item.title + ' → ' + vids.length + ' clip' + (vids.length === 1 ? '' : 's'), 'ok');
      if (o.onApply) o.onApply(item, vids);
      return vids.length;
    }
    // one ⌘Z for an effect, two for a preset: the first takes back its settings, the second the effect itself
    function doUndo() {
      var u = undo[undo.length - 1]; if (!u) return false;
      u.left--;
      u.ids.forEach(function (id) {
        var c = byId[id]; if (!c) return;
        var mine = c.fx.slice(-u.n);
        if (u.left > 0) mine.forEach(function (a) { if (a.preset) a.look = []; });
      });
      if (u.left <= 0) { undo.pop(); u.ids.forEach(function (id) { var c = byId[id]; if (c) c.fx.splice(-u.n, u.n); }); }
      paintSel(); render();
      return true;
    }

    // ⌘⇧J: Khanjar drops the project's adjustment layer above the clips, at the playhead
    function addAdjustment() {
      var at = t, free = null;
      ['V2', 'V3', 'V4'].forEach(function (tr) {
        if (free || !lanes[tr]) return;
        var busy = clips.some(function (c) { return c.tr === tr && c.e > at && c.s < at + 5; });
        var above = ['V2', 'V3', 'V4'].slice(['V2', 'V3', 'V4'].indexOf(tr) + 1).every(function (t2) { return true; });
        if (!busy && above) free = tr;
      });
      if (!free) { hud('Couldn\'t place the adjustment layer — add an empty video track above your clips', 'warn'); return null; }
      var c = { id: 'adj' + Math.round(at * 100), tr: free, n: 'Adjustment Layer', s: at, e: Math.min(SEQ, at + 5), c: 'lavender', adj: true, fx: [], sel: false, isNew: true };
      clips.push(c); index();
      clips.forEach(function (x) { x.sel = false; }); c.sel = true;
      draw(); render();
      if (!edited) { edited = true; root.classList.add('edited'); }
      hud('Adjustment layer → track ' + free, 'ok');
      return c;
    }

    // ---------- the palette ----------
    var rows = [], cur = 0, isOpen = false, freqMode = true;
    function glyph(it, i) {
      if (freqMode && i < 10) return '⌘' + ((i + 1) % 10);
      if (it.kind === 'duo') return KLINK;
      if (it.kind === 'preset') return KSTACK;
      return '';
    }
    function renderList() {
      var query = kin.value.trim();
      freqMode = !query;
      rows = freqMode ? FREQ.map(function (id) { return BY[id]; }) : search(query, 8);
      cur = Math.min(cur, Math.max(0, rows.length - 1));
      khead.hidden = !freqMode;
      kempty.hidden = !!rows.length || freqMode;
      if (!rows.length && !freqMode) kempty.textContent = 'Nothing found for “' + query + '”';
      klist.innerHTML = rows.map(function (it, i) {
        var body = it.parts ? '<span class="chips"><span class="chip">' + esc(it.parts[0]) + '</span><span class="arr">→</span><span class="chip">' + esc(it.parts[1]) + '</span></span>'
          : '<span class="t">' + esc(it.title) + '</span>' + (it.partial ? '<span class="part">partial</span>' : '');
        return '<li role="option" data-i="' + i + '" class="' + (i === cur ? 'on' : '') + '" aria-selected="' + (i === cur) + '"><span class="g">' + glyph(it, i) + '</span>' + body + '<span class="d">' + esc(it.detail) + '</span></li>';
      }).join('');
    }
    function setCur(i) {
      if (!rows.length) return;
      cur = clamp(i, 0, rows.length - 1);
      [].forEach.call(klist.children, function (li, j) { li.classList.toggle('on', j === cur); li.setAttribute('aria-selected', String(j === cur)); });
    }
    var P = {
      open: function () { isOpen = true; kin.value = ''; cur = 0; renderList(); kp.hidden = false; khud.classList.remove('show'); if (o.interactive && o.focusInput !== false) setTimeout(function () { try { kin.focus({ preventScroll: true }); } catch (e) {} }, 20); },
      close: function () { isOpen = false; kp.hidden = true; try { kin.blur(); } catch (e) {} },
      isOpen: function () { return isOpen; },
      set: function (text) { kin.value = text; cur = 0; renderList(); },
      type: function (text, each) {
        var i = 0, base = kin.value;
        return new Promise(function (res) {
          (function next() {
            if (!isOpen || i > text.length) { res(); return; }
            kin.value = base + text.slice(0, i++); cur = 0; renderList();
            if (i > text.length) { res(); return; }
            setTimeout(next, (each || 120) + Math.random() * 50);
          })();
        });
      },
      move: function (d) { setCur(cur + d); },
      pick: function (i) { setCur(i); },
      commit: function (i) {
        if (i !== undefined) setCur(i);
        var it = rows[cur]; if (!it) return null;
        P.close(); apply(it); return it;
      },
      direct: function (digit) { var i = digit === 0 ? 9 : digit - 1; if (!freqMode || !rows[i]) return null; return P.commit(i); },
      input: kin, list: klist, rows: function () { return rows; }
    };
    kin.addEventListener('input', function () { cur = 0; renderList(); if (o.onType) o.onType(); });
    klist.addEventListener('pointermove', function (e) { var li = e.target.closest('li'); if (li && +li.dataset.i !== cur) setCur(+li.dataset.i); });
    klist.addEventListener('click', function (e) { var li = e.target.closest('li'); if (li) { if (o.onTouch) o.onTouch(); P.commit(+li.dataset.i); } });
    kp.addEventListener('pointerdown', function (e) { if (e.target === kin) return; e.preventDefault(); });

    // ---------- the keys pressed, a cursor, a dragged item ----------
    function keys(list, ms) {
      kkeys.innerHTML = list.map(function (k) { return '<span>' + esc(k) + '</span>'; }).join('');
      kkeys.classList.add('show'); clearTimeout(keys.t);
      keys.t = setTimeout(function () { kkeys.classList.remove('show'); }, ms || 700);
    }
    function scale() { var r = root.getBoundingClientRect(); return r.width / root.offsetWidth || 1; }
    function at(el, fx, fy) {
      var R = root.getBoundingClientRect(), r = el.getBoundingClientRect(), k = scale();
      return { x: (r.left - R.left + r.width * (fx === undefined ? .5 : fx)) / k, y: (r.top - R.top + r.height * (fy === undefined ? .5 : fy)) / k };
    }
    var cpos = { x: D.w * .62, y: D.h * .78 };
    function cursorTo(p, ms) {
      if (p && p.nodeType) p = at(p, .5, .55);
      cpos = p; kcur.classList.add('show');
      kcur.style.transitionDuration = (ms || 0) + 'ms,200ms';
      kcur.style.transform = 'translate(' + p.x.toFixed(1) + 'px,' + p.y.toFixed(1) + 'px)';
      kdrag.style.transitionDuration = (ms || 0) + 'ms,150ms';
      kdrag.style.transform = 'translate(' + (p.x + 12).toFixed(1) + 'px,' + (p.y + 14).toFixed(1) + 'px)';
      return wait(ms || 0);
    }
    function click() { kcur.classList.remove('click'); void kcur.offsetWidth; kcur.classList.add('click'); }
    function hideCursor() { kcur.classList.remove('show'); kdrag.classList.remove('show'); }

    // ---------- the Effects panel (the old way) ----------
    var tree = [
      { n: 'Presets', k: [{ n: 'Bevel Edges', k: [] }, { n: 'Blurs', k: [{ n: 'Fast Blur In', p: 1 }, { n: 'Fast Blur Out', p: 1 }] }, { n: 'Color', k: [{ n: 'Cinematic Vignette', p: 1 }] }, { n: 'Color Effects', k: [] },
        { n: 'Convolution Kernel', k: [] }, { n: 'Lens Distortion Removal', k: [] }, { n: 'Mosaics', k: [] },
        { n: 'My Presets', k: [{ n: 'Film Grain', p: 1 }, { n: 'Glow + Shadow', p: 1 }, { n: 'Glow Pulse', p: 1 }, { n: 'Slide Up Text', p: 1 }, { n: 'True Drop Shadow', p: 1, id: 'tds' }] },
        { n: 'PiPs', k: [] }, { n: 'Solarizes', k: [] }, { n: 'Transitions', k: [{ n: 'Gaussian Blur Fade In', p: 1 }, { n: 'Gaussian Blur Fade Out', p: 1 }, { n: 'Glitch Reveal', p: 1 }, { n: 'Zoom In 120%', p: 1 }] }, { n: 'Twirls', k: [] }] },
      { n: 'Lumetri Presets', k: [] }, { n: 'Audio Effects', k: [] }, { n: 'Audio Transitions', k: [] },
      { n: 'Video Effects', k: [{ n: 'Adjust', k: [] }, { n: 'Blur & Sharpen', k: [] }, { n: 'Color Correction', k: [] }, { n: 'Distort', k: [] }, { n: 'Generate', k: [] }, { n: 'Image Control', k: [] }, { n: 'Keying', k: [] },
        { n: 'Noise & Grain', k: [] }, { n: 'Perspective', k: [{ n: 'Basic 3D', e: 1 }, { n: 'Drop Shadow', e: 1 }, { n: 'Long Shadow', e: 1 }] }, { n: 'Stylize', k: [] }, { n: 'Time', k: [] }, { n: 'Transform', k: [] }, { n: 'Utility', k: [] }, { n: 'Video', k: [] }] },
      { n: 'Video Transitions', k: [] }];
    var fxTree = q('.efx-tree'), fxField = q('.efx-field'), fxQ = q('.efx-field .q'), openBins = {}, fxQuery = '';
    function fxMatches(node, qq) { if (!qq) return true; if (node.k) return node.k.some(function (k) { return fxMatches(k, qq); }); return node.n.toLowerCase().indexOf(qq) >= 0; }
    function drawTree() {
      if (!fxTree) return;
      var h = '', qq = fxQuery.toLowerCase();
      (function walk(list, d, path) {
        list.forEach(function (node) {
          if (!fxMatches(node, qq)) return;
          var p = path + '/' + node.n, open = !!openBins[p];
          if (node.k) {
            h += '<div class="efr' + (open ? ' open' : '') + '" data-p="' + esc(p) + '" style="--d:' + d + '"><svg class="tw" viewBox="0 0 16 16">' + I.tw + '</svg>' + svg('folder', 'ic') + '<span>' + esc(node.n) + '</span></div>';
            if (open) walk(node.k, d + 1, p);
          } else {
            var nm = esc(node.n);
            if (qq) { var ix = node.n.toLowerCase().indexOf(qq); if (ix >= 0) nm = esc(node.n.slice(0, ix)) + '<span class="hit">' + esc(node.n.slice(ix, ix + qq.length)) + '</span>' + esc(node.n.slice(ix + qq.length)); }
            h += '<div class="efr leaf" data-p="' + esc(p) + '" style="--d:' + d + '"><i class="tw"></i>' + svg(node.p ? 'preset' : 'fxfilm', 'ic') + '<span>' + nm + '</span>'
              + (node.e ? '<span class="bd">' + svg('acc') + svg('b32') + svg('yuv') + '</span>' : '') + '</div>';
          }
        });
      })(tree, 0, '');
      fxTree.innerHTML = h;
    }
    drawTree();
    var FXA = {
      tab: function (which) {
        var fxOn = which === 'effects', pj = q('.pp-pj'); if (!pj) return;
        q('.t-pj').classList.toggle('on', !fxOn); q('.t-fx').classList.toggle('on', fxOn);
        q('.t-pj').innerHTML = 'Project: Short 01' + (fxOn ? '' : HAM); q('.t-fx').innerHTML = 'Effects' + (fxOn ? HAM : '');
        q('.pj-pane').hidden = fxOn; q('.efx-pane').hidden = !fxOn;
        q('.pj-pane').style.display = fxOn ? 'none' : 'flex'; q('.efx-pane').style.display = fxOn ? 'flex' : 'none';
      },
      focus: function (on) { fxField.classList.toggle('on', on); },
      type: function (text, each) {
        var i = 0;
        return new Promise(function (res) {
          (function next() { fxQuery = text.slice(0, i++); fxQ.textContent = fxQuery; drawTree(); if (i > text.length) { res(); return; } setTimeout(next, each || 130); })();
        });
      },
      clear: function () { fxQuery = ''; fxQ.textContent = ''; openBins = {}; drawTree(); FXA.focus(false); },
      open: function (p) { openBins[p] = true; drawTree(); },
      row: function (p) { return fxTree.querySelector('[data-p="' + p.replace(/"/g, '\\"') + '"]'); },
      hot: function (p, on) { var r = FXA.row(p); if (r) r.classList.toggle(on === 'pick' ? 'pick' : 'hot', !!on); },
      el: function (s) { return q(s); }
    };
    function drag(label, isPreset, on) {
      kdrag.innerHTML = svg(isPreset ? 'preset' : 'fxfilm') + '<span>' + esc(label) + '</span>';
      kdrag.classList.toggle('show', !!on);
    }
    function dropOn(id, on) { var el = clipEl(id); if (el) el.classList.toggle('drop', !!on); }

    // ---------- interactive: clicks on clips, the ruler, Space ----------
    if (o.interactive) {
      tlx.addEventListener('pointerdown', function (e) {
        if (e.button > 0) return;
        var cl = e.target.closest('.cl'), inRuler = e.target.closest('.tlx-rul');
        if (o.onTouch) o.onTouch();
        if (inRuler) { stop(); var r = lanes.V1.getBoundingClientRect(); seek((e.clientX - r.left) / (r.width / VIEW)); scrub = e.pointerId; return; }
        if (cl) { if (e.shiftKey || e.metaKey || e.ctrlKey || e.pointerType !== 'mouse') toggleSel(cl.dataset.id); else setSel([cl.dataset.id]); }
        else if (e.target.closest('.ln')) setSel([]);
      });
      var scrub = null;
      window.addEventListener('pointermove', function (e) { if (scrub === e.pointerId) { var r = lanes.V1.getBoundingClientRect(); seek((e.clientX - r.left) / (r.width / VIEW)); } });
      window.addEventListener('pointerup', function (e) { if (scrub === e.pointerId) scrub = null; });
      var mr = q('.mon-rul');
      if (mr) mr.addEventListener('pointerdown', function (e) { if (o.onTouch) o.onTouch(); var r = this.getBoundingClientRect(); stop(); seek((e.clientX - r.left) / r.width * SEQ); });
      if (playB) playB.addEventListener('click', function () { if (o.onTouch) o.onTouch(); if (playing) stop(); else play(); });
    }

    // ---------- reset, wake, layout ----------
    function reset(state) {
      stop(); P.close(); hideCursor(); khud.classList.remove('show'); kkeys.classList.remove('show');
      clips = fresh(); index(); undo = []; edited = false; root.classList.remove('edited');
      t = state && state.t !== undefined ? state.t : 3.2;
      if (state && state.sel) state.sel.forEach(function (id) { var c = byId[id]; if (c) { c.sel = true; if (c.link) byId[c.link].sel = true; } });
      if (fxTree) { FXA.clear(); FXA.tab(panel === 'effects' ? 'effects' : 'project'); }
      draw(); render();
    }
    if ('ResizeObserver' in window) new ResizeObserver(function () { draw(); }).observe(tlx); else window.addEventListener('resize', draw);

    Object.assign(api, {
      reset: reset, draw: draw, render: render, play: play, stop: stop, seek: seek, time: function () { return t; }, isPlaying: function () { return playing; },
      select: setSel, toggle: toggleSel, selected: selected, apply: apply, undo: doUndo, addAdjustment: addAdjustment, hud: hud, keys: keys,
      palette: P, effects: FXA, cursorTo: cursorTo, click: click, hideCursor: hideCursor, at: at, drag: drag, dropOn: dropOn, clipEl: clipEl, clip: function (id) { return byId[id]; },
      item: function (id) { return BY[id]; }, q: q, D: D,
      wake: function () { if (awake) return; awake = true; render(); sync(true); }
    });
    reset(o.state);
    return api;
  }

  window.KPR = { make: make, search: search, items: ITEMS, byId: BY, reduce: reduce, wait: wait };
})();
