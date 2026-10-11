/* The Premiere screens of the page and what plays on them:
   #before   the mouse way (the README's four steps: Open Effects, Search, Open the folder, Drag onto clips), ~11 s loop
   #after    the Khanjar way (⌘J, tds, Enter: True Drop Shadow on both titles), ~6 s loop
   #demo     a working copy you can drive (⌘J, type, Enter, ⌘Z, Space, clicks); plays by itself until you take over, ~33 s loop
   #shortcuts each shortcut played on Premiere, one after the other (~4.5 s each), or the one you click
   Every loop only runs while its screen is on screen. Reduced motion: still frames, nothing moves by itself. */
(function () {
  'use strict';
  var K = window.KPR; if (!K) return;
  var reduce = K.reduce;
  var touch = matchMedia('(hover: none) and (pointer: coarse)').matches;
  function $(s, r) { return (r || document).querySelector(s); }

  // ---- a stage: a fixed-size Premiere screen scaled into its .shot box; the layout follows the box's width ----
  function Stage(box, pick) {
    var st = { box: box, api: null, key: '', k: 1, onMake: null };
    var inner = document.createElement('div');
    box.appendChild(inner);
    st.fit = function () {
      var w = box.clientWidth; if (!w) return;
      var cfg = pick(w);
      if (!st.api || cfg.key !== st.key) {
        st.key = cfg.key; st.gen = (st.gen || 0) + 1;
        st.api = K.make(inner, cfg.opts);
        if (st.onMake) st.onMake(st.api);
      }
      var D = st.api.D, k = w / D.w; st.k = k;
      inner.style.transform = 'scale(' + k.toFixed(5) + ')';
      box.style.height = Math.round(D.h * k) + 'px';
      st.api.draw();
    };
    if ('ResizeObserver' in window) new ResizeObserver(function () { st.fit(); }).observe(box); else addEventListener('resize', st.fit);
    st.fit();
    return st;
  }

  // ---- a loop that only runs while its element is on screen; every step checks it is still wanted ----
  function Loop(el, body, opts) {
    opts = opts || {};
    var L = { on: false, run: 0 };
    L.alive = function (my) { return L.on && my === L.run; };
    L.wait = function (my, ms) { return new Promise(function (res, rej) { setTimeout(function () { L.alive(my) ? res() : rej('stop'); }, reduce ? 0 : ms); }); };
    L.start = function () {
      if (L.on || reduce) return;
      L.on = true; var my = ++L.run;
      (function go() {
        if (!L.alive(my)) return;
        Promise.resolve(body(my)).then(function () { if (L.alive(my)) setTimeout(go, 20); }, function () {});
      })();
    };
    L.stop = function () { if (!L.on) return; L.on = false; L.run++; if (opts.onStop) opts.onStop(); };
    if ('IntersectionObserver' in window) new IntersectionObserver(function (es) { es[0].isIntersecting ? (opts.canStart ? opts.canStart() && L.start() : L.start()) : L.stop(); }, { threshold: opts.threshold || .35 }).observe(el);
    document.addEventListener('visibilitychange', function () { if (document.hidden) L.stop(); });
    return L;
  }
  function beats(fig, i) { [].forEach.call(fig.querySelectorAll('[data-beats] li'), function (li, j) { li.classList.toggle('on', i === 'all' ? true : j === i); }); }

  var portKey = function (w) { return w < 560; };

  // ======================= #before: the mouse way =======================
  (function () {
    var fig = $('#before'), box = fig && $('.shot', fig); if (!box) return;
    var S = Stage(box, function (w) {
      var p = portKey(w);
      return { key: p ? 'p' : 's', opts: p ? { layout: 'port', panel: 'effects', size: { w: 430, h: 620, row1: 300 }, tracks: [['V4', 20], ['V3', 28], ['V2', 34], ['V1', 34], ['A1', 30], ['A3', 24]], state: { t: 1.2 } }
        : { layout: 'stage', panel: 'project', state: { t: 1.2 } } };
    });
    var TDS = K.byId.tds;
    function end() { var a = S.api; a.reset({ t: 1.2 }); a.effects.tab('effects'); a.effects.open('/Presets'); a.effects.open('/Presets/My Presets'); a.effects.type('drop', 0); a.apply(TDS, ['t1'], true); beats(fig, 'all'); }
    if (reduce) { end(); S.onMake = function () { end(); }; return; }
    var L = Loop(fig, async function (my) {
      var a = S.api, w = function (ms) { return L.wait(my, ms); }, port = S.key === 'p';
      a.reset({ t: 1.2 }); beats(fig, -1);
      if (!port) a.effects.tab('project');
      a.cursorTo({ x: a.D.w * .55, y: a.D.h * .72 }, 0); await w(700);
      // 1. Open Effects
      beats(fig, 0);
      if (!port) { await a.cursorTo(a.q('.t-fx'), 750); a.click(); await w(160); a.effects.tab('effects'); await w(450); }
      // 2. Search
      beats(fig, 1);
      await a.cursorTo(a.q('.efx-field'), 600); a.click(); a.effects.focus(true); await w(200);
      await a.effects.type('drop', 140); await w(450);
      // 3. Open the folder
      beats(fig, 2);
      await a.cursorTo(a.effects.row('/Presets'), 520); a.click(); await w(140); a.effects.open('/Presets'); await w(380);
      await a.cursorTo(a.effects.row('/Presets/My Presets'), 420); a.click(); await w(140); a.effects.open('/Presets/My Presets'); await w(420);
      // 4. Drag onto clips, one after the other
      beats(fig, 3);
      var row = '/Presets/My Presets/True Drop Shadow';
      for (var n = 0; n < 2; n++) {
        var id = n ? 't2' : 't1';
        await a.cursorTo(a.effects.row(row), n ? 700 : 450); a.effects.hot(row, 'pick'); a.click(); await w(180);
        a.drag('True Drop Shadow', true, true);
        await a.cursorTo(a.clipEl(id), 950); a.dropOn(id, true); await w(260);
        a.dropOn(id, false); a.drag('', true, false); a.effects.hot(row, false);
        a.apply(TDS, [id], 'flash'); await w(420);
      }
      await a.cursorTo({ x: a.D.w * .62, y: a.D.h * .45 }, 600);
      await w(1500);
    }, { onStop: function () { if (S.api) { S.api.hideCursor(); } } });
    S.onMake = function () { if (L.on) { L.stop(); L.start(); } };
  })();

  // ======================= #after: ⌘J, tds, Enter =======================
  (function () {
    var fig = $('#after'), box = fig && $('.shot', fig); if (!box) return;
    var S = Stage(box, function (w) {
      var p = portKey(w);
      return { key: p ? 'p' : 's', opts: p ? { layout: 'port', panel: null, size: { w: 430, h: 620, row1: 300 }, tracks: [['V4', 20], ['V3', 28], ['V2', 34], ['V1', 34], ['A1', 30], ['A3', 24]], state: { t: 1.2, sel: ['t1', 't2'] } }
        : { layout: 'stage', panel: 'project', state: { t: 1.2, sel: ['t1', 't2'] } } };
    });
    function end() { var a = S.api; a.reset({ t: 1.2, sel: ['t1', 't2'] }); a.palette.open(); a.palette.set('tds'); beats(fig, 'all'); }
    if (reduce) { end(); S.onMake = function () { end(); }; return; }
    var L = Loop(fig, async function (my) {
      var a = S.api, w = function (ms) { return L.wait(my, ms); };
      a.reset({ t: 1.2, sel: ['t1', 't2'] }); beats(fig, -1); await w(900);
      beats(fig, 0); a.keys(['⌘', 'J'], 650); await w(260); a.palette.open(); await w(900);
      beats(fig, 1); await a.palette.type('tds', 150); await w(650);
      beats(fig, 2); a.keys(['Enter'], 650); await w(240); a.palette.commit(); await w(2600);
    });
    S.onMake = function () { if (L.on) { L.stop(); L.start(); } };
  })();

  // ======================= #demo: drive it yourself =======================
  var demo = (function () {
    var box = $('#demo .shot'); if (!box) return null;
    var status = $('#demoStatus'), app = $('#app'), user = false, L = null;
    var START = { t: 3.2, sel: ['b1', 'b2', 'b3'] };
    var S = Stage(box, function (w) {
      var p = w < 700;
      return { key: p ? 'p' : 'w', opts: { layout: p ? 'port' : 'wide', panel: p ? null : 'project', interactive: true, focusInput: !touch, state: START,
        onTouch: function () { takeOver(); }, onApply: function (it, vids) { if (user) say(it.title + ' landed on ' + vids.length + ' clip' + (vids.length === 1 ? '' : 's') + '. ⌘Z takes it back.'); },
        onSelect: function (sel) { if (user) { var v = sel.filter(function (c) { return c.tr.charAt(0) === 'V'; }).length; say(v ? v + ' clip' + (v === 1 ? '' : 's') + ' selected. Press ⌘J.' : 'No clip selected. Click one in the timeline.'); } } } };
    });
    function say(t) { if (status) status.textContent = t; }
    function api() { return S.api; }
    // the footage only loads when the demo comes near
    if ('IntersectionObserver' in window) new IntersectionObserver(function (es) { if (es[0].isIntersecting) api().wake(); }, { rootMargin: '600px 0px' }).observe(box);
    else api().wake();
    S.onMake = function (a) { a.wake && setTimeout(function () { a.wake(); }, 0); if (L && L.on) { L.stop(); L.start(); } };

    function takeOver() {
      if (user) return false;
      user = true; if (L) L.stop();
      var a = api(); a.palette.close(); a.hideCursor(); a.reset(START);
      app.classList.add('user');
      say('Your turn. 3 clips selected: press ⌘J.');
      return true;
    }
    function inView() { var r = box.getBoundingClientRect(); return r.top < innerHeight * .85 && r.bottom > innerHeight * .15; }

    if (!reduce) L = Loop(box, async function (my) {
      var a = api(), w = function (ms) { return L.wait(my, ms); };
      a.reset(START); a.cursorTo({ x: a.D.w * .58, y: a.D.h * .9 }, 0); a.hideCursor(); await w(1000);
      // 1. three B-roll clips selected: Film Grain on all of them, then watch it play
      a.keys(['⌘', 'J']); await w(250); a.palette.open(); await w(1000);
      await a.palette.type('film', 140); await w(600);
      a.keys(['Enter']); await w(220); a.palette.commit(); await w(1300);
      a.keys(['Space']); a.seek(2.6); a.play(4.55); await w(2200);
      // 2. a preset comes off in two ⌘Z
      a.keys(['⌘', 'Z']); a.undo(); await w(650); a.keys(['⌘', 'Z']); a.undo(); await w(900); a.seek(3.2); await w(400);
      // 3. the two titles: True Drop Shadow from its initials
      await a.cursorTo(a.clipEl('t1'), 800); a.click(); a.select(['t1']); await w(450);
      await a.cursorTo(a.clipEl('t2'), 700); a.click(); a.toggle('t2'); await w(650); a.hideCursor();
      a.keys(['⌘', 'J']); await w(250); a.palette.open(); await w(800);
      await a.palette.type('tds', 150); await w(700);
      a.keys(['Enter']); await w(220); a.palette.commit(); await w(2200);
      // 4. your number one, without typing
      a.keys(['⌘', 'Z']); a.undo(); a.undo(); await w(700);
      a.keys(['⌘', 'J']); await w(250); a.palette.open(); await w(1300);
      a.keys(['⌘', '1']); await w(240); a.palette.direct(1); await w(2000);
      // 5. a duo: Slide Up Text → Glow + Shadow, and play it from the title's start
      a.keys(['⌘', 'Z']); a.undo(); a.undo(); await w(600);
      a.keys(['⌘', 'J']); await w(250); a.palette.open(); await w(900); a.palette.pick(1); await w(600);
      a.keys(['⌘', '2']); await w(240); a.palette.direct(2); await w(900);
      a.keys(['Space']); a.seek(.25); a.play(2.6); await w(2900);
      await w(1200);
    }, { threshold: .45, canStart: function () { return !user; } });

    // ---- the keyboard, as in Premiere with Khanjar running ----
    function open(fromKey) {
      var a = api(), fresh = takeOver();
      if (!inView()) box.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'center' });
      if (a.palette.isOpen() && !fresh) { a.palette.close(); return; }
      a.palette.open();
      if (fromKey) a.keys(['⌘', 'J'], 500);
    }
    addEventListener('keydown', function (e) {
      var a = api(), mod = e.metaKey || e.ctrlKey, k = (e.key || '').toLowerCase(), inInput = e.target && /input|textarea/i.test(e.target.tagName) && e.target !== a.palette.input;
      if (inInput) return;
      if (mod && !e.altKey && k === 'j') {
        e.preventDefault();
        if (e.shiftKey) { if (!inView()) return; takeOver(); a.keys(['⌘', '⇧', 'J'], 600); a.addAdjustment(); return; }
        // on the night (the hero or the last screen), the dagger strikes first, then the page cuts to the demo
        var night = [$('#top'), $('.final')].some(function (el) { if (!el) return false; var r = el.getBoundingClientRect(); return r.top < innerHeight * .6 && r.bottom > innerHeight * .4; });
        if (night && window.KhanjarWorld && !reduce) {
          heroKeys();
          window.KhanjarWorld.strike().then(function () { setTimeout(function () { open(false); }, 220); });
        } else open(true);
        return;
      }
      if (a.palette.isOpen()) {
        if (e.key === 'ArrowDown') { e.preventDefault(); takeOver(); a.palette.move(1); }
        else if (e.key === 'ArrowUp') { e.preventDefault(); takeOver(); a.palette.move(-1); }
        else if (e.key === 'Enter') { e.preventDefault(); takeOver(); a.palette.commit(); }
        else if (e.key === 'Escape') { e.preventDefault(); takeOver(); a.palette.close(); say('Closed. The timeline is untouched.'); }
        else if (mod && /^[0-9]$/.test(k)) { e.preventDefault(); takeOver(); a.palette.direct(+k); }
        else if (!mod && e.key.length === 1 && e.target !== a.palette.input) {
          e.preventDefault(); var fresh = takeOver(); if (fresh) a.palette.open();
          a.palette.input.value += e.key; a.palette.input.dispatchEvent(new Event('input')); try { a.palette.input.focus({ preventScroll: true }); } catch (x) {}
        } else if (e.target === a.palette.input) takeOver();
        return;
      }
      if (!inView()) return;
      if (mod && k === 'z' && !e.shiftKey) { e.preventDefault(); takeOver(); a.keys(['⌘', 'Z'], 500); if (!a.undo()) say('Nothing to undo.'); return; }
      if (e.key === ' ' && !(e.target.closest && e.target.closest('button,a,input,textarea,summary'))) { e.preventDefault(); takeOver(); a.isPlaying() ? a.stop() : (a.time() >= 11.9 && a.seek(0), a.play()); }
    });
    var ob = $('#openBtn'); if (ob) ob.addEventListener('click', function () { open(false); });
    var rb = $('#resetBtn'); if (rb) rb.addEventListener('click', function () { takeOver(); api().reset(START); say('Back to the start: 3 clips selected.'); });
    // the hero's keys light up when ⌘J is pressed there
    function heroKeys() {
      var ks = document.querySelectorAll('.how li:first-child kbd');
      [].forEach.call(ks, function (kb, i) { setTimeout(function () { kb.classList.add('hit'); setTimeout(function () { kb.classList.remove('hit'); }, 380); }, i * 90); });
    }
    return { api: api, takeOver: takeOver, isUser: function () { return user; } };
  })();
  window.KDemo = demo;

  // ======================= #shortcuts: each one played on Premiere =======================
  (function () {
    var box = $('#shortcuts .shot'), list = $('#klist'); if (!box || !list) return;
    var S = Stage(box, function (w) {
      var p = portKey(w);
      return { key: p ? 'p' : 's', opts: p ? { layout: 'port', panel: null, size: { w: 430, h: 560, row1: 268 }, tracks: [['V4', 18], ['V3', 24], ['V2', 30], ['V1', 30], ['A1', 26], ['A3', 18]], state: { t: 3.2 } }
        : { layout: 'stage', panel: 'project', state: { t: 3.2 } } };
    });
    var btns = [].slice.call(list.querySelectorAll('button'));
    var GS = K.byId.glowsh;
    // the Settings window's preset shortcuts, as Khanjar draws them (settings-dark.png)
    var set = document.createElement('div');
    set.className = 'ksettings'; set.setAttribute('aria-hidden', 'true');
    set.innerHTML = '<p class="ks-t">Preset shortcuts</p><p class="ks-s">One key → applies a preset to the selected clip (only in Premiere).</p>'
      + '<div class="ks-l"><p><b>^⌥G</b><span>Glow + Shadow</span><i></i></p><p><b>^⌥S</b><span>Slide Up Text</span><i></i></p><p><b>^⌥B</b><span>Gaussian Blur</span><i></i></p></div><span class="ks-b">Add a shortcut…</span>';
    box.appendChild(set);
    var SC = {
      open: async function (a, w) { a.reset({ t: 3.2, sel: ['b1', 'b2', 'b3'] }); await w(500); a.keys(['⌘', 'J']); await w(250); a.palette.open(); await w(2600); },
      search: async function (a, w) { a.reset({ t: 1.2, sel: ['t1', 't2'] }); a.palette.open(); await w(600); await a.palette.type('tds', 170); await w(2300); },
      apply: async function (a, w) {
        a.reset({ t: 5, sel: ['v1', 'v2'] }); a.palette.open(); a.palette.set('cine'); await w(1300);
        a.keys(['Enter']); await w(220); a.palette.commit(); await w(2600);
      },
      freq: async function (a, w) { a.reset({ t: 1.2, sel: ['t1', 't2'] }); await w(400); a.keys(['⌘', 'J']); await w(250); a.palette.open(); await w(1400); a.keys(['⌘', '1']); await w(240); a.palette.direct(1); await w(2400); },
      undo: async function (a, w) {
        a.reset({ t: 1.2, sel: ['t1', 't2'] }); a.apply(GS, null, true); await w(1100);
        a.keys(['⌘', 'Z']); a.undo(); await w(1000); a.keys(['⌘', 'Z']); a.undo(); await w(1900);
      },
      adj: async function (a, w) {
        a.reset({ t: 3.2 }); await w(600); a.keys(['⌘', '⇧', 'J']); await w(240); a.addAdjustment(); await w(1500);
        a.keys(['⌘', 'J']); await w(250); a.palette.open(); await w(400); await a.palette.type('black', 120); await w(500);
        a.keys(['Enter']); await w(220); a.palette.commit(); await w(2200);
      },
      esc: async function (a, w) { a.reset({ t: 3.2, sel: ['b1', 'b2', 'b3'] }); a.palette.open(); await a.palette.type('glo', 150); await w(900); a.keys(['esc']); await w(220); a.palette.close(); await w(2000); },
      own: async function (a, w) {
        a.reset({ t: 1.2, sel: ['t1', 't2'] }); set.classList.add('show'); await w(2000); set.classList.remove('show'); await w(500);
        a.keys(['⌃', '⌥', 'G']); await w(260); a.apply(GS); await w(2400);
      }
    };
    var cur = 0, playing = false, picked = false;
    function mark(i) { btns.forEach(function (b, j) { b.classList.toggle('on', j === i); b.setAttribute('aria-pressed', String(j === i)); }); }
    var L = Loop(box, async function (my) {
      var w = function (ms) { return L.wait(my, ms); };
      mark(cur); set.classList.remove('show');
      await SC[btns[cur].dataset.k](S.api, w);
      await w(500);
      cur = (cur + 1) % btns.length;
    }, { threshold: .4, onStop: function () { set.classList.remove('show'); } });
    btns.forEach(function (b, i) {
      b.addEventListener('click', function () {
        cur = i; mark(i);
        if (reduce) { SC[b.dataset.k](S.api, function () { return Promise.resolve(); }); return; }
        L.stop(); L.start();
        if (innerWidth <= 1000) { var r = box.getBoundingClientRect(); if (r.top < 0 || r.bottom > innerHeight) box.scrollIntoView({ behavior: 'smooth', block: 'nearest' }); }
      });
    });
    S.onMake = function () { if (L.on) { L.stop(); L.start(); } };
    if (reduce) { mark(2); SC.apply(S.api, function () { return Promise.resolve(); }); }
    else mark(0);
  })();
})();
