/* Self-Service Portal - single page app (no build step, no external dependencies). */
(() => {
  'use strict';

  const FINAL = ['Succeeded', 'Failed', 'Rejected', 'Cancelled'];
  const STATUS_LABEL = { PendingApproval: 'Pending approval', Queued: 'Queued', Dispatched: 'Starting', Running: 'Running',
                         Succeeded: 'Succeeded', Failed: 'Failed', Rejected: 'Rejected', Cancelled: 'Cancelled' };
  const state = { me: null, catalog: [], category: 'All', search: '', timer: null, background: false, lastActivity: Date.now(), lastServerTouch: Date.now() };
  const app = document.getElementById('app');

  /* ---------------- utilities ---------------- */
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fmtDate = (s) => (s ? new Date(s).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '');
  const hasRole = (r) => !!state.me && state.me.user.roles.includes(r);
  const pill = (s) => `<span class="pill st-${esc(s)}">${esc(STATUS_LABEL[s] || s)}</span>`;

  function toast(msg, ms = 3500) {
    const t = document.getElementById('toast');
    t.textContent = msg; t.classList.remove('hidden');
    clearTimeout(toast._h); toast._h = setTimeout(() => t.classList.add('hidden'), ms);
  }

  /* ---------------- session (idle timeout, re-authentication, sign-out) ---------------- */
  const channel = ('BroadcastChannel' in window) ? new BroadcastChannel('ssp-session') : null;

  function logout(reason) {
    try { sessionStorage.setItem('ssp-logout-reason', reason || 'signedout'); } catch { /* private mode */ }
    if (channel && reason !== 'remote') channel.postMessage({ type: 'logout', reason });
    fetch('/api/session/logout', { method: 'POST', credentials: 'same-origin', headers: { 'X-Portal-Request': '1', 'Content-Type': 'application/json' }, body: '{}' })
      .catch(() => {}).finally(() => {
        const f = document.createElement('form'); f.method = 'post'; f.action = '/logout'; document.body.appendChild(f); f.submit();
      });
  }

  function modal(html) {
    const wrap = document.createElement('div');
    wrap.className = 'modal-backdrop';
    wrap.innerHTML = `<div class="modal" role="dialog" aria-modal="true">${html}</div>`;
    document.body.appendChild(wrap);
    const first = wrap.querySelector('input, button'); if (first) setTimeout(() => first.focus(), 30);
    return { el: wrap, close: () => wrap.remove() };
  }

  let reauthPending = null;
  function reauthDialog(message) {
    if (reauthPending) return reauthPending;
    reauthPending = new Promise((resolve, reject) => {
      const m = modal(`<h2 class="section-title">Confirm it's you</h2>
        <p class="muted">${esc(message || 'This action needs your password again.')}</p>
        <div class="field"><label for="raPw">Password</label><input id="raPw" type="password" autocomplete="current-password"></div>
        <div class="field hidden" id="raOtpBox"><label for="raOtp">Authenticator code</label><input id="raOtp" type="text" inputmode="numeric" autocomplete="one-time-code" placeholder="123456"></div>
        <div id="raErr" class="alert alert-err hidden"></div>
        <div class="modal-actions"><button class="btn" id="raCancel">Cancel</button><button class="btn btn-primary" id="raOk">Confirm</button></div>`);
      const done = (ok, err) => { m.close(); reauthPending = null; ok ? resolve() : reject(err || new Error('Confirmation cancelled.')); };
      const submit = async () => {
        const body = { password: document.getElementById('raPw').value, otp: document.getElementById('raOtp').value.trim() };
        try {
          const r = await rawApi('/api/session/reauth', { method: 'POST', body });
          if (r.next === 'mfa') { document.getElementById('raOtpBox').classList.remove('hidden'); document.getElementById('raOtp').focus(); return; }
          done(true);
        } catch (e) { const b = document.getElementById('raErr'); b.textContent = e.message; b.classList.remove('hidden'); }
      };
      m.el.querySelector('#raOk').addEventListener('click', submit);
      m.el.querySelector('#raCancel').addEventListener('click', () => done(false));
      m.el.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') submit(); if (ev.key === 'Escape') done(false); });
    });
    return reauthPending;
  }

  // User interaction keeps the session alive (throttled keepalive); idle tabs are signed out by the server and here.
  function noteActivity(fromServerCall) {
    state.lastActivity = Date.now();
    if (fromServerCall) state.lastServerTouch = Date.now();
    if (channel) channel.postMessage({ type: 'activity', at: state.lastActivity });
  }
  ['click', 'keydown', 'pointerdown', 'scroll'].forEach((ev) => window.addEventListener(ev, () => {
    state.lastActivity = Date.now();
    if (state.me && Date.now() - state.lastServerTouch > 60000) {
      state.lastServerTouch = Date.now();
      api('/api/session/keepalive', { method: 'POST' }).catch(() => {});
    }
  }, { passive: true, capture: true }));
  if (channel) channel.onmessage = (m) => {
    if (m.data.type === 'activity') { state.lastActivity = Math.max(state.lastActivity, m.data.at); state.lastServerTouch = Math.max(state.lastServerTouch, m.data.at); hideIdleWarning(); }
    if (m.data.type === 'logout') logout('remote');
  };

  let idleBox = null;
  function hideIdleWarning() { if (idleBox) { idleBox.close(); idleBox = null; } }
  function startIdleWatch() {
    setInterval(() => {
      const s = state.me && state.me.session; if (!s) return;
      const idleMs = s.idleTimeoutMinutes * 60000, warnMs = s.warningSeconds * 1000;
      const left = idleMs - (Date.now() - state.lastActivity);
      if (s.expiresAt && Date.now() > Date.parse(s.expiresAt)) return logout('expired');
      if (left <= 0) return logout('idle');
      if (left <= warnMs) {
        const secs = Math.ceil(left / 1000);
        if (!idleBox) {
          idleBox = modal(`<h2 class="section-title">Are you still there?</h2>
            <p>For security you will be signed out in <b id="idleSecs">${secs}</b> seconds of inactivity.</p>
            <div class="modal-actions"><button class="btn" id="idleOut">Sign out</button><button class="btn btn-primary" id="idleStay">Stay signed in</button></div>`);
          idleBox.el.querySelector('#idleStay').addEventListener('click', async () => {
            hideIdleWarning();
            try { await api('/api/session/keepalive', { method: 'POST' }); } catch { /* api() handles expiry */ }
          });
          idleBox.el.querySelector('#idleOut').addEventListener('click', () => logout('signedout'));
        }
        const e = document.getElementById('idleSecs'); if (e) e.textContent = secs;
      } else hideIdleWarning();
    }, 1000);
  }

  async function api(path, opts = {}) {
    try { return await rawApi(path, opts); }
    catch (e) {
      const code = e.fields && e.fields.code;
      if (e.status === 401 && code === 'REAUTH_REQUIRED' && !opts._retried) {
        await reauthDialog(e.message);
        return api(path, { ...opts, _retried: true });
      }
      if (e.status === 401 && code) { logout(code === 'SESSION_IDLE' ? 'idle' : code === 'SESSION_REVOKED' ? 'revoked' : 'expired'); }
      if (e.status === 403 && (code === 'PASSWORD_CHANGE_REQUIRED' || code === 'MFA_ENROLLMENT_REQUIRED') && location.hash !== '#/account') {
        location.hash = '#/account';
      }
      throw e;
    }
  }

  async function rawApi(path, opts = {}) {
    const init = { method: opts.method || 'GET', credentials: 'same-origin', headers: { 'Accept': 'application/json' } };
    const background = !!(opts.background || state.background);
    if (background) init.headers['X-Portal-Background'] = '1'; else noteActivity(true);
    if (init.method !== 'GET') {
      init.headers['Content-Type'] = 'application/json';
      init.headers['X-Portal-Request'] = '1';
      if (init.method !== 'DELETE' || opts.body) init.body = JSON.stringify(opts.body || {});
    }
    let res;
    for (let attempt = 0; ; attempt++) {
      try { res = await fetch(path, init); }
      catch (e) { if (init.method === 'GET' && attempt < 2) { await new Promise((r) => setTimeout(r, 400 * (attempt + 1))); continue; } throw e; }
      // 408 = Pode closed an idle keep-alive connection or timed out the request: retry GETs transparently.
      if (res.status === 408 && init.method === 'GET' && attempt < 2) { await new Promise((r) => setTimeout(r, 400 * (attempt + 1))); continue; }
      break;
    }
    const ct = res.headers.get('content-type') || '';
    if ((res.redirected && res.url.includes('/login')) || (res.ok && !ct.includes('json')) || (res.status === 401 && !ct.includes('json'))) {
      logout('expired'); throw new Error('Session expired');
    }
    const data = ct.includes('json') ? await res.json() : {};
    if (res.ok && data && data.ok === false && data.next) return data;
    if (!res.ok) { const e = new Error(data.error || `HTTP ${res.status}`); e.status = res.status; e.fields = data.fields; throw e; }
    return data;
  }

  const ICONS = {
    vm: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>',
    windows: '<rect x="3" y="3" width="18" height="7" rx="1.5"/><rect x="3" y="14" width="18" height="7" rx="1.5"/><path d="M7 6.5h.01M7 17.5h.01"/>',
    linux: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3M13 15h4"/>',
    snapshot: '<path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/>',
    network: '<circle cx="12" cy="5" r="2"/><circle cx="5" cy="19" r="2"/><circle cx="19" cy="19" r="2"/><path d="M12 7v5M12 12l-6 5M12 12l6 5"/>',
    storage: '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
    backup: '<path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5M12 7v5l3 2"/>',
    security: '<path d="M12 3 4 6v6c0 5 3.5 8 8 9 4.5-1 8-4 8-9V6z"/>',
    database: '<ellipse cx="12" cy="5" rx="7" ry="2.5"/><path d="M5 5v14c0 1.4 3.1 2.5 7 2.5s7-1.1 7-2.5V5M5 12c0 1.4 3.1 2.5 7 2.5s7-1.1 7-2.5"/>',
    cloud: '<path d="M7 18h10a4 4 0 0 0 .6-7.95A6 6 0 0 0 6.1 9.1 4.5 4.5 0 0 0 7 18z"/>',
    generic: '<rect x="4" y="4" width="16" height="16" rx="3"/><path d="M9 12h6M12 9v6"/>'
  };
  const icon = (k, size = 22) => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${ICONS[k] || ICONS.generic}</svg>`;

  /* ---------------- router ---------------- */
  function setActive(route) {
    document.querySelectorAll('#nav a').forEach((a) => a.classList.toggle('active', a.dataset.route === route));
  }
  async function backgroundRoute() {
    state.background = true;
    try { await route(true); } finally { state.background = false; }
  }
  async function route(keepTimer) {
    if (!keepTimer) { clearInterval(state.timer); state.timer = null; }
    const s = state.me && state.me.session;
    if (s && (s.mustChangePassword || s.mfaEnrollRequired) && location.hash !== '#/account') { location.hash = '#/account'; return; }
    const parts = (location.hash || '#/catalog').slice(2).split('/');
    const [r, id] = parts;
    try {
      switch (r) {
        case 'item':      setActive('catalog');   return await viewItem(decodeURIComponent(id));
        case 'requests':  setActive('requests');  return id ? await viewRequest(id) : await viewRequestList('mine');
        case 'approvals': setActive('approvals'); return await viewRequestList('approvals');
        case 'all':       setActive('all');       return await viewRequestList('all');
        case 'admin':     setActive('admin');     return await viewAdmin(parts.slice(1).map(decodeURIComponent));
        case 'account':   setActive('account');   return await viewAccount();
        default:          setActive('catalog');   return await viewCatalog();
      }
    } catch (e) {
      app.innerHTML = `<div class="alert alert-err">${esc(e.message)}</div>`;
    }
  }
  window.addEventListener('hashchange', route);

  /* ---------------- marketplace ---------------- */
  async function viewCatalog() {
    const data = await api('/api/catalog');
    state.catalog = data.items || [];
    const cats = ['All', ...new Set(state.catalog.map((i) => i.category))];
    app.innerHTML = `
      <div class="page-head">
        <div><h1>Service marketplace</h1><p>Request infrastructure services. Every request is validated, tracked and audited.</p></div>
        <div class="search">${'<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>'}
          <input id="q" type="text" placeholder="Search services..." value="${esc(state.search)}"></div>
      </div>
      <div class="chips">${cats.map((c) => `<button class="chip ${c === state.category ? 'active' : ''}" data-cat="${esc(c)}">${esc(c)}</button>`).join('')}</div>
      <div id="grid"></div>`;
    const draw = () => {
      const q = state.search.toLowerCase();
      const items = state.catalog.filter((i) => (state.category === 'All' || i.category === state.category) &&
        (!q || [i.name, i.summary, i.category, ...(i.tags || [])].join(' ').toLowerCase().includes(q)));
      const card = (i) => `
        <article class="card svc" data-id="${esc(i.id)}" tabindex="0">
          <div class="svc-top"><div class="svc-icon">${icon(i.icon)}</div>
            <div><div class="svc-name">${esc(i.name)}</div><div class="svc-cat">${esc(i.category)} &middot; v${esc(i.version)}</div></div></div>
          <div class="svc-sum">${esc(i.summary)}</div>
          <div class="svc-foot">
            ${i.approvalRequired ? '<span class="tag tag-approval">Approval required</span>' : '<span class="tag tag-auto">Auto-approved</span>'}
            ${i.estimatedDuration ? `<span class="tag">~ ${esc(i.estimatedDuration)}</span>` : ''}
            ${(i.tags || []).slice(0, 2).map((t) => `<span class="tag">${esc(t)}</span>`).join('')}
          </div>
        </article>`;
      // "All": one section per category (e.g. Datacenter (vSphere), Cloud Ops); a category chip shows a flat grid.
      const groups = [...new Set(items.map((i) => i.category))];
      document.getElementById('grid').innerHTML = !items.length ? '<div class="empty card">No services match your search.</div>'
        : (state.category === 'All' && groups.length > 1)
          ? groups.map((g) => `<section class="mk-section"><h2 class="mk-title">${esc(g)} <span class="muted">${items.filter((i) => i.category === g).length}</span></h2>
              <div class="grid">${items.filter((i) => i.category === g).map(card).join('')}</div></section>`).join('')
          : `<div class="grid">${items.map(card).join('')}</div>`;
    };
    draw();
    document.getElementById('q').addEventListener('input', (e) => { state.search = e.target.value; draw(); });
    app.querySelectorAll('.chip').forEach((b) => b.addEventListener('click', () => { state.category = b.dataset.cat; viewCatalog(); }));
  }
  // Card navigation (delegated once; cards only exist on the marketplace view).
  app.addEventListener('click', (e) => { const c = e.target.closest('.svc'); if (c) location.hash = `#/item/${encodeURIComponent(c.dataset.id)}`; });
  app.addEventListener('keydown', (e) => { const c = e.target.closest('.svc'); if (c && e.key === 'Enter') location.hash = `#/item/${encodeURIComponent(c.dataset.id)}`; });

  /* ---------------- request form (rendered from the catalog JSON) ---------------- */
  async function viewItem(id) {
    const item = await api(`/api/catalog/${encodeURIComponent(id)}`);
    const groups = [];
    item.inputs.forEach((f) => { const g = f.group || 'Details'; let grp = groups.find((x) => x.name === g); if (!grp) groups.push(grp = { name: g, fields: [] }); grp.fields.push(f); });

    app.innerHTML = `
      <a class="back" href="#/catalog">&larr; Marketplace</a>
      <div class="page-head"><div style="display:flex;gap:14px;align-items:center"><div class="svc-icon">${icon(item.icon)}</div>
        <div><h1>${esc(item.name)}</h1><p>${esc(item.summary)}</p></div></div></div>
      <div class="two-col">
        <form id="reqForm" novalidate>
          <div id="formAlert"></div>
          ${groups.map((g) => `<section class="card fieldset"><h2 class="section-title">${esc(g.name)}</h2>
            <div class="fields">${g.fields.map(renderField).join('')}</div></section>`).join('')}
        </form>
        <aside class="aside card card-pad stack">
          <div><h2 class="section-title">About this service</h2><p style="margin:0">${esc(item.description || item.summary)}</p></div>
          <dl class="kv">
            <dt>Category</dt><dd>${esc(item.category)}</dd>
            <dt>Version</dt><dd>${esc(item.version)}</dd>
            <dt>Owner</dt><dd>${esc(item.owner)}</dd>
            <dt>Duration</dt><dd>${esc(item.estimatedDuration || '-')}</dd>
            <dt>Approval</dt><dd>${item.approvalRequired ? '<span class="tag tag-approval">Required</span>' : '<span class="tag tag-auto">Not required</span>'}</dd>
          </dl>
          <button class="btn btn-primary" id="submitBtn" type="button" style="width:100%;padding:10px">${item.approvalRequired ? 'Submit for approval' : 'Submit request'}</button>
        </aside>
      </div>`;

    const byName = Object.fromEntries(item.inputs.map((f) => [f.name, f]));
    const children = {};
    item.inputs.forEach((f) => (f.source?.dependsOn || []).forEach((p) => (children[p] = children[p] || []).push(f.name)));
    const el = (n) => document.getElementById(`f_${n}`);

    const readValues = () => {
      const v = {};
      item.inputs.forEach((f) => {
        const wrap = document.getElementById(`w_${f.name}`);
        if (wrap.classList.contains('hidden')) return;
        const e = el(f.name);
        v[f.name] = f.type === 'boolean' ? e.checked : e.value;
      });
      return v;
    };
    const applyVisibility = () => {
      item.inputs.forEach((f) => {
        if (!f.visibleWhen) return;
        const ctl = el(f.visibleWhen.field);
        const cur = ctl ? (ctl.type === 'checkbox' ? ctl.checked : ctl.value) : undefined;
        const w = document.getElementById(`w_${f.name}`);   // the form may be gone (navigation during a lookup)
        if (w) w.classList.toggle('hidden', String(cur) !== String(f.visibleWhen.equals));
      });
    };
    async function loadOptions(name) {
      const f = byName[name]; const s = el(name);
      if (!s || (!f.source && f.type !== 'credential')) return;
      const deps = (f.source && f.source.dependsOn) || [];
      const values = readValues();
      if (deps.some((d) => !values[d])) { s.innerHTML = `<option value="">Select ${esc(byName[deps.find((d) => !values[d])].label)} first</option>`; s.disabled = true; return; }
      s.disabled = true; s.innerHTML = '<option value="">Loading...</option>';
      try {
        const res = await api(`/api/catalog/${encodeURIComponent(item.id)}/options/${encodeURIComponent(name)}`, { method: 'POST', body: { values } });
        const opts = res.options || [];
        if (!s.isConnected) return;
        s.innerHTML = `<option value="">${opts.length ? 'Select...' : 'No options available'}</option>` +
          opts.map((o) => `<option value="${esc(o.value)}">${esc(o.label)}</option>`).join('');
        if (f.default !== undefined && opts.some((o) => o.value === String(f.default))) s.value = String(f.default);
        else if (opts.length === 1 && f.required) s.value = opts[0].value;
        s.disabled = false;
      } catch (e) {
        s.innerHTML = '<option value="">Unavailable</option>';
        setFieldError(name, e.message);
      }
      if (s.value) await cascade(name);
    }
    async function cascade(name) {
      applyVisibility();
      for (const c of children[name] || []) await loadOptions(c);
    }
    function setFieldError(name, msg) {
      const w = document.getElementById(`w_${name}`); if (!w) return;
      w.classList.toggle('invalid', !!msg);
      w.querySelector('.err').textContent = msg || '';
    }

    item.inputs.forEach((f) => {
      const e = el(f.name);
      e.addEventListener('change', async () => { setFieldError(f.name, ''); await cascade(f.name); });
    });
    // Storage rescan buttons.
    const storageInputs = item.inputs.filter((f) => f.source && f.source.type === 'storageDevices');
    const scanTarget = (f) => { const v = readValues(); return { site: v[(f.source.dependsOn || ['Site'])[0]], cluster: v[f.source.clusterInput || 'Cluster'] }; };
    async function showScanState(f) {
      const btn = document.getElementById(`rs_${f.name}`); const info = document.getElementById(`rss_${f.name}`);
      const t = scanTarget(f);
      if (!t.site || !t.cluster) { btn.disabled = true; info.textContent = 'Select the cluster first.'; return null; }
      try {
        const st = await api(`/api/storage/scan?itemId=${encodeURIComponent(item.id)}&site=${encodeURIComponent(t.site)}&cluster=${encodeURIComponent(t.cluster)}`, { background: true });
        const last = st.lastRescanAt ? `Last rescan ${fmtDate(st.lastRescanAt)} by ${st.lastRescanBy}.` : 'Never rescanned from the portal.';
        const failed = st.state === 'Failed' && st.error ? ` Last scan failed: ${st.error}` : '';
        if (st.running) { btn.disabled = true; info.textContent = `Scanning... (started by ${st.lockedBy})`; }
        else if (st.cooldownSeconds > 0) { btn.disabled = true; info.textContent = `${last} Next rescan in ${Math.ceil(st.cooldownSeconds / 60)} min.${failed}`; }
        else { btn.disabled = false; info.textContent = `${last}${failed}`; }
        return st;
      } catch (e) { btn.disabled = true; info.textContent = e.message; return null; }
    }
    for (const f of storageInputs) {
      document.getElementById(`rs_${f.name}`).addEventListener('click', async (ev) => {
        const btn = ev.currentTarget; btn.disabled = true; setFieldError(f.name, '');
        const t = scanTarget(f);
        try {
          await api('/api/storage/rescan', { method: 'POST', body: { itemId: item.id, site: t.site, cluster: t.cluster } });
          toast(`Storage rescan started on ${t.cluster}.`);
          for (let i = 0; i < 200; i++) {
            await new Promise((ok) => setTimeout(ok, 3000));
            const st = await showScanState(f);
            if (!st || !st.running) break;
          }
          await loadOptions(f.name);
        } catch (e) { setFieldError(f.name, e.message); }
        await showScanState(f);
      });
      const cl = el(f.source.clusterInput || 'Cluster');
      if (cl) cl.addEventListener('change', () => showScanState(f));
      showScanState(f);
    }

    applyVisibility();
    for (const f of item.inputs) if ((f.source && !(f.source.dependsOn || []).length) || f.type === 'credential') await loadOptions(f.name);

    document.getElementById('submitBtn').addEventListener('click', async (ev) => {
      const btn = ev.currentTarget; btn.disabled = true;
      item.inputs.forEach((f) => setFieldError(f.name, ''));
      document.getElementById('formAlert').innerHTML = '';
      try {
        const res = await api('/api/requests', { method: 'POST', body: { itemId: item.id, inputs: readValues() } });
        toast(`Request ${res.id} submitted (${STATUS_LABEL[res.status] || res.status}).`);
        location.hash = `#/requests/${res.id}`;
      } catch (e) {
        document.getElementById('formAlert').innerHTML = `<div class="alert alert-err">${esc(e.message)}</div>`;
        if (e.fields) Object.entries(e.fields).forEach(([k, m]) => setFieldError(k, m));
        const first = document.querySelector('.field.invalid'); if (first) first.scrollIntoView({ behavior: 'smooth', block: 'center' });
        btn.disabled = false;
      }
    });
  }

  function renderField(f) {
    const id = `f_${f.name}`;
    const req = f.required ? '<span class="req">*</span>' : '';
    const help = f.help ? `<div class="help">${esc(f.help)}</div>` : '';
    const wide = f.type === 'textarea' ? ' wide' : '';
    const def = f.default ?? '';
    let ctl;
    switch (f.type) {
      case 'textarea': ctl = `<textarea id="${id}" maxlength="${esc(f.validation?.maxLength ?? '')}" placeholder="${esc(f.placeholder || '')}" ${f.placeholder && String(f.placeholder).includes('\n') ? 'rows="5" class="mono"' : ''}>${esc(def)}</textarea>`; break;
      case 'number':   ctl = `<input id="${id}" type="number" value="${esc(def)}" ${f.validation?.min !== undefined ? `min="${esc(f.validation.min)}"` : ''} ${f.validation?.max !== undefined ? `max="${esc(f.validation.max)}"` : ''}>`; break;
      case 'boolean':  return `<div class="field" id="w_${f.name}"><label class="toggle"><input id="${id}" type="checkbox" ${def === true || def === 'true' ? 'checked' : ''}> ${esc(f.label)}</label>${help}<div class="err"></div></div>`;
      case 'select':
        ctl = f.options
          ? `<select id="${id}"><option value="">Select...</option>${f.options.map((o) => `<option value="${esc(o.value)}" ${String(o.value) === String(def) ? 'selected' : ''}>${esc(o.label)}</option>`).join('')}</select>`
          : `<select id="${id}" disabled><option value="">Loading...</option></select>`;
        break;
      case 'credential': ctl = `<select id="${id}" disabled><option value="">Loading...</option></select>`; break;
      case 'ipv4': ctl = `<input id="${id}" type="text" inputmode="decimal" placeholder="10.0.0.10" value="${esc(def)}">`; break;
      default: ctl = `<input id="${id}" type="text" value="${esc(def)}" placeholder="${esc(f.placeholder || '')}" ${f.validation?.maxLength ? `maxlength="${esc(f.validation.maxLength)}"` : ''}>`;
    }
    // Storage devices (New datastore): explicit rescan; every rescan asks for re-authentication and is rate limited per cluster.
    const rescan = f.source && f.source.type === 'storageDevices'
      ? `<div class="rescan-row"><button type="button" class="btn btn-sm" id="rs_${f.name}" disabled>Rescan storage</button><span class="muted small" id="rss_${f.name}"></span></div>` : '';
    return `<div class="field${wide}" id="w_${f.name}"><label for="${id}">${esc(f.label)}${req}</label>${ctl}${rescan}${help}<div class="err"></div></div>`;
  }

  /* ---------------- request lists ---------------- */
  async function viewRequestList(scope) {
    const titles = { mine: ['My requests', 'Everything you have requested through the portal.'],
                     approvals: ['Approvals', 'Requests waiting for your decision. You cannot approve your own requests.'],
                     all: ['All requests', 'Every request across the portal.'] };
    const data = await api(`/api/requests?scope=${scope}`);
    const rows = data.requests || [];
    app.innerHTML = `
      <div class="page-head"><div><h1>${titles[scope][0]}</h1><p>${titles[scope][1]}</p></div>
        <button class="btn" id="refresh">Refresh</button></div>
      <div class="card table-wrap">${rows.length ? `
        <table><thead><tr><th>Request</th><th>Service</th><th>Target</th><th>Site</th>${scope !== 'mine' ? '<th>Requester</th>' : ''}<th>Status</th><th>Created</th><th>Updated</th></tr></thead>
        <tbody>${rows.map((r) => `<tr class="click" data-id="${esc(r.id)}">
          <td class="mono">${esc(r.id)}</td><td>${esc(r.itemName)}</td><td>${esc(r.target || '-')}</td><td>${esc(r.site || '-')}</td>
          ${scope !== 'mine' ? `<td>${esc(r.requester?.name)}</td>` : ''}
          <td>${pill(r.status)}</td><td>${fmtDate(r.createdAt)}</td><td>${fmtDate(r.updatedAt)}</td></tr>`).join('')}</tbody></table>`
        : `<div class="empty">${scope === 'approvals' ? 'Nothing waiting for approval.' : 'No requests yet. Start from the <a href="#/catalog">marketplace</a>.'}</div>`}
      </div>`;
    document.getElementById('refresh').addEventListener('click', route);
    app.querySelectorAll('tr.click').forEach((tr) => tr.addEventListener('click', () => (location.hash = `#/requests/${tr.dataset.id}`)));
    if (rows.some((r) => !FINAL.includes(r.status)) && !state.timer) state.timer = setInterval(() => { if (!document.hidden) backgroundRoute(); }, 15000);
  }

  /* ---------------- request detail ---------------- */
  async function viewRequest(id) {
    const r = await api(`/api/requests/${encodeURIComponent(id)}`);
    const inputs = Object.entries(r.inputs || {});
    const result = r.result ? Object.entries(r.result) : [];
    app.innerHTML = `
      <a class="back" href="#/requests">&larr; Requests</a>
      <div class="detail-head" style="margin-bottom:18px">
        <div><h1>${esc(r.itemName)} ${r.target ? `&middot; ${esc(r.target)}` : ''}</h1>
          <p class="muted" style="margin:4px 0 0"><span class="mono">${esc(r.id)}</span> &middot; requested by ${esc(r.requester.name)} &middot; ${fmtDate(r.createdAt)}</p></div>
        <div style="display:flex;gap:10px;align-items:center">${pill(r.status)}
          ${r.canCancel ? '<button class="btn btn-danger btn-sm" id="cancelBtn">Cancel request</button>' : ''}</div>
      </div>
      <div class="two-col">
        <div class="stack">
          ${r.canApprove ? `<section class="card card-pad"><h2 class="section-title">Your decision</h2>
            <div class="field wide"><label for="decisionComment">Comment</label><textarea id="decisionComment" placeholder="Required when rejecting"></textarea></div>
            <div class="actions" style="margin-top:12px"><button class="btn btn-ok" id="approveBtn">Approve</button><button class="btn btn-danger" id="rejectBtn">Reject</button></div></section>` : ''}
          ${r.error ? `<div class="alert alert-err"><b>Failure:</b> ${esc(r.error)}</div>` : ''}
          ${result.length ? `<section class="card card-pad"><h2 class="section-title">Result</h2><dl class="kv">${result.map(([k, v]) =>
            `<dt>${esc(k)}</dt><dd>${Array.isArray(v) ? `<ul style="margin:0;padding-left:18px">${v.map((x) => `<li>${esc(x)}</li>`).join('')}</ul>` : esc(typeof v === 'object' ? JSON.stringify(v) : v)}</dd>`).join('')}</dl></section>` : ''}
          ${(r.reports || []).length ? `<section class="card card-pad"><h2 class="section-title">Reports</h2><ul class="report-list">${r.reports.map((f) =>
            `<li><a href="/api/requests/${encodeURIComponent(r.id)}/reports/${encodeURIComponent(f.name)}" target="_blank" rel="noopener">${esc(f.name)}</a>
             <span class="tag">${esc(String(f.type).toUpperCase())}</span> <span class="muted small">${esc(f.sizeKB)} KB</span></li>`).join('')}</ul></section>` : ''}
          <section class="card card-pad"><div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px">
            <h2 class="section-title" style="margin:0">Execution log</h2><span class="muted" id="logState"></span></div>
            <div class="console" id="log">${['PendingApproval', 'Queued', 'Rejected', 'Cancelled'].includes(r.status) ? 'The job has not started.' : 'Loading...'}</div></section>
          <section class="card card-pad"><h2 class="section-title">Submitted values</h2>
            <dl class="kv">${inputs.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('')}</dl></section>
        </div>
        <aside class="aside card card-pad stack">
          <div><h2 class="section-title">Approval</h2>
            ${r.approval.required ? (r.approval.decision
              ? `<p style="margin:0">${esc(r.approval.decision)} by <b>${esc(r.approval.decidedBy)}</b><br><span class="muted">${fmtDate(r.approval.decidedAt)}</span>${r.approval.comment ? `<br>&ldquo;${esc(r.approval.comment)}&rdquo;` : ''}</p>`
              : `<p style="margin:0" class="muted">Waiting for ${esc((r.approval.approverRoles || []).join(' / '))}.</p>`)
              : '<p style="margin:0" class="muted">Not required for this service.</p>'}</div>
          <div><h2 class="section-title">Timeline</h2><ul class="timeline">${(r.history || []).map((h) =>
            `<li><b>${esc(STATUS_LABEL[h.status] || h.status)}</b> <span class="muted">&middot; ${fmtDate(h.ts)}</span><br><span class="muted">${esc(h.actor)}${h.note ? ` &mdash; ${esc(h.note)}` : ''}</span></li>`).join('')}</ul></div>
        </aside>
      </div>`;

    const decide = async (action) => {
      const comment = document.getElementById('decisionComment').value.trim();
      if (action === 'reject' && !comment) { toast('A comment is required to reject.'); return; }
      try { await api(`/api/requests/${id}/${action}`, { method: 'POST', body: { comment } }); toast(`Request ${action === 'approve' ? 'approved' : 'rejected'}.`); refreshApprovalCount(); route(); }
      catch (e) { toast(e.message); }
    };
    document.getElementById('approveBtn')?.addEventListener('click', () => decide('approve'));
    document.getElementById('rejectBtn')?.addEventListener('click', () => decide('reject'));
    document.getElementById('cancelBtn')?.addEventListener('click', async () => {
      if (!confirmInline('cancelBtn')) return;
      try { await api(`/api/requests/${id}/cancel`, { method: 'POST' }); toast('Request cancelled.'); route(); } catch (e) { toast(e.message); }
    });

    const started = !['PendingApproval', 'Queued', 'Rejected', 'Cancelled'].includes(r.status);
    const loadLog = async () => {
      const l = await api(`/api/requests/${encodeURIComponent(id)}/log`);
      const box = document.getElementById('log'); if (!box) return;
      const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 20;
      box.innerHTML = l.log ? l.log.split('\n').map((line) => {
        const m = line.match(/\[(STEP|OK|WARN|ERROR|INFO)\s*\]/); return `<span class="${m ? 'l-' + m[1] : ''}">${esc(line)}</span>`;
      }).join('\n') : 'Waiting for output...';
      if (atBottom) box.scrollTop = box.scrollHeight;
      document.getElementById('logState').textContent = FINAL.includes(l.status) ? '' : 'Live - refreshing every 3 s';
      if (l.status !== r.status) route();   // state change: re-render the whole view
    };
    if (started) await loadLog();
    if (!FINAL.includes(r.status) && !state.timer) state.timer = setInterval(() => {
      if (document.hidden) return;
      state.background = true;
      (started ? loadLog() : route(true)).catch(() => {}).finally(() => { state.background = false; });
    }, started ? 3000 : 10000);
  }

  // Two-click confirmation without browser dialogs.
  function confirmInline(btnId) {
    const b = document.getElementById(btnId);
    if (b.dataset.armed) return true;
    b.dataset.armed = '1'; const t = b.textContent; b.textContent = 'Click again to confirm';
    setTimeout(() => { if (b.isConnected) { delete b.dataset.armed; b.textContent = t; } }, 4000);
    return false;
  }

  /* ---------------- my account: password, MFA ---------------- */
  async function viewAccount() {
    state.me = await api('/api/me');
    const me = state.me, u = me.user, s = me.session || {};
    const forced = s.mustChangePassword ? 'password' : (s.mfaEnrollRequired ? 'mfa' : null);
    app.innerHTML = `
      <div class="page-head"><div><h1>My account</h1><p>${esc(u.name)} &middot; <span class="mono">${esc(u.username)}</span> &middot; ${u.local ? 'Local account' : `Directory account (${esc(u.provider)})`}</p></div></div>
      ${forced === 'password' ? '<div class="alert alert-warn"><b>Change your password to continue.</b> It was set by an administrator or has expired.</div>' : ''}
      ${forced === 'mfa' ? '<div class="alert alert-warn"><b>Set up multi-factor authentication to continue.</b> Your role requires an authenticator app (Microsoft Authenticator, Google Authenticator, FreeOTP...).</div>' : ''}
      <div class="grid-2">
        <section class="card card-pad">
          <h2 class="section-title">Access</h2>
          <dl class="kv"><dt>Roles</dt><dd>${u.roles.map((r) => `<span class="tag">${esc(r)}</span>`).join(' ') || '-'}</dd>
            <dt>Teams</dt><dd>${(u.teams || []).map((t) => `<span class="tag">${esc(t)}</span>`).join(' ') || '<span class="muted">all items without team restriction</span>'}</dd>
            <dt>Session</dt><dd>Signs out after ${esc(s.idleTimeoutMinutes)} min of inactivity; expires ${fmtDate(s.expiresAt)}</dd></dl>
          ${u.networkRestricted ? '<div class="alert alert-warn">Administrative roles are only available from the management network.</div>' : ''}
        </section>
        <section class="card card-pad" id="pwCard">
          <h2 class="section-title">Password</h2>
          ${u.local ? `
            <div class="field"><label for="pwCur">Current password</label><input id="pwCur" type="password" autocomplete="current-password"></div>
            <div class="field"><label for="pwNew">New password</label><input id="pwNew" type="password" autocomplete="new-password"></div>
            <div class="field"><label for="pwNew2">Repeat new password</label><input id="pwNew2" type="password" autocomplete="new-password"></div>
            <p class="hint">Minimum length, character classes and history are set by your administrator.</p>
            <button class="btn btn-primary" id="pwSave">Change password</button>`
          : '<p class="muted">Your password is managed by your directory (Active Directory / LDAP).</p>'}
        </section>
      </div>
      <section class="card card-pad" id="mfaCard" style="margin-top:16px">
        <h2 class="section-title">Multi-factor authentication</h2>
        <div id="mfaBody">${me.mfa.enrolled
          ? `<div class="alert alert-ok">Authenticator app enrolled ${fmtDate(me.mfa.enrolledAt)} &middot; ${me.mfa.recoveryLeft} recovery codes left.</div>
             <button class="btn" id="mfaStart">Replace authenticator / new recovery codes</button>`
          : `<p>${forced === 'mfa' ? '' : 'Optional for your role, recommended. '}Protect your account with a 6-digit code from an authenticator app.</p>
             <button class="btn btn-primary" id="mfaStart">Set up authenticator app</button>`}</div>
      </section>`;
    const pwSave = document.getElementById('pwSave');
    if (pwSave) pwSave.addEventListener('click', async () => {
      const cur = document.getElementById('pwCur').value, n1 = document.getElementById('pwNew').value, n2 = document.getElementById('pwNew2').value;
      if (n1 !== n2) return toast('The new passwords do not match.');
      try { await api('/api/me/password', { method: 'POST', body: { currentPassword: cur, newPassword: n1 } }); toast('Password changed.'); await afterAccountChange(); }
      catch (e) { toast(e.message, 6000); }
    });
    document.getElementById('mfaStart').addEventListener('click', async () => {
      let en;
      try { en = await api('/api/me/mfa/begin', { method: 'POST' }); } catch (e) { return toast(e.message); }
      const qr = window.qrcode ? (() => { const q = window.qrcode(0, 'M'); q.addData(en.uri); q.make(); return q.createSvgTag({ cellSize: 4, margin: 2, scalable: true }); })() : '';
      document.getElementById('mfaBody').innerHTML = `
        <div class="mfa-setup">
          <div class="mfa-qr">${qr}</div>
          <div>
            <ol class="steps"><li>Open your authenticator app and add an account.</li><li>Scan the QR code, or type the key:<div class="mono secret-key">${esc(en.secret.replace(/(.{4})/g, '$1 ').trim())}</div></li>
              <li>Enter the 6-digit code the app shows:</li></ol>
            <div class="inline"><input id="mfaCode" type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="123456" style="width:140px">
              <button class="btn btn-primary" id="mfaConfirm">Verify and enable</button></div>
          </div>
        </div>`;
      document.getElementById('mfaConfirm').addEventListener('click', async () => {
        try {
          const r = await api('/api/me/mfa/confirm', { method: 'POST', body: { code: document.getElementById('mfaCode').value.trim() } });
          document.getElementById('mfaBody').innerHTML = `
            <div class="alert alert-ok"><b>Multi-factor authentication is on.</b></div>
            <p>Save these one-time recovery codes in a safe place. Each one signs you in once if you lose your phone. They are shown only now.</p>
            <div class="recovery">${r.recoveryCodes.map((c) => `<span class="mono">${esc(c)}</span>`).join('')}</div>
            <button class="btn btn-primary" id="mfaDone" style="margin-top:12px">I saved my codes</button>`;
          document.getElementById('mfaDone').addEventListener('click', afterAccountChange);
        } catch (e) { toast(e.message, 6000); }
      });
    });
  }

  async function afterAccountChange() {
    state.me = await api('/api/me');
    applyNav();
    const s = state.me.session;
    if (s.mustChangePassword || s.mfaEnrollRequired) return viewAccount();
    location.hash = '#/catalog'; route();
  }

  function applyNav() {
    const me = state.me;
    document.getElementById('userName').textContent = me.user.name;
    document.getElementById('userRoles').textContent = (me.user.assignedRoles && me.user.assignedRoles.length ? me.user.assignedRoles : me.user.roles).join(' · ');
    document.querySelectorAll('#nav [data-role]').forEach((a) => a.classList.toggle('hidden', !hasRole(a.dataset.role)));
    const adminLink = document.querySelector('#nav [data-perm]');
    if (adminLink) adminLink.classList.toggle('hidden', !(me.permissions || []).length);
  }

  /* ---------------- admin (web/assets/admin.js) ---------------- */
  async function viewAdmin(args) {
    if (!window.PortalAdmin) throw new Error('Admin module not loaded.');
    return window.PortalAdmin.view(app, args);
  }

  /* ---------------- bootstrap ---------------- */
  async function refreshApprovalCount() {
    if (!hasRole('Approver')) return;
    try {
      const d = await api('/api/requests?scope=approvals', { background: true });
      const n = (d.requests || []).length; const b = document.getElementById('approvalCount');
      b.textContent = n; b.classList.toggle('hidden', n === 0);
    } catch { /* ignore */ }
  }

  const can = (perm) => !!state.me && (state.me.permissions || []).includes(perm);
  window.Portal = { api, esc, toast, fmtDate, pill, icon, hasRole, can, state, route, ICONS, modal, reauthDialog };

  (async function init() {
    try { state.branding = await (await fetch('/api/branding')).json(); window.applyBranding(state.branding); } catch { /* defaults */ }
    try { state.me = await api('/api/me'); }
    catch (e) { app.innerHTML = `<div class="alert alert-err">${esc(e.message)}</div>`; return; }
    applyNav();
    document.getElementById('signOut').addEventListener('click', () => logout('signedout'));
    startIdleWatch();
    refreshApprovalCount(); setInterval(refreshApprovalCount, 60000);
    route();
  })();
})();
