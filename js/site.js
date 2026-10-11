/* The page around the demos: the nav, things that appear as you scroll, the Claude Code lines, copying the prompt. */
(function () {
  'use strict';
  var reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  var $ = function (s) { return document.querySelector(s); };
  document.documentElement.classList.add('js');

  // the nav turns solid as soon as the page scrolls
  var nav = $('#nav');
  if (nav) { var solid = function () { nav.classList.toggle('solid', scrollY > 40); }; addEventListener('scroll', solid, { passive: true }); solid(); }

  // "Try it": the dagger strikes, then the page cuts to the demo
  var tryBtn = $('#tryBtn');
  if (tryBtn) tryBtn.addEventListener('click', function (e) {
    var demo = $('#demo'); if (!demo) return;
    e.preventDefault();
    var go = function () { demo.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'start' }); history.replaceState(null, '', '#demo'); };
    if (window.KhanjarWorld && !reduce) window.KhanjarWorld.strike().then(function () { setTimeout(go, 160); }); else go();
  });

  // section headings and blocks rise in, once
  var rv = [].slice.call(document.querySelectorAll('.sec-head, .way, .screen, .klist, .usage-copy, .facts-list, .limits, .steps, .install-side, .cl-head, .cc-win, .cl-prompt, .qa'));
  rv.forEach(function (el) { el.classList.add('rv'); });
  if (reduce || !('IntersectionObserver' in window)) rv.forEach(function (el) { el.classList.add('in'); });
  else {
    var io = new IntersectionObserver(function (es) { es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }); }, { rootMargin: '0px 0px -8% 0px', threshold: .06 });
    rv.forEach(function (el) { io.observe(el); });
  }

  // the usage chart grows when it comes into view
  var chart = $('#chart');
  if (chart) {
    if (reduce || !('IntersectionObserver' in window)) chart.classList.add('in');
    else { var cio = new IntersectionObserver(function (es) { if (es[0].isIntersecting) { chart.classList.add('in'); cio.disconnect(); } }, { threshold: .35 }); cio.observe(chart); }
  }

  // Claude Code: the lines of the install appear one by one, as they would in the terminal
  var lines = [].slice.call(document.querySelectorAll('#cc-body .cc-line'));
  if (reduce || !('IntersectionObserver' in window)) lines.forEach(function (l) { l.classList.add('on'); });
  else {
    var ccio = new IntersectionObserver(function (es) {
      if (!es[0].isIntersecting) return;
      ccio.disconnect();
      lines.forEach(function (l, i) { setTimeout(function () { l.classList.add('on'); }, 300 + i * 520); });
    }, { threshold: .3 });
    var body = $('#cc-body'); if (body) ccio.observe(body);
  }

  // copy the prompt; if the clipboard is refused, select it so ⌘C works
  var btn = $('#copy'), pre = $('#prompt-text');
  if (btn && pre) btn.addEventListener('click', function () {
    var done = function (ok) { btn.textContent = ok ? 'Copied' : 'Press ⌘C to copy'; clearTimeout(btn.t); btn.t = setTimeout(function () { btn.textContent = 'Copy prompt'; }, 2000); };
    var select = function () { var r = document.createRange(); r.selectNodeContents(pre); var s = getSelection(); s.removeAllRanges(); s.addRange(r); pre.focus(); };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(pre.textContent).then(function () { done(true); }, function () { select(); done(false); });
    else { select(); done(false); }
  });
})();
