/* Profile — System Monitor. Small vanilla JS, no libraries.
   Without JS the page is the static Profile
   sheet; Resources still renders server-side and is reached via #resources (:target).

   Data: the feed embedded in <script id="cl-stats">. Drawn once on load; not refreshed.

   URL hash: #profile | #resources | #status picks a tab (plain links work too);
   range=7d starts the history graph on the 7-day range. */
(() => {
  'use strict';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const NS = 'http://www.w3.org/2000/svg';
  const el = (tag, attrs, parent, svg) => {
    const e = svg ? document.createElementNS(NS, tag) : document.createElement(tag);
    for (const k in attrs) k === 'text' ? (e.textContent = attrs[k]) : e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  };
  const set = (id, v) => { $('#' + id).textContent = v; };
  // 4477200 -> "4.5M", 182300 -> "182k", 4710 -> "4.7k"
  const fmt = n => n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e4 ? Math.round(n / 1e3) + 'k'
    : n >= 1e3 ? (n / 1e3).toFixed(1) + 'k' : String(n);
  const WD = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const TABS = ['profile', 'resources', 'status'].filter(n => document.getElementById(n));   // panels exist only when their upstreams have data

  const data = JSON.parse($('#cl-stats').textContent);
  let m = null;                       // derived view of `data`, rebuilt on every render
  let range = 'today';

  function derive(d) {
    const T = d.tokens;
    if (!T) return null;                                            // magpie has no data: no Resources panel
    const H = T.hourly, D = T.daily;
    const hCache = H.cacheRead.map((v, i) => v + H.cacheWrite[i]);
    const dCache = D.cacheRead.map((v, i) => v == null ? null : v + D.cacheWrite[i]);
    const hourTot = H.input.map((v, i) => v + hCache[i] + H.output[i]);
    const dayTot = D.input.map((v, i) => v == null ? null : v + dCache[i] + D.output[i]);
    let last = dayTot.length - 1; while (last > 0 && dayTot[last] == null) last--;   // index of "today"
    return {
      T, hourTot, dayTot, last,
      H0: parseInt(T.hourly.start.slice(11, 13), 10),
      nowAt: (Date.parse(d.generatedAt) - Date.parse(T.hourly.start)) / 36e5,   // hours past local midnight at snapshot
    };
  }
  const hourLabel = i => String((m.H0 + i) % 24).padStart(2, '0') + ':00';
  // dates are read as plain calendar values so the viewer's own time zone never shifts them
  const dayAt = i => new Date(Date.parse(m.T.daily.start + 'T00:00:00Z') + i * 864e5);
  const dayLabel = d => `${WD[d.getUTCDay()]} ${String(d.getUTCDate()).padStart(2, '0')}`;
  const iso = d => d.toISOString().slice(0, 10);

  function renderStatus() {
    const svg = $('#spark'), W = 72, H = 24, mx = Math.max(1, ...m.hourTot);
    svg.textContent = '';
    const pts = m.hourTot.map((v, i) => `${(i * W / (m.hourTot.length - 1)).toFixed(1)},${(H - 1 - v / mx * (H - 4)).toFixed(1)}`).join(' ');
    el('polygon', { points: `0,${H} ${pts} ${W},${H}`, class: 'sp-a' }, svg, 1);
    el('polyline', { points: pts, class: 'sp-l' }, svg, 1);
  }

  /* ---------- notebook tabs (ARIA tabs, automatic activation, hash = tab) ---------- */
  function selectTab(name, focus) {
    TABS.forEach(n => {
      const on = n === name, tab = $('#tab-' + n);
      tab.setAttribute('aria-selected', on);
      tab.tabIndex = on ? 0 : -1;
      $('#' + n).classList.toggle('on', on);
    });
    if (focus) $('#tab-' + name).focus();
    if (name === 'resources') drawGraph();                       // needs a laid-out width
  }
  TABS.forEach((n, i) => {
    const tab = $('#tab-' + n);
    tab.addEventListener('click', () => { selectTab(n); setHash(n); });
    tab.addEventListener('keydown', e => {
      const to = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: TABS.length - 1 }[e.key];
      if (to === undefined) return;
      e.preventDefault();
      const next = TABS[(to + TABS.length) % TABS.length];
      selectTab(next, true); setHash(next);
    });
  });
  const setHash = n => history.replaceState(null, '', '#' + n);   // no history spam, no scroll jump
  function applyHash() {
    const o = {};
    location.hash.slice(1).split('&').forEach(t => { const [k, v] = t.split('='); if (v === undefined) o.tab = k; else o[k] = v; });
    if (TABS.includes(o.tab)) selectTab(o.tab);
    else if (o.tab) {                    // e.g. #main or #h-who: show the panel that holds it
      const t = document.getElementById(o.tab), p = t && t.closest('[role=tabpanel]');
      if (p) selectTab(p.id);
    }
    return o;
  }
  window.addEventListener('hashchange', applyHash);

  /* ---------- Resources: history graph (SVG, redrawn on resize / range change) ---------- */
  const niceStep = v => { const p = 10 ** Math.floor(Math.log10(v)); return p * [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].find(k => k * p >= v); };
  function series() {
    const { last } = m;
    if (range === 'today') return { total: m.hourTot, label: hourLabel, step: 3,
      cap: 'tokens by hour, today', now: m.nowAt };
    const a = Math.max(0, last - 6), cut = arr => arr.slice(a, last + 1);
    return { total: cut(m.dayTot), step: 1,
      label: i => dayLabel(dayAt(a + i)), cap: 'tokens per day, last 7 days' };
  }
  function drawGraph() {
    const svg = $('#graph');
    if (!svg || !m) return;                                         // no panel: magpie has no data
    const W = svg.clientWidth, H = svg.clientHeight;
    if (!W) return;                                                 // panel hidden
    const s = series(), n = s.total.length;
    const L = 46, R = 12, TOP = 8, B = 22, pw = W - L - R, ph = H - TOP - B;
    const total = s.total;
    const step = niceStep(Math.max(1, ...total) / 4), max = step * 4;
    const x = i => L + i * pw / (n - 1), y = v => TOP + ph - v / max * ph;
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
    svg.textContent = '';
    el('rect', { x: L + .5, y: TOP + .5, width: pw, height: ph, class: 'g-plot' }, svg, 1);
    for (let g = 0; g <= 4; g++) {                                  // horizontal grid + y labels
      const gy = Math.round(TOP + ph * g / 4) + .5;
      if (g && g < 4) el('line', { x1: L, x2: L + pw, y1: gy, y2: gy, class: 'g-grid' }, svg, 1);
      el('text', { x: L - 6, y: gy + 4, 'text-anchor': 'end', class: 'g-ax', text: fmt(max * (4 - g) / 4) }, svg, 1);
    }
    const every = s.step * (W < 520 && n > 12 ? 2 : 1);             // fewer x labels when narrow
    for (let i = 0; i < n; i++) {
      if (i % every) continue;
      const gx = Math.round(x(i)) + .5;
      if (i) el('line', { x1: gx, x2: gx, y1: TOP, y2: TOP + ph, class: 'g-grid' }, svg, 1);
      el('text', { x: gx, y: H - 6, 'text-anchor': !i ? 'start' : i === n - 1 ? 'end' : 'middle', class: 'g-ax', text: s.label(i) }, svg, 1);
    }
    const at = arr => arr.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`);
    const points = arr => at(arr).join(' ');
    const path = points(total);
    el('polygon', { points: `${L},${TOP + ph} ${path} ${L + pw},${TOP + ph}`, class: 'a-total' }, svg, 1);
    el('polyline', { points: path, class: 'l-total' }, svg, 1);
    el('circle', { cx: x(n - 1), cy: y(total[n - 1]), r: 3, class: 'd-total' }, svg, 1);
    if (s.now >= 0 && s.now <= n - 1) {                             // today: the snapshot's place in the day
      const nx = x(s.now), end = s.now > (n - 1) / 2;
      el('line', { x1: nx, x2: nx, y1: TOP, y2: TOP + ph, class: 'g-now' }, svg, 1);
      el('text', { x: end ? nx - 4 : nx + 4, y: TOP + 11, 'text-anchor': end ? 'end' : 'start', class: 'g-ax', text: 'now' }, svg, 1);
    }
    for (let i = 0; i < n; i++) {                                    // hover strips with native tooltips
      const w = pw / (n - 1);
      const hit = el('rect', { x: Math.max(L, x(i) - w / 2), y: TOP, width: w / (i && i < n - 1 ? 1 : 2), height: ph, class: 'g-hit' }, svg, 1);
      el('title', { text: `${s.label(i)}: ${fmt(total[i])} tokens` }, hit, 1);
    }
    set('graph-cap', s.cap);
    svg.setAttribute('aria-label', `${s.cap}, one line of all tokens. the total peaks at ${fmt(Math.max(...total))}.`);
  }
  $$('[data-range]').forEach(b => b.addEventListener('click', () => {
    range = b.dataset.range;
    $$('[data-range]').forEach(o => o.setAttribute('aria-pressed', o === b));
    drawGraph();
  }));
  let resizeTimer;
  window.addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(drawGraph, 120); });

  /* ---------- Resources: 16-week heatmap (columns = weeks, Mon..Sun) ---------- */
  function renderHeat() {
    const { dayTot } = m, heat = $('#heat');
    const hmax = Math.max(0, ...dayTot.filter(v => v != null));
    heat.textContent = '';
    ['', 'Mon', '', 'Wed', '', 'Fri', '', ''].forEach(t => el('span', t ? { class: 'dl', text: t } : {}, heat));
    dayTot.forEach((v, i) => {
      const d = dayAt(i);
      if (i % 7 === 0) {                                             // month label above each week column
        const mo = d.getUTCMonth(), show = i === 0 || mo !== dayAt(i - 7).getUTCMonth();
        el('span', { class: 'hm', text: show ? MON[mo] : '' }, heat);
      }
      const lvl = v == null ? 'fut' : 'l' + (hmax ? Math.min(4, Math.ceil(v / hmax * 4)) : 0);
      const label = `${WD[d.getUTCDay()]} ${iso(d)}: ${v == null ? 'not yet' : fmt(v) + ' tokens'}`;
      el('span', { class: 'hc ' + lvl, title: label, 'data-label': label }, heat);
    });
    const best = dayTot.indexOf(hmax);
    heat.setAttribute('aria-label', `token activity per day for 16 weeks. busiest day ${iso(dayAt(best))} with ${fmt(hmax)} tokens; today ${fmt(dayTot[m.last])}.`);
  }
  $('#heat')?.addEventListener('mouseover', e => { if (e.target.dataset.label) set('heat-read', e.target.dataset.label); });

  /* ---------- render everything from the current feed ---------- */
  function render() {
    m = derive(data);
    if (!m || !$('#resources')) return;                             // magpie has no data: no panel to draw
    renderStatus(); renderHeat(); drawGraph();
  }

  /* ---------- window controls: minimise / maximise / close ---------- */
  const win = $('.window'), dlg = $('#quit-dlg'), info = $('#infobar');
  const bMin = $('.wm .min'), bMax = $('.wm .max'), bCls = $('.wm .cls');
  $$('.wm button').forEach(b => { b.disabled = false; });
  function minimise(on) {                    // window -> task chip on a GNOME 2 bottom panel, and back
    win.hidden = on; $('#gpanel').hidden = !on; $('#desk-note').hidden = !on;
    (on ? $('#taskchip') : bMin).focus();
  }
  function maximise(on) { win.classList.toggle('wide', on); bMax.setAttribute('aria-pressed', on); drawGraph(); }
  bMin.addEventListener('click', () => minimise(true));
  $('#taskchip').addEventListener('click', () => minimise(false));
  bMax.addEventListener('click', () => maximise(bMax.getAttribute('aria-pressed') !== 'true'));
  // <dialog>.showModal() makes the page inert (focus trap) and Esc cancels; we restore focus on close
  bCls.addEventListener('click', () => { dlg.returnValue = ''; dlg.showModal(); });
  dlg.addEventListener('close', () => {
    if (dlg.returnValue === 'quit') { info.hidden = false; $('#info-ok').focus(); } else bCls.focus();
  });
  $('#info-ok').addEventListener('click', () => { info.hidden = true; bCls.focus(); });

  /* ---------- start: hash picks tab and range ---------- */
  render();
  const o = applyHash();
  if (o.range === '7d') $('[data-range="7d"]')?.click();
})();
