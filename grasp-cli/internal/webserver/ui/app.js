'use strict';
/* grasp canvas: a whiteboard of function cards. Cards stay where you put
   them; a new card opens beside the card it was opened from. Drag headers to
   move cards, the background to pan, ⌘+wheel to zoom. Sessions persist the
   whole arrangement server-side. */

const $ = s => document.querySelector(s);
const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const CARD_W = 620, GAP_X = 70, GAP_Y = 30, EST_H = 320;

let IDX = null, byId = new Map(), callersOf = new Map(), COMMENTS = { threads: [] }, CFG = {};
let S = null;                 // session: {name, cards: Map, edges: [], focus, pan, zoom}
let heights = new Map();      // card id -> measured px height
let sigMode = false;
let composing = null;         // {fnId, file, line, endLine, side}
let allModulesShown = false;
let zTop = 10;
let spaceHeld = false;

function emptySession(name) {
  return { name, cards: new Map(), edges: [], focus: null, pan: { x: 0, y: 0 }, zoom: 1 };
}

// ---------- data ----------
async function loadAll(keep) {
  const [ir, cr, gr] = await Promise.all([fetch('/api/index'), fetch('/api/comments'), fetch('/api/config')]);
  if (!ir.ok) { $('#hint').innerHTML = esc(await ir.text()); return false; }
  IDX = await ir.json();
  COMMENTS = cr.ok ? await cr.json() : { threads: [] };
  CFG = gr.ok ? await gr.json() : {};
  byId = new Map(IDX.functions.map(f => [f.id, f]));
  callersOf = new Map();
  for (const f of IDX.functions)
    for (const c of f.calls) {
      if (!callersOf.has(c.target)) callersOf.set(c.target, []);
      callersOf.get(c.target).push({ from: f.id, call: c });
    }
  if (keep && S) {
    for (const id of [...S.cards.keys()]) if (!byId.has(id)) S.cards.delete(id);
    S.edges = S.edges.filter(e => S.cards.has(e.from) && S.cards.has(e.to));
  }
  renderHeader(); renderSidebar();
  return true;
}

function changedFns() { return IDX.functions.filter(f => f.change !== 'unchanged'); }

// ---------- sessions ----------
function defaultSessionName() {
  const q = new URLSearchParams(location.search).get('s');
  if (q) return q;
  if (IDX.review && IDX.review.pr) return 'pr-' + IDX.review.pr;
  return 'default';
}

async function loadSession(name) {
  S = emptySession(name);
  try {
    const r = await fetch('/api/sessions/' + encodeURIComponent(name));
    if (r.ok) {
      const doc = await r.json();
      for (const c of doc.cards || []) if (byId.has(c.id)) S.cards.set(c.id, { x: c.x, y: c.y, view: c.view || 'source', fold: !!c.fold, collapsed: !!c.collapsed, root: !!c.root, expanded: new Set() });
      S.edges = (doc.edges || []).filter(e => S.cards.has(e.from) && S.cards.has(e.to));
      S.focus = doc.focus && S.cards.has(doc.focus) ? doc.focus : null;
      if (doc.pan) S.pan = doc.pan;
      if (doc.zoom) S.zoom = doc.zoom;
    }
  } catch { /* fresh session */ }
  const url = new URL(location);
  if (name === 'default') url.searchParams.delete('s'); else url.searchParams.set('s', name);
  history.replaceState(null, '', url);
  if (S.cards.size === 0) autoOpenChanges();
  renderCanvas();
  applyTransform();
  await refreshSessionList();
}

let saveTimer = null;
function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveSession, 700);
}
async function saveSession() {
  if (!S) return;
  const doc = {
    cards: [...S.cards.entries()].map(([id, c]) => ({ id, x: Math.round(c.x), y: Math.round(c.y), view: c.view, fold: c.fold, collapsed: c.collapsed, root: c.root })),
    edges: S.edges, focus: S.focus, pan: { x: Math.round(S.pan.x), y: Math.round(S.pan.y) }, zoom: S.zoom,
  };
  await fetch('/api/sessions/' + encodeURIComponent(S.name), { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(doc) }).catch(() => {});
}

async function refreshSessionList() {
  let names = [];
  try { names = (await (await fetch('/api/sessions')).json()).sessions || []; } catch { /* none */ }
  if (!names.includes(S.name)) names.unshift(S.name);
  const sel = $('#sessionSel');
  sel.innerHTML = names.map(n => '<option' + (n === S.name ? ' selected' : '') + '>' + esc(n) + '</option>').join('') +
    '<option value="__new">new session…</option><option value="__del">delete this session</option>';
}

$('#sessionSel').addEventListener('change', async () => {
  const v = $('#sessionSel').value;
  if (v === '__new') {
    const name = prompt('session name (letters, digits, - and _):');
    await refreshSessionList();
    if (name && /^[A-Za-z0-9_-]{1,40}$/.test(name)) { await saveSession(); await loadSession(name); }
    return;
  }
  if (v === '__del') {
    await fetch('/api/sessions/' + encodeURIComponent(S.name), { method: 'DELETE' });
    await loadSession('default');
    return;
  }
  if (v !== S.name) { await saveSession(); await loadSession(v); }
});

// Open every changed function as a card, one column per module, modified
// cards showing their diff — the canvas a review starts from.
function autoOpenChanges() {
  const ch = changedFns().slice(0, 24);
  if (ch.length === 0) return;
  const mods = new Map();
  for (const f of ch) { if (!mods.has(f.module)) mods.set(f.module, []); mods.get(f.module).push(f); }
  let col = 0;
  for (const [, fns] of mods) {
    let y = 40;
    for (const f of fns) {
      S.cards.set(f.id, { x: 40 + col * (CARD_W + GAP_X), y, view: f.base_source != null ? 'diff' : 'source', fold: false, collapsed: false, root: true, expanded: new Set() });
      y += EST_H + GAP_Y;
    }
    col++;
  }
  for (const f of ch)
    for (const c of f.calls)
      if (S.cards.has(c.target) && c.target !== f.id && !S.edges.some(e => e.from === f.id && e.to === c.target))
        S.edges.push({ from: f.id, to: c.target, key: c.target + '@' + c.range.start[0] + ':' + c.range.start[1] });
  S.focus = ch[0].id;
  // restack with real heights once rendered
  requestAnimationFrame(() => requestAnimationFrame(() => { restackColumns(); scheduleSave(); }));
}

function restackColumns() {
  const cols = new Map();
  for (const [id, c] of S.cards) {
    const key = Math.round(c.x);
    if (!cols.has(key)) cols.set(key, []);
    cols.get(key).push([id, c]);
  }
  for (const [, list] of cols) {
    list.sort((a, b) => a[1].y - b[1].y);
    let y = 40;
    for (const [id, c] of list) { c.y = y; y += (heights.get(id) || EST_H) + GAP_Y; }
  }
  renderCanvas();
}

// ---------- header ----------
function renderHeader() {
  $('#project').textContent = IDX.project.app;
  const g = IDX.git || {};
  const base = (g.base_ref || '').replace(/^origin\//, '');
  $('#reviewline').textContent = base ? base + '…' + (g.branch === 'HEAD' ? (g.head || '').slice(0, 8) : g.branch) : '';
  const pr = IDX.review;
  const a = $('#prlink');
  if (pr && pr.pr) { a.textContent = '#' + pr.pr + ' ' + (pr.title || ''); a.href = pr.url || '#'; } else { a.textContent = ''; }
  $('#counts').textContent = changedFns().length + ' changed · ' + IDX.functions.length + ' functions';
}

// ---------- sidebar ----------
function renderSidebar() {
  const ch = changedFns();
  const chGroups = groupBy(ch, f => f.module);
  $('#changes').innerHTML = ch.length === 0 ? '<div class="side-empty">no changes against the base</div>'
    : [...chGroups.entries()].map(([mod, fns]) =>
        '<div class="side-mod"><div class="side-modlabel">' + esc(mod) + '</div>' + fns.map(sideFn).join('') + '</div>').join('');

  const openThreads = COMMENTS.threads.filter(t => !t.resolved);
  $('#commentsList').innerHTML = openThreads.length === 0 ? '<div class="side-empty">none open</div>'
    : openThreads.map(t => {
        const first = (t.comments[0] && t.comments[0].body || '').slice(0, 48);
        return '<div class="side-cmt" data-fn="' + esc(t.function) + '"><span class="loc">' + esc(t.file.split('/').pop() + ':' + t.line) + '</span> ' + esc(first) + '</div>';
      }).join('');

  // Related: modules the change touches one hop away — callers into and
  // callees out of the changed functions.
  const changedIds = new Set(ch.map(f => f.id));
  const changedMods = new Set(ch.map(f => f.module));
  const related = new Map();
  const addRel = f => {
    if (!f || changedIds.has(f.id) || changedMods.has(f.module)) return;
    if (!related.has(f.module)) related.set(f.module, new Map());
    related.get(f.module).set(f.id, f);
  };
  for (const f of ch) for (const c of f.calls) addRel(byId.get(c.target));
  for (const id of changedIds) for (const caller of (callersOf.get(id) || [])) addRel(byId.get(caller.from));
  $('#related').innerHTML = related.size === 0 ? '<div class="side-empty">nothing adjacent</div>'
    : [...related.entries()].map(([mod, fns]) =>
        '<details class="side-mod"><summary>' + esc(mod) + ' <span style="color:var(--dim)">(' + fns.size + ')</span></summary>' +
        [...fns.values()].map(sideFn).join('') + '</details>').join('');

  const modsEl = $('#modules');
  if (allModulesShown) {
    const mods = groupBy(IDX.functions, f => f.module);
    modsEl.innerHTML = [...mods.entries()].map(([mod, fns]) =>
      '<details class="side-mod"><summary>' + esc(mod) + ' <span style="color:var(--dim)">(' + fns.length + ')</span></summary>' +
      fns.map(sideFn).join('') + '</details>').join('');
    $('#allModulesBtn').textContent = 'hide the full module list';
  } else {
    modsEl.innerHTML = '';
    $('#allModulesBtn').textContent = 'show all modules (' + new Set(IDX.functions.map(f => f.module)).size + ')';
  }

  document.querySelectorAll('.side-fn').forEach(el => el.addEventListener('click', () => openCard(el.dataset.id, {})));
  document.querySelectorAll('.side-cmt').forEach(el => el.addEventListener('click', () => openCard(el.dataset.fn, {})));
  applyFilter();
}

function sideFn(f) {
  return '<div class="side-fn" data-id="' + esc(f.id) + '"><span class="badge ' + f.change + '">' +
    f.change[0].toUpperCase() + '</span><span>' + esc(f.name) + '<span style="color:var(--dim)">/' + f.arity + '</span></span></div>';
}

function groupBy(list, key) {
  const m = new Map();
  for (const it of list) { const k = key(it); if (!m.has(k)) m.set(k, []); m.get(k).push(it); }
  return m;
}

$('#filter').addEventListener('input', applyFilter);
function applyFilter() {
  const q = $('#filter').value.toLowerCase();
  document.querySelectorAll('.side-fn').forEach(el => { el.hidden = q !== '' && !el.dataset.id.toLowerCase().includes(q); });
  document.querySelectorAll('#sidebar details, #changes .side-mod').forEach(d => {
    const any = [...d.querySelectorAll('.side-fn')].some(el => !el.hidden);
    d.style.display = any ? '' : 'none';
    if (q !== '' && d.tagName === 'DETAILS') d.open = true;
  });
}
$('#allModulesBtn').addEventListener('click', () => { allModulesShown = !allModulesShown; renderSidebar(); });

// ---------- canvas ----------
function applyTransform() {
  $('#world').style.transform = 'translate(' + S.pan.x + 'px,' + S.pan.y + 'px) scale(' + S.zoom + ')';
  $('#zoomLabel').textContent = Math.round(S.zoom * 100) + '%';
}

function openCard(id, { fromId, key, side }) {
  if (!byId.has(id)) return;
  setFocus(id);
  if (S.cards.has(id)) {
    if (fromId && !S.edges.some(e => e.from === fromId && e.to === id)) S.edges.push({ from: fromId, to: id, key });
    renderCanvas();
    const el = cardEl(id); if (el) el.classList.add('flash');
    ensureVisible(id);
    scheduleSave();
    return;
  }
  const fn = byId.get(id);
  const pos = place(fromId, side);
  S.cards.set(id, { x: pos.x, y: pos.y, view: 'source', fold: false, collapsed: false, root: !fromId, expanded: new Set() });
  if (fromId) S.edges.push({ from: side === 'left' ? id : fromId, to: side === 'left' ? fromId : id, key });
  renderCanvas();
  ensureVisible(id);
  scheduleSave();
}

// place beside the opener, in the first clear space there.
function place(fromId, side) {
  if (!fromId || !S.cards.has(fromId)) {
    let y = 40;
    for (const [id, c] of S.cards) if (c.x < 40 + CARD_W) y = Math.max(y, c.y + (heights.get(id) || EST_H) + GAP_Y);
    return { x: 40, y };
  }
  const from = S.cards.get(fromId);
  const x = side === 'left' ? from.x - CARD_W - GAP_X : from.x + CARD_W + GAP_X;
  let y = from.y;
  const collides = yy => [...S.cards.entries()].some(([id, c]) =>
    Math.abs(c.x - x) < CARD_W && yy < c.y + (heights.get(id) || EST_H) + 10 && yy + EST_H > c.y - 10);
  let guard = 0;
  while (collides(y) && guard++ < 200) y += 60;
  return { x, y };
}

function closeCard(id, subtree) {
  S.cards.delete(id);
  S.edges = S.edges.filter(e => e.from !== id && e.to !== id);
  if (subtree) {
    // keep what a root still reaches; everything else had no other way in.
    const reach = new Set();
    const walk = i => { if (reach.has(i)) return; reach.add(i); for (const e of S.edges) if (e.from === i) walk(e.to); };
    for (const [i, c] of S.cards) if (c.root) walk(i);
    for (const i of [...S.cards.keys()]) if (!reach.has(i)) { S.cards.delete(i); }
    S.edges = S.edges.filter(e => S.cards.has(e.from) && S.cards.has(e.to));
  }
  if (S.focus === id) S.focus = [...S.cards.keys()].pop() || null;
  renderCanvas();
  scheduleSave();
}

function setFocus(id) {
  S.focus = id;
  document.querySelectorAll('.card.focused').forEach(c => c.classList.remove('focused'));
  const el = cardEl(id);
  if (el) { el.classList.add('focused'); el.style.zIndex = ++zTop; }
}

function cardEl(id) { return document.querySelector('.card[data-id="' + CSS.escape(id) + '"]'); }

function renderCanvas() {
  const world = $('#world');
  world.querySelectorAll('.card').forEach(el => el.remove());
  $('#hint').style.display = S.cards.size === 0 ? '' : 'none';
  for (const [id] of S.cards) world.appendChild(buildCard(byId.get(id)));
  requestAnimationFrame(() => {
    for (const [id] of S.cards) { const el = cardEl(id); if (el) heights.set(id, el.offsetHeight); }
    drawEdges();
  });
}

function ensureVisible(id) {
  const c = S.cards.get(id);
  if (!c) return;
  const vp = $('#viewport'), vw = vp.clientWidth, vh = vp.clientHeight;
  const sx = c.x * S.zoom + S.pan.x, sy = c.y * S.zoom + S.pan.y;
  const w = CARD_W * S.zoom, h = Math.min(heights.get(id) || EST_H, 500) * S.zoom;
  if (sx < 0) S.pan.x -= sx - 30;
  if (sy < 40) S.pan.y -= sy - 70;
  if (sx + w > vw) S.pan.x -= sx + w - vw + 30;
  if (sy + h > vh) S.pan.y -= sy + h - vh + 30;
  applyTransform();
  requestAnimationFrame(drawEdges);
}

// ---------- pan / zoom / drag ----------
const viewport = $('#viewport');
viewport.addEventListener('wheel', e => {
  e.preventDefault();
  if (e.metaKey || e.ctrlKey) {
    const z2 = Math.min(2.5, Math.max(0.12, S.zoom * Math.exp(-e.deltaY * 0.0022)));
    const r = viewport.getBoundingClientRect();
    const cx = e.clientX - r.left, cy = e.clientY - r.top;
    S.pan.x = cx - (cx - S.pan.x) * (z2 / S.zoom);
    S.pan.y = cy - (cy - S.pan.y) * (z2 / S.zoom);
    S.zoom = z2;
  } else {
    S.pan.x -= e.deltaX; S.pan.y -= e.deltaY;
  }
  applyTransform();
  scheduleSave();
}, { passive: false });

let dragging = null; // {kind:'pan'|'card', id?, sx, sy, ox, oy}
viewport.addEventListener('mousedown', e => {
  const cardHead = e.target.closest('.card-head');
  const card = e.target.closest('.card');
  if (e.target.closest('button, a, select, textarea, input, .callers-menu')) return;
  if (spaceHeld || (!card && !cardHead)) {
    dragging = { kind: 'pan', sx: e.clientX, sy: e.clientY, ox: S.pan.x, oy: S.pan.y };
    viewport.classList.add('panning');
    e.preventDefault();
    return;
  }
  if (card && (cardHead || e.ctrlKey)) {
    const id = card.dataset.id, c = S.cards.get(id);
    setFocus(id);
    dragging = { kind: 'card', id, sx: e.clientX, sy: e.clientY, ox: c.x, oy: c.y };
    e.preventDefault();
  } else if (card) {
    setFocus(id0(card));
  }
});
function id0(card) { return card.dataset.id; }

window.addEventListener('mousemove', e => {
  if (!dragging) return;
  if (dragging.kind === 'pan') {
    S.pan.x = dragging.ox + (e.clientX - dragging.sx);
    S.pan.y = dragging.oy + (e.clientY - dragging.sy);
    applyTransform();
  } else {
    const c = S.cards.get(dragging.id);
    if (!c) { dragging = null; return; }
    c.x = dragging.ox + (e.clientX - dragging.sx) / S.zoom;
    c.y = dragging.oy + (e.clientY - dragging.sy) / S.zoom;
    const el = cardEl(dragging.id);
    if (el) { el.style.left = c.x + 'px'; el.style.top = c.y + 'px'; }
    drawEdges();
  }
});
window.addEventListener('mouseup', () => {
  if (dragging) { viewport.classList.remove('panning'); dragging = null; scheduleSave(); }
});

$('#resetBtn').addEventListener('click', resetLayout);
function resetLayout() {
  // BFS from the roots: column per depth, cards stacked by measured height.
  const ids = [...S.cards.keys()];
  const depth = new Map();
  const roots = ids.filter(i => !S.edges.some(e => e.to === i));
  const queue = (roots.length ? roots : ids.slice(0, 1)).map(i => [i, 0]);
  while (queue.length) {
    const [i, d] = queue.shift();
    if (depth.has(i) && depth.get(i) <= d) continue;
    depth.set(i, d);
    for (const e of S.edges) if (e.from === i) queue.push([e.to, d + 1]);
  }
  for (const i of ids) if (!depth.has(i)) depth.set(i, 0);
  const cols = new Map();
  for (const i of ids) { const d = depth.get(i); if (!cols.has(d)) cols.set(d, []); cols.get(d).push(i); }
  for (const [d, list] of [...cols.entries()].sort((a, b) => a[0] - b[0])) {
    list.sort((a, b) => S.cards.get(a).y - S.cards.get(b).y);
    let y = 40;
    for (const i of list) {
      const c = S.cards.get(i);
      c.x = 40 + d * (CARD_W + GAP_X);
      c.y = y;
      y += (heights.get(i) || EST_H) + GAP_Y;
    }
  }
  S.pan = { x: 0, y: 0 };
  renderCanvas(); applyTransform(); scheduleSave();
}

$('#sigBtn').addEventListener('click', toggleSig);
function toggleSig() {
  sigMode = !sigMode;
  $('#world').classList.toggle('sig', sigMode);
  $('#sigBtn').classList.toggle('on', sigMode);
  requestAnimationFrame(() => { for (const [id] of S.cards) { const el = cardEl(id); if (el) heights.set(id, el.offsetHeight); } drawEdges(); });
}

// ---------- cards ----------
function buildCard(fn) {
  const st = S.cards.get(fn.id);
  const card = document.createElement('div');
  card.className = 'card' + (fn.removed ? ' removed-card' : '') + (fn.id === S.focus ? ' focused' : '') + (st.collapsed ? ' collapsed' : '');
  card.dataset.id = fn.id;
  card.style.left = st.x + 'px';
  card.style.top = st.y + 'px';
  if (fn.id === S.focus) card.style.zIndex = ++zTop;

  const showDiff = st.view === 'diff' && fn.base_source != null;
  let dstat = '';
  if (fn.base_source != null) {
    const d = diffLines(fn.base_source.split('\n'), fn.source.split('\n'));
    dstat = '<span class="dstat"><span class="plus">+' + d.filter(r => r.t === 'add').length + '</span> <span class="minus">−' + d.filter(r => r.t === 'del').length + '</span></span>';
  }
  const nCallers = (callersOf.get(fn.id) || []).length;
  const fileLine = fn.file + ':' + fn.span.start_line;
  const link = editorLink(fn);

  card.innerHTML =
    '<div class="card-head">' +
      '<span class="badge ' + fn.change + '">' + fn.change[0].toUpperCase() + '</span>' +
      '<span class="card-title">' + esc(fn.name) + '<span class="arity">/' + fn.arity + '</span></span>' +
      '<span class="chip">' + esc(fn.kind) + '</span>' + dstat +
      '<span class="card-actions">' +
        (nCallers ? '<span class="callers-wrap"><button class="callersBtn">callers ' + nCallers + '</button></span>' : '') +
        (fn.base_source != null ? '<button class="toggleView">' + (showDiff ? 'source' : 'diff') + '</button>' : '') +
        (showDiff ? '<button class="toggleFold">' + (st.fold ? 'all lines' : 'changes only') + '</button>' : '') +
        '<button class="collapseBtn" title="collapse (c)">' + (st.collapsed ? '▸' : '▾') + '</button>' +
        '<button class="closeCard" title="close (x) · shift closes the subtree">×</button>' +
      '</span>' +
    '</div>' +
    '<div class="card-sub"><span>' + esc(fn.module) + '</span>' +
      (link && !fn.removed ? '<a href="' + link + '">' + esc(fileLine) + '</a>'
                           : '<span>' + esc(fileLine) + (fn.removed ? ' (base)' : '') + '</span>') +
    '</div>' +
    '<div class="card-body"></div>';

  const body = card.querySelector('.card-body');
  if (!st.collapsed) body.appendChild(showDiff ? diffTable(fn, st) : sourceTable(fn));

  card.addEventListener('mousedown', () => { if (S.focus !== fn.id) setFocus(fn.id); });
  const tv = card.querySelector('.toggleView');
  if (tv) tv.addEventListener('click', () => {
    st.view = showDiff ? 'source' : 'diff';
    if (st.view === 'diff' && fn.base_source != null) {
      const rows = diffLines(fn.base_source.split('\n'), fn.source.split('\n'));
      if (rows.length > 100 && st.fold === false && !st.foldTouched) st.fold = true;
    }
    renderCanvas(); scheduleSave();
  });
  const tf = card.querySelector('.toggleFold');
  if (tf) tf.addEventListener('click', () => { st.fold = !st.fold; st.foldTouched = true; renderCanvas(); scheduleSave(); });
  card.querySelector('.collapseBtn').addEventListener('click', () => { st.collapsed = !st.collapsed; renderCanvas(); scheduleSave(); });
  card.querySelector('.closeCard').addEventListener('click', e => closeCard(fn.id, e.shiftKey));
  const cb = card.querySelector('.callersBtn');
  if (cb) cb.addEventListener('click', () => callersMenu(card, fn));
  return card;
}

function callersMenu(card, fn) {
  const old = card.querySelector('.callers-menu');
  if (old) { old.remove(); return; }
  const wrap = card.querySelector('.callers-wrap');
  const menu = document.createElement('div');
  menu.className = 'callers-menu';
  const seen = new Set();
  for (const { from } of callersOf.get(fn.id) || []) {
    if (seen.has(from)) continue;
    seen.add(from);
    const row = document.createElement('div');
    row.textContent = from;
    row.addEventListener('click', () => {
      const caller = byId.get(from);
      const call = caller && caller.calls.find(c => c.target === fn.id);
      const key = call ? fn.id + '@' + call.range.start[0] + ':' + call.range.start[1] : undefined;
      openCard(from, { fromId: fn.id, key, side: 'left' });
      menu.remove();
    });
    menu.appendChild(row);
  }
  wrap.appendChild(menu);
}

function editorLink(fn) {
  const root = IDX.project.root;
  if (!CFG.editor || !root) return null;
  const abs = root + '/' + fn.file, line = fn.span.start_line;
  switch (CFG.editor) {
    case 'vscode': return 'vscode://file/' + abs + ':' + line;
    case 'cursor': return 'cursor://file/' + abs + ':' + line;
    case 'zed': return 'zed://file/' + abs + ':' + line;
    case 'idea': return 'idea://open?file=' + encodeURIComponent(abs) + '&line=' + line;
  }
  return null;
}

// ---------- syntax highlighting ----------
const KW = {
  js: 'const let var function return if else for while do switch case break continue new class extends import export from default async await try catch finally throw typeof instanceof of in yield static get set delete void this super null undefined true false',
  elixir: 'def defp defmodule defmacro defmacrop defguard defstruct defprotocol defimpl defdelegate do end fn when case cond if else unless for with try rescue catch after raise receive quote unquote alias import require use true false nil and or not in',
  go: 'func return if else for range switch case break continue type struct interface map chan go defer select package import var const nil true false new make len cap append copy delete panic recover error string int int64 uint byte rune bool float64 any',
};
const kwSets = {};
for (const k in KW) kwSets[k] = new Set(KW[k].split(' '));

function langOf(file) {
  if (/\.(ex|exs)$/.test(file)) return 'elixir';
  if (/\.go$/.test(file)) return 'go';
  return 'js';
}

const tokRe = {
  js: /(\/\/.*$|\/\*.*?\*\/)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`?)|(\b\d[\d_.]*\b)|(\b[A-Z][A-Za-z0-9_]*\b)|(\b[a-z_$][A-Za-z0-9_$]*\b)/gm,
  elixir: /(#.*$)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')|(\b\d[\d_.]*\b)|(:[a-zA-Z_][A-Za-z0-9_?!]*|@[a-z_]+)|(\b[A-Z][A-Za-z0-9_.]*\b)|(\b[a-z_][A-Za-z0-9_?!]*\b)/gm,
  go: /(\/\/.*$|\/\*.*?\*\/)|("(?:[^"\\]|\\.)*"|`[^`]*`?|'(?:[^'\\]|\\.)*')|(\b\d[\d_.]*\b)|(\b[A-Z][A-Za-z0-9_]*\b)|(\b[a-z_][A-Za-z0-9_]*\b)/gm,
};

// tokenize one line into [{s, e, cls}] spans (not covering everything).
function tokenize(text, lang) {
  const re = tokRe[lang] || tokRe.js;
  re.lastIndex = 0;
  const out = [];
  let m;
  while ((m = re.exec(text))) {
    let cls = '';
    if (m[1] != null) cls = 'tok-com';
    else if (m[2] != null) cls = 'tok-str';
    else if (m[3] != null) cls = 'tok-num';
    else if (lang === 'elixir' && m[4] != null) cls = 'tok-atom';
    else {
      const word = m[0];
      const kwIdx = lang === 'elixir' ? 6 : 5;
      if (m[kwIdx] != null) cls = kwSets[lang].has(word) ? 'tok-kw' : '';
      else cls = kwSets[lang].has(word) ? 'tok-kw' : 'tok-mod';
    }
    if (cls) out.push({ s: m.index, e: m.index + m[0].length, cls });
    if (m.index === re.lastIndex) re.lastIndex++;
  }
  return out;
}

function highlightRange(text, from, to, tokens) {
  let out = '', pos = from;
  for (const t of tokens) {
    if (t.e <= from || t.s >= to) continue;
    const s = Math.max(t.s, from), e = Math.min(t.e, to);
    if (s > pos) out += esc(text.slice(pos, s));
    out += '<span class="' + t.cls + '">' + esc(text.slice(s, e)) + '</span>';
    pos = e;
  }
  return out + esc(text.slice(pos, to));
}

// ---------- source view ----------
function sourceTable(fn) {
  const lines = fn.source.split('\n');
  const start = fn.span.start_line;
  const side = fn.removed ? 'base' : 'new';
  const lang = langOf(fn.file);
  const callsByLine = new Map();
  for (const c of fn.calls) {
    if (c.range.start[0] !== c.range.end[0]) continue;
    const l = c.range.start[0];
    if (!callsByLine.has(l)) callsByLine.set(l, []);
    callsByLine.get(l).push(c);
  }
  const table = mkCodeTable();
  const tbody = table.tBodies[0];
  lines.forEach((text, i) => {
    const abs = start + i;
    const tr = document.createElement('tr');
    if (inThreadRange(fn, abs, side)) tr.classList.add('inrange');
    tr.innerHTML = '<td class="ln" title="comment · shift+click extends a range">' + abs + '</td><td class="codecell">' +
      lineHTML(text, callsByLine.get(abs) || [], lang) + '</td>';
    tr.querySelector('.ln').addEventListener('click', e => lineClick(e, fn, abs, side));
    tbody.appendChild(tr);
    appendThreadRows(tbody, fn, abs, side, 2);
  });
  wireCalls(table, fn.id);
  return table;
}

function lineHTML(text, calls, lang) {
  const tokens = tokenize(text, lang);
  if (calls.length === 0) return highlightRange(text, 0, text.length, tokens);
  calls.sort((a, b) => a.range.start[1] - b.range.start[1]);
  let out = '', pos = 0;
  for (const c of calls) {
    const s = c.range.start[1] - 1, e = Math.min(c.range.end[1] - 1, text.length);
    if (s < pos || s >= text.length) continue;
    out += highlightRange(text, pos, s, tokens);
    const key = c.target + '@' + c.range.start[0] + ':' + c.range.start[1];
    out += byId.has(c.target)
      ? '<a class="call" data-target="' + esc(c.target) + '" data-key="' + esc(key) + '" title="' + esc(c.target) + '">' + esc(text.slice(s, e)) + '</a>'
      : highlightRange(text, s, e, tokens);
    pos = e;
  }
  return out + highlightRange(text, pos, text.length, tokens);
}

function wireCalls(scope, fromId) {
  scope.querySelectorAll('a.call').forEach(a =>
    a.addEventListener('click', () => openCard(a.dataset.target, { fromId, key: a.dataset.key })));
}

// ---------- diff view ----------
function diffLines(a, b) {
  const n = a.length, m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const rows = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { rows.push({ t: 'ctx', text: a[i], o: i + 1, n: j + 1 }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { rows.push({ t: 'del', text: a[i], o: i + 1, n: null }); i++; }
    else { rows.push({ t: 'add', text: b[j], o: null, n: j + 1 }); j++; }
  }
  while (i < n) { rows.push({ t: 'del', text: a[i], o: i + 1, n: null }); i++; }
  while (j < m) { rows.push({ t: 'add', text: b[j], o: null, n: j + 1 }); j++; }
  return rows;
}

function diffTable(fn, st) {
  const rows = diffLines(fn.base_source.split('\n'), fn.source.split('\n'));
  const start = fn.span.start_line;
  const lang = langOf(fn.file);
  const table = mkCodeTable();
  const tbody = table.tBodies[0];

  const visible = new Array(rows.length).fill(true);
  if (st.fold) {
    rows.forEach((r, k) => { visible[k] = r.t !== 'ctx'; });
    rows.forEach((r, k) => {
      if (r.t !== 'ctx') for (let d = -3; d <= 3; d++) if (rows[k + d]) visible[k + d] = true;
    });
    // every line a comment sits on stays drawn
    rows.forEach((r, k) => {
      const absNew = r.n != null ? start + r.n - 1 : null;
      if ((r.o != null && threadsAt(fn, r.o, 'base').length) || (absNew != null && threadsAt(fn, absNew, 'new').length)) visible[k] = true;
    });
  }

  let k = 0, runIdx = 0;
  while (k < rows.length) {
    if (!visible[k] && !st.expanded.has(runIdx)) {
      let e = k;
      while (e < rows.length && !visible[e]) e++;
      const count = e - k, thisRun = runIdx;
      const tr = document.createElement('tr');
      tr.className = 'fold';
      tr.innerHTML = '<td colspan="4">⋯ ' + count + ' unchanged line' + (count > 1 ? 's' : '') + '</td>';
      tr.addEventListener('click', () => { st.expanded.add(thisRun); renderCanvas(); });
      tbody.appendChild(tr);
      k = e; runIdx++;
      continue;
    }
    const r = rows[k];
    const absNew = r.n != null ? start + r.n - 1 : null;
    const tr = document.createElement('tr');
    tr.className = r.t === 'ctx' ? '' : r.t;
    if ((r.o != null && inThreadRange(fn, r.o, 'base')) || (absNew != null && inThreadRange(fn, absNew, 'new'))) tr.classList.add('inrange');
    const sign = r.t === 'add' ? '+' : r.t === 'del' ? '−' : '';
    tr.innerHTML = '<td class="ln old" title="comment on the base side">' + (r.o != null ? r.o : '') + '</td>' +
      '<td class="ln" title="comment">' + (absNew != null ? absNew : '') + '</td>' +
      '<td class="sign">' + sign + '</td><td class="codecell">' + highlightRange(r.text, 0, r.text.length, tokenize(r.text, lang)) + '</td>';
    const [oldLn, newLn] = tr.querySelectorAll('.ln');
    if (r.o != null) oldLn.addEventListener('click', e => lineClick(e, fn, r.o, 'base'));
    if (absNew != null) newLn.addEventListener('click', e => lineClick(e, fn, absNew, 'new'));
    tbody.appendChild(tr);
    if (r.o != null) appendThreadRows(tbody, fn, r.o, 'base', 4);
    if (absNew != null) appendThreadRows(tbody, fn, absNew, 'new', 4);
    k++;
    if (k < rows.length && !visible[k - 1] && visible[k]) runIdx++;
  }
  return table;
}

function mkCodeTable() {
  const t = document.createElement('table');
  t.className = 'code';
  t.appendChild(document.createElement('tbody'));
  return t;
}

// ---------- comments ----------
function lineClick(e, fn, line, side) {
  // Shift+click while composing stretches the range to this line.
  if (e.shiftKey && composing && composing.fnId === fn.id && composing.side === side) {
    if (line >= composing.line) composing.endLine = line;
    else { composing.endLine = composing.endLine || composing.line; composing.line = line; }
    renderCanvas();
    return;
  }
  composing = { fnId: fn.id, file: fn.file, line, endLine: null, side };
  renderCanvas();
}

function threadsAt(fn, line, side) {
  return COMMENTS.threads.filter(t => t.file === fn.file && t.side === side &&
    (t.end_line ? t.end_line === line : t.line === line) &&
    (t.function === fn.id || byId.get(t.function) == null));
}

function inThreadRange(fn, line, side) {
  if (composing && composing.fnId === fn.id && composing.side === side && composing.endLine &&
      line >= composing.line && line <= composing.endLine) return true;
  return COMMENTS.threads.some(t => t.file === fn.file && t.side === side && t.end_line &&
    line >= t.line && line <= t.end_line);
}

function appendThreadRows(tbody, fn, line, side, colspan) {
  for (const t of threadsAt(fn, line, side)) tbody.appendChild(threadRow(t, colspan));
  if (composing && composing.fnId === fn.id && composing.side === side &&
      (composing.endLine ? composing.endLine === line : composing.line === line))
    tbody.appendChild(composerRow(colspan));
}

function threadRow(t, colspan) {
  const tr = document.createElement('tr');
  const td = document.createElement('td');
  td.colSpan = colspan;
  const box = document.createElement('div');
  box.className = 'thread' + (t.resolved ? ' resolved' : '');
  const range = t.end_line ? t.line + '–' + t.end_line : '' + t.line;
  box.innerHTML = '<div class="who" style="margin-bottom:6px"><span style="font-family:var(--mono)">' + esc(range) + (t.side === 'base' ? ' (base)' : '') + '</span>' +
    (t.resolved ? '<span class="chip">resolved</span>' : '') + '</div>' +
    t.comments.map(c =>
      '<div class="cmt"><div class="who"><span class="avatar">' + esc(initials(c.author)) + '</span>' +
      esc(c.author) + ' · ' + esc((c.at || '').slice(0, 16).replace('T', ' ')) + '</div>' +
      '<div class="body">' + esc(c.body) + '</div></div>').join('') +
    (t.published_url ? '<div class="pub">published: ' + esc(t.published_url) + '</div>' : '') +
    '<textarea placeholder="reply…"></textarea>' +
    '<div class="thread-actions">' +
      '<button class="reply">reply</button>' +
      '<button class="resolve">' + (t.resolved ? 'reopen' : 'resolve') + '</button>' +
      '<button class="del">delete</button>' +
    '</div>';
  if (t.resolved) box.addEventListener('click', e => { if (!e.target.closest('button, textarea')) box.classList.toggle('expanded'); });
  const ta = box.querySelector('textarea');
  box.querySelector('.reply').addEventListener('click', () => { if (ta.value.trim()) api({ action: 'reply', thread: t.id, body: ta.value }); });
  ta.addEventListener('keydown', e => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && ta.value.trim()) api({ action: 'reply', thread: t.id, body: ta.value });
  });
  box.querySelector('.resolve').addEventListener('click', () => api({ action: t.resolved ? 'unresolve' : 'resolve', thread: t.id }));
  box.querySelector('.del').addEventListener('click', () => api({ action: 'delete', thread: t.id }));
  td.appendChild(box); tr.appendChild(td);
  return tr;
}

function composerRow(colspan) {
  const tr = document.createElement('tr');
  const td = document.createElement('td');
  td.colSpan = colspan;
  const box = document.createElement('div');
  box.className = 'composer';
  const range = composing.endLine ? composing.line + '–' + composing.endLine : '' + composing.line;
  box.innerHTML = '<textarea placeholder="comment on line ' + esc(range) + '…"></textarea>' +
    '<div class="row"><button class="send">comment</button><button class="cancel">cancel</button>' +
    '<span class="hint">⌘⏎ sends · shift+click a line number extends the range</span></div>';
  const ta = box.querySelector('textarea');
  const send = () => {
    if (!ta.value.trim()) return;
    api({ action: 'add', function: composing.fnId, file: composing.file, line: composing.line, end_line: composing.endLine || 0, side: composing.side, body: ta.value });
    composing = null;
  };
  box.querySelector('.send').addEventListener('click', send);
  box.querySelector('.cancel').addEventListener('click', () => { composing = null; renderCanvas(); });
  ta.addEventListener('keydown', e => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') send();
    if (e.key === 'Escape') { composing = null; renderCanvas(); e.stopPropagation(); }
  });
  td.appendChild(box); tr.appendChild(td);
  setTimeout(() => ta.focus(), 0);
  return tr;
}

async function api(payload) {
  const r = await fetch('/api/comments', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
  if (r.ok) { COMMENTS = await r.json(); renderCanvas(); renderSidebar(); }
  else alert(await r.text());
}

function initials(name) {
  return (name || '?').split(/\s+/).map(w => w[0] || '').join('').slice(0, 2).toUpperCase();
}

// ---------- edges ----------
function edgeColor(key) {
  let h = 0;
  for (const ch of key || '') h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return 'hsl(' + (h % 360) + ' 65% 62%)';
}

function drawEdges() {
  const svg = $('#edgesvg');
  const world = $('#world');
  const wr = world.getBoundingClientRect();
  let html = '';
  S.edges.forEach((e, idx) => {
    const fromCard = cardEl(e.from), toCard = cardEl(e.to);
    if (!fromCard || !toCard) return;
    const to = S.cards.get(e.to), from = S.cards.get(e.from);
    let x1, y1;
    const srcEl = e.key ? fromCard.querySelector('a.call[data-key="' + CSS.escape(e.key) + '"]') : null;
    if (srcEl) {
      const r = srcEl.getBoundingClientRect();
      x1 = (r.right - wr.left) / S.zoom;
      y1 = (r.top + r.height / 2 - wr.top) / S.zoom;
    } else {
      x1 = from.x + CARD_W;
      y1 = from.y + 20;
    }
    const rightward = to.x >= from.x + CARD_W / 2;
    const x2 = rightward ? to.x : to.x + CARD_W;
    const y2 = to.y + 22;
    if (!rightward && srcEl == null) x1 = from.x;
    const mx = (x1 + x2) / 2;
    const color = edgeColor(e.key || e.from + e.to);
    const tip = rightward ? x2 - 7 : x2 + 7;
    html += '<path data-i="' + idx + '" d="M' + x1 + ' ' + y1 + ' C' + mx + ' ' + y1 + ', ' + mx + ' ' + y2 + ', ' + x2 + ' ' + y2 +
      '" fill="none" stroke="' + color + '" stroke-opacity=".55" stroke-width="1.6"/>' +
      '<polygon points="' + x2 + ',' + y2 + ' ' + tip + ',' + (y2 - 4) + ' ' + tip + ',' + (y2 + 4) + '" fill="' + color + '" fill-opacity=".8"/>';
  });
  svg.innerHTML = html;
  svg.querySelectorAll('path').forEach(p => p.addEventListener('dblclick', () => {
    const e = S.edges[+p.dataset.i];
    if (!e) return;
    // jump to whichever end is farther out of sight
    const vp = $('#viewport');
    const center = { x: vp.clientWidth / 2, y: vp.clientHeight / 2 };
    const dist = id => {
      const c = S.cards.get(id);
      const sx = (c.x + CARD_W / 2) * S.zoom + S.pan.x, sy = c.y * S.zoom + S.pan.y;
      return Math.hypot(sx - center.x, sy - center.y);
    };
    const far = dist(e.from) > dist(e.to) ? e.from : e.to;
    setFocus(far); ensureVisible(far);
  }));
}

// ---------- palette ----------
let palSel = 0, palItems = [];
function openPalette() { $('#palette').hidden = false; $('#palInput').value = ''; palRender(''); $('#palInput').focus(); }
function closePalette() { $('#palette').hidden = true; }
$('#paletteBtn').addEventListener('click', openPalette);
$('#palette').addEventListener('mousedown', e => { if (e.target === $('#palette')) closePalette(); });
$('#palInput').addEventListener('input', () => palRender($('#palInput').value));
$('#palInput').addEventListener('keydown', e => {
  if (e.key === 'ArrowDown') { palSel = Math.min(palSel + 1, palItems.length - 1); palPaint(); e.preventDefault(); }
  else if (e.key === 'ArrowUp') { palSel = Math.max(palSel - 1, 0); palPaint(); e.preventDefault(); }
  else if (e.key === 'Enter') { if (palItems[palSel]) { openCard(palItems[palSel].id, {}); closePalette(); } }
  else if (e.key === 'Escape') closePalette();
});

function fuzzyScore(needle, hay) {
  needle = needle.toLowerCase(); hay = hay.toLowerCase();
  if (needle === '') return 1;
  let score = 0, j = 0, streak = 0;
  for (let i = 0; i < hay.length && j < needle.length; i++) {
    if (hay[i] === needle[j]) { streak++; score += 1 + streak * 2 + (i === 0 || './_-'.includes(hay[i - 1]) ? 8 : 0); j++; }
    else streak = 0;
  }
  return j === needle.length ? score : -1;
}

function palRender(q) {
  const scored = [];
  for (const f of IDX.functions) {
    const s = fuzzyScore(q, f.id);
    if (s >= 0) scored.push([s + (f.change !== 'unchanged' ? 5 : 0), f]);
  }
  scored.sort((a, b) => b[0] - a[0]);
  palItems = scored.slice(0, 60).map(x => x[1]);
  palSel = 0;
  palPaint();
}

function palPaint() {
  $('#palList').innerHTML = palItems.map((f, i) =>
    '<li data-i="' + i + '" class="' + (i === palSel ? 'sel' : '') + '"><span class="badge ' + f.change + '">' +
    f.change[0].toUpperCase() + '</span><span>' + esc(f.id) + '</span><span class="file">' + esc(f.file) + '</span></li>').join('');
  document.querySelectorAll('#palList li').forEach(li =>
    li.addEventListener('click', () => { openCard(palItems[+li.dataset.i].id, {}); closePalette(); }));
  const sel = document.querySelector('#palList li.sel');
  if (sel) sel.scrollIntoView({ block: 'nearest' });
}

// ---------- chat ----------
let chatRunning = false;
$('#askBtn').addEventListener('click', toggleChat);
$('#chatClose').addEventListener('click', toggleChat);
function toggleChat() {
  const p = $('#chat');
  p.hidden = !p.hidden;
  if (!p.hidden) $('#chatText').focus();
}

$('#chatNew').addEventListener('click', () => {
  $('#transcript').innerHTML = '';
  chatMsg('meta', 'new conversation');
  fetch('/api/chat/reset', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ session: S.name }) }).catch(() => {});
});
$('#chatStop').addEventListener('click', () => fetch('/api/chat/stop', { method: 'POST' }));

$('#chatText').addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendChat(); }
});

function chatMsg(cls, text) {
  const div = document.createElement('div');
  div.className = 'msg ' + cls;
  div.textContent = text;
  $('#transcript').appendChild(div);
  $('#transcript').scrollTop = $('#transcript').scrollHeight;
  return div;
}

async function sendChat() {
  const ta = $('#chatText');
  const message = ta.value.trim();
  if (!message || chatRunning) return;
  ta.value = '';
  chatMsg('user', message);
  chatRunning = true;
  $('#chatStop').disabled = false;
  ta.disabled = true;
  try {
    const r = await fetch('/api/chat', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message, mode: $('#chatMode').value, model: $('#chatModel').value, session: S.name }),
    });
    if (!r.ok) { chatMsg('err', await r.text()); return; }
    const reader = r.body.getReader();
    const dec = new TextDecoder();
    let buf = '';
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let nl;
      while ((nl = buf.indexOf('\n\n')) >= 0) {
        const chunk = buf.slice(0, nl);
        buf = buf.slice(nl + 2);
        for (const line of chunk.split('\n')) {
          if (line.startsWith('data: ')) handleChatEvent(line.slice(6));
        }
      }
    }
  } catch (err) {
    chatMsg('err', String(err));
  } finally {
    chatRunning = false;
    $('#chatStop').disabled = true;
    ta.disabled = false;
    ta.focus();
  }
}

function handleChatEvent(raw) {
  let ev;
  try { ev = JSON.parse(raw); } catch { return; }
  switch (ev.type) {
    case 'assistant':
      for (const block of (ev.message && ev.message.content) || []) {
        if (block.type === 'text' && block.text.trim()) chatMsg('assistant', block.text);
        else if (block.type === 'tool_use') {
          const input = JSON.stringify(block.input || {});
          chatMsg('tool', '⏺ ' + block.name + ' ' + (input.length > 90 ? input.slice(0, 90) + '…' : input));
        }
      }
      break;
    case 'result':
      chatMsg('meta', (ev.subtype === 'success' ? 'done' : ev.subtype) +
        (ev.num_turns ? ' · ' + ev.num_turns + ' turns' : '') +
        (ev.total_cost_usd ? ' · $' + ev.total_cost_usd.toFixed(4) : ''));
      COMMENTS_refresh();
      break;
    case 'stderr':
      chatMsg('err', ev.text);
      break;
  }
}

async function COMMENTS_refresh() {
  const r = await fetch('/api/comments');
  if (r.ok) { COMMENTS = await r.json(); renderCanvas(); renderSidebar(); }
}

// ---------- keyboard ----------
document.addEventListener('keydown', e => {
  if (e.code === 'Space' && !(e.target.tagName === 'TEXTAREA' || e.target.tagName === 'INPUT')) { spaceHeld = true; }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); openPalette(); return; }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'i') { e.preventDefault(); toggleChat(); return; }
  if (e.target.tagName === 'TEXTAREA' || e.target.tagName === 'INPUT') return;
  if (e.key === 'Escape') {
    if (!$('#palette').hidden) closePalette();
    else if (composing) { composing = null; renderCanvas(); }
    return;
  }
  const st = S.focus && S.cards.get(S.focus);
  const fn = S.focus && byId.get(S.focus);
  switch (e.key) {
    case 'd':
      if (st && fn && fn.base_source != null) { st.view = st.view === 'diff' ? 'source' : 'diff'; renderCanvas(); scheduleSave(); }
      break;
    case 'h':
      if (st) { st.fold = !st.fold; st.foldTouched = true; renderCanvas(); scheduleSave(); }
      break;
    case 'c':
      if (st) { st.collapsed = !st.collapsed; renderCanvas(); scheduleSave(); }
      break;
    case 'x':
      if (S.focus) closeCard(S.focus, e.shiftKey);
      break;
    case 's':
      toggleSig();
      break;
    case 'ArrowRight': walkEdge(true); e.preventDefault(); break;
    case 'ArrowLeft': walkEdge(false); e.preventDefault(); break;
    case 'ArrowDown': walkColumn(1); e.preventDefault(); break;
    case 'ArrowUp': walkColumn(-1); e.preventDefault(); break;
  }
});
document.addEventListener('keyup', e => { if (e.code === 'Space') spaceHeld = false; });

function walkEdge(out) {
  if (!S.focus) return;
  const e = out ? S.edges.find(e => e.from === S.focus) : S.edges.find(e => e.to === S.focus);
  if (!e) return;
  const next = out ? e.to : e.from;
  setFocus(next); ensureVisible(next);
}

function walkColumn(dir) {
  if (!S.focus) return;
  const cur = S.cards.get(S.focus);
  const same = [...S.cards.entries()].filter(([, c]) => Math.abs(c.x - cur.x) < CARD_W / 2).sort((a, b) => a[1].y - b[1].y);
  const idx = same.findIndex(([id]) => id === S.focus);
  const next = same[idx + dir];
  if (next) { setFocus(next[0]); ensureVisible(next[0]); }
}

// ---------- boot ----------
(async function boot() {
  if (!(await loadAll(false))) return;
  await loadSession(defaultSessionName());
  if (!new URLSearchParams(location.search).has('static')) {
    const es = new EventSource('/events');
    es.addEventListener('reload', async () => {
      const name = S.name;
      if (await loadAll(true)) {
        // a new PR index renames the session it belongs to
        const want = defaultSessionName();
        if (want !== name && IDX.review) await loadSession(want);
        else { renderCanvas(); applyTransform(); }
      }
    });
  }
})();
