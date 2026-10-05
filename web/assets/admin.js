/* Self-Service Portal - Admin module
   Tabs (shown per permission): Catalog | Customization | vCenter connections | Cloud connections | Identity | Security |
   Vault | Local users | Audit | Data files (software repository, baselines, backup policies)
   Each tab loads only its own data, so one slow call never blocks the whole page. */
(() => {
  'use strict';
  const P = () => window.Portal;
  const esc = (v) => P().esc(v);
  const ROLES = ['Requester', 'Approver', 'Admin', 'CatalogAdmin', 'SecurityAdmin', 'VaultAdmin'];
  const ROLE_HELP = { Requester: 'request services', Approver: 'approve requests of their teams', Admin: 'everything',
                      CatalogAdmin: 'catalog, branding, teams, VM notes', SecurityAdmin: 'identity, users, security policy, audit', VaultAdmin: 'credential vault' };
  const INPUT_TYPES = ['text', 'textarea', 'number', 'select', 'boolean', 'ipv4', 'credential'];
  const SOURCE_TYPES = ['', 'sites', 'clusters', 'datastores', 'datastoreClusters', 'portgroups', 'templates', 'folders', 'vms', 'hosts', 'vdSwitches', 'storageDevices', 'softwareSets', 'backupPolicies', 'awsSubnets', 'awsInstanceTypes', 'azureSubnets', 'azureVmSizes'];
  const ICON_KEYS = ['vm', 'windows', 'linux', 'snapshot', 'network', 'storage', 'backup', 'security', 'database', 'cloud', 'generic'];
  const TABS = [['catalog', 'Catalog', ['catalog.manage']], ['datafiles', 'Data files', ['catalog.manage']], ['customization', 'Customization', ['catalog.manage', 'security.manage']],
                ['vcenters', 'vCenter connections', ['connections.manage']], ['clouds', 'Cloud connections', ['connections.manage']],
                ['identity', 'Identity', ['security.manage']], ['security', 'Security', ['security.manage']], ['vault', 'Vault', ['vault.manage']],
                ['users', 'Local users', ['security.manage']], ['audit', 'Audit', ['audit.read']]];
  const can = (perm) => P().can(perm);
  const allowedTabs = () => TABS.filter(([, , perms]) => perms.some(can));

  let host = null;            // #app element
  const ed = { draft: null, fx: [], mode: 'create', file: null, sites: [], handlers: [], params: null, errors: [] };

  /* ---------------- shell ---------------- */
  async function view(appEl, args) {
    host = appEl;
    const tabs = allowedTabs();
    if (!tabs.length) { host.innerHTML = '<div class="alert alert-err">You have no administrative permissions.</div>'; return; }
    let [tab, sub, id] = args || [];
    if (!tab || !tabs.some(([k]) => k === tab)) tab = tabs[0][0];
    const shell = (inner) => `
      <div class="page-head"><div><h1>Administration</h1><p>Catalog, connections, identity, security, credential vault and audit trail.</p></div></div>
      <nav class="tabs">${tabs.map(([k, l]) => `<a href="#/admin/${k}" class="${k === tab ? 'active' : ''}">${l}</a>`).join('')}</nav>
      <div id="adminBody">${inner}</div>`;
    host.innerHTML = shell('<div class="card card-pad muted">Loading...</div>');
    const body = document.getElementById('adminBody');
    try {
      if (tab === 'catalog' && (sub === 'new' || sub === 'edit')) return await catalogEditor(body, sub === 'new' ? null : id);
      if (tab === 'catalog')  return await catalogList(body);
      if (tab === 'vcenters') return await vcenters(body);
      if (tab === 'clouds')   return await clouds(body);
      if (tab === 'customization') return await customization(body);
      if (tab === 'users')    return await users(body);
      if (tab === 'identity') return await identity(body);
      if (tab === 'security') return await security(body);
      if (tab === 'vault')    return await vault(body);
      if (tab === 'audit')    return await audit(body);
      if (tab === 'datafiles') return await dataFiles(body, sub);
      body.innerHTML = '<div class="alert alert-err">Unknown admin page.</div>';
    } catch (e) { body.innerHTML = `<div class="alert alert-err">${esc(e.message)}</div>`; }
  }

  const val = (id) => { const e = document.getElementById(id); return e ? (e.type === 'checkbox' ? e.checked : e.value.trim()) : undefined; };
  const checkedValues = (name) => [...document.querySelectorAll(`input[name="${name}"]:checked`)].map((e) => e.value);
  const teamList = () => (P().state.me && P().state.me.teams) || [];
  const teamBoxes = (name, selected) => teamList().length
    ? teamList().map((t) => `<label class="toggle"><input type="checkbox" name="${name}" value="${esc(t.id)}" ${selected.includes(t.id) ? 'checked' : ''}> ${esc(t.name)} <span class="muted mono" style="font-size:11px">${esc(t.id)}</span></label>`).join('')
    : '<span class="muted">No teams defined (Admin > Customization).</span>';
  const roleBoxes = (name, selected, roles = ROLES) => roles.map((r) => `<label class="toggle" title="${esc(ROLE_HELP[r] || '')}"><input type="checkbox" name="${name}" value="${r}" ${selected.includes(r) ? 'checked' : ''}> ${r}</label>`).join('');
  const list = (v) => (v || '').split(/[\n,]/).map((x) => x.trim()).filter(Boolean);
  const dot = (state) => `<span class="state-dot ${state}"></span>`;

  /* =====================================================================================================
     CATALOG LIST
     ===================================================================================================== */
  async function catalogList(body) {
    const cat = await P().api('/api/admin/catalog');
    body.innerHTML = `
      <section class="card card-pad">
        <div class="section-bar"><h2 class="section-title" style="margin:0">Catalog items</h2>
          <a class="btn btn-primary" href="#/admin/catalog/new">+ New catalog item</a></div>
        ${cat.errors.length ? `<div class="alert alert-err"><b>${cat.errors.length} item file(s) rejected</b> (not visible in the marketplace):
          <ul style="margin:6px 0 0;padding-left:18px">${cat.errors.map((e) => `<li><span class="mono">${esc(e.file)}</span>: ${e.errors.map(esc).join('; ')}
          ${e.id ? ` &mdash; <a href="#/admin/catalog/edit/${encodeURIComponent(e.id)}">fix in editor</a>` : ''}</li>`).join('')}</ul></div>`
          : '<div class="alert alert-ok">All catalog files are valid.</div>'}
        <div class="table-wrap"><table><thead><tr><th>Id</th><th>Name</th><th>Version</th><th>Status</th><th>Approval</th><th>Visible to</th><th>Handler</th><th>Updated</th><th></th></tr></thead>
        <tbody>${cat.items.map((i) => `<tr><td class="mono">${esc(i.id)}</td><td>${esc(i.name)}</td><td>${esc(i.version)}</td>
          <td>${i.enabled ? '<span class="tag tag-auto">Published</span>' : '<span class="tag">Disabled</span>'}</td>
          <td>${i.approval ? 'Required' : 'Auto'}</td><td>${esc((i.roles || []).join(', '))}</td>
          <td class="mono" style="word-break:break-all">${esc(i.handler)}</td><td>${P().fmtDate(i.updated)}</td>
          <td class="row-actions"><a class="btn btn-sm" href="#/admin/catalog/edit/${encodeURIComponent(i.id)}">Edit</a>
            <button class="btn btn-sm btn-danger" data-del="${esc(i.id)}">Delete</button></td></tr>`).join('')}</tbody></table></div>
      </section>`;
    body.querySelectorAll('[data-del]').forEach((b) => b.addEventListener('click', async () => {
      if (!armed(b, 'Confirm delete')) return;
      try { await P().api(`/api/admin/catalog/${encodeURIComponent(b.dataset.del)}`, { method: 'DELETE' }); P().toast('Item archived (catalog/_archive).'); catalogList(body); }
      catch (e) { P().toast(e.message); }
    }));
  }

  // Two-click confirmation without browser dialogs.
  function armed(btn, label) {
    if (btn.dataset.armed) return true;
    const t = btn.textContent; btn.dataset.armed = '1'; btn.textContent = label;
    setTimeout(() => { if (btn.isConnected) { delete btn.dataset.armed; btn.textContent = t; } }, 4000);
    return false;
  }

  /* =====================================================================================================
     CATALOG EDITOR
     ===================================================================================================== */
  function newDraft() {
    return {
      id: '', version: '1.0.0', enabled: false, name: '', category: 'Compute', icon: 'generic', summary: '', description: '',
      owner: 'Infrastructure Operations', tags: [], estimatedDuration: '',
      access: { roles: [...ROLES] }, approval: { required: true, approverRoles: ['Approver', 'Admin'] },
      sites: ed.sites.map((s) => s.code),
      execution: { handler: '', requiresVCenter: true, siteInput: 'Site', timeoutMinutes: 30, fixedParameters: {} },
      inputs: [{ name: 'Site', label: 'Datacenter', type: 'select', group: 'Placement', required: true, source: { type: 'sites' } }]
    };
  }

  async function catalogEditor(body, id) {
    const [sites, handlers] = await Promise.all([P().api('/api/admin/sites'), P().api('/api/admin/handlers')]);
    ed.sites = sites.sites; ed.handlers = handlers.handlers; ed.params = null; ed.errors = [];
    if (id) {
      const r = await P().api(`/api/admin/catalog/${encodeURIComponent(id)}`);
      ed.draft = r.item; ed.mode = 'update'; ed.file = r.file;
    } else { ed.draft = newDraft(); ed.mode = 'create'; ed.file = null; }
    const d = ed.draft;
    d.access = d.access || { roles: [...ROLES] }; d.approval = d.approval || { required: false };
    d.execution = d.execution || {}; d.inputs = d.inputs || [];
    ed.fx = Object.entries(d.execution.fixedParameters || {}).map(([name, v]) =>
      (v && typeof v === 'object' && !Array.isArray(v)) ? { name, perSite: true, value: '', siteValues: { ...v } } : { name, perSite: false, value: v ?? '', siteValues: {} });
    renderEditor(body);
  }

  function renderEditor(body) {
    const d = ed.draft, x = d.execution;
    body.innerHTML = `
      <a class="back" href="#/admin/catalog">&larr; Catalog</a>
      <div class="editor-head"><h2>${ed.mode === 'create' ? 'New catalog item' : `Edit <span class="mono">${esc(d.id)}</span>`}</h2>
        <span class="muted">${ed.file ? `File: <span class="mono">catalog/items/${esc(ed.file)}</span>` : 'Will be saved as catalog/items/&lt;id&gt;.json'}</span></div>
      <div id="edErrors"></div>

      <section class="card fieldset"><h2 class="section-title">General</h2><div class="fields">
        ${fld('Id', `<input type="text" data-k="id" value="${esc(d.id)}" ${ed.mode === 'update' ? 'readonly' : ''} placeholder="vm-windows-2025">`, 'Lowercase, digits and hyphens. Immutable once created.')}
        ${fld('Name', `<input type="text" data-k="name" value="${esc(d.name)}">`)}
        ${fld('Version', `<input type="text" data-k="version" value="${esc(d.version)}" placeholder="1.0.0">`, 'Semantic version, stored in every request.')}
        ${fld('Category', `<input type="text" data-k="category" value="${esc(d.category)}" list="dlCategory"><datalist id="dlCategory"><option>Compute</option><option>Operations</option><option>Network</option><option>Storage</option><option>Backup</option></datalist>`)}
        ${fld('Icon', `<select data-k="icon">${ICON_KEYS.map((k) => `<option ${d.icon === k ? 'selected' : ''}>${k}</option>`).join('')}</select>`)}
        ${fld('Estimated duration', `<input type="text" data-k="estimatedDuration" value="${esc(d.estimatedDuration || '')}" placeholder="15-20 min">`)}
        ${fld('Summary (card text)', `<input type="text" data-k="summary" value="${esc(d.summary)}" maxlength="200">`, '', true)}
        ${fld('Description', `<textarea data-k="description">${esc(d.description || '')}</textarea>`, '', true)}
        ${fld('Owner', `<input type="text" data-k="owner" value="${esc(d.owner || '')}">`)}
        ${fld('Tags (comma separated)', `<input type="text" data-k="tags" data-t="list" value="${esc((d.tags || []).join(', '))}">`)}
        <div class="field wide"><label class="toggle"><input type="checkbox" data-k="enabled" data-t="bool" ${d.enabled !== false ? 'checked' : ''}> Published (visible in the marketplace)</label></div>
      </div></section>

      <section class="card fieldset"><h2 class="section-title">Access, approval and sites</h2><div class="fields">
        <div class="field"><label>Visible to roles</label><div class="checks">${roleBoxes('accRoles', d.access.roles || [])}</div></div>
        <div class="field"><label>Visible to teams</label><div class="checks">${teamBoxes('accTeams', d.access.teams || [])}</div><div class="help">None selected = every team. Admins always see every item.</div></div>
        <div class="field"><label>Build options</label><label class="toggle"><input type="checkbox" id="edVmNotes" ${d.vmNotes ? 'checked' : ''}> Add the "VM notes" section (Admin > Customization) to this form</label><div class="help">The script receives it as -VmNotes.</div></div>
        <div class="field"><label>Approval</label><label class="toggle"><input type="checkbox" id="apprReq" ${d.approval.required ? 'checked' : ''}> Requires approval before execution</label>
          <div class="checks" style="margin-top:6px">${roleBoxes('apprRoles', d.approval.approverRoles || ['Approver', 'Admin'])}</div><div class="help">Roles allowed to approve.</div></div>
        <div class="field wide"><label>Offered at sites</label><div class="checks">${ed.sites.map((s) =>
          `<label class="toggle"><input type="checkbox" name="edSites" value="${esc(s.code)}" ${(d.sites || []).includes(s.code) ? 'checked' : ''}> ${esc(s.code)} <span class="muted">${esc(s.vcenter)}</span></label>`).join('')}</div></div>
      </div></section>

      <section class="card fieldset"><h2 class="section-title">Automation</h2><div class="fields">
        ${fld('Automation script (handler)', `<input type="text" data-k="execution.handler" value="${esc(x.handler || '')}" list="dlHandlers" placeholder="New-MyService.ps1 or D:\\Automation\\Invoke-X.ps1">
            <datalist id="dlHandlers">${ed.handlers.map((h) => `<option value="${esc(h.handler)}">`).join('')}</datalist>`,
            'File name in automation/handlers, or a full path inside a folder listed in automation.allowedHandlerRoots.', true)}
        <div class="field wide"><div class="actions">
          <button type="button" class="btn btn-sm" id="btnInspect">Inspect script parameters</button>
          <button type="button" class="btn btn-sm" id="btnStub">Create script skeleton</button></div>
          <div id="inspectOut"></div></div>
        ${fld('Timeout (minutes)', `<input type="number" data-k="execution.timeoutMinutes" data-t="num" min="1" max="1440" value="${esc(x.timeoutMinutes ?? 30)}">`)}
        ${fld('Site input name', `<input type="text" data-k="execution.siteInput" value="${esc(x.siteInput || 'Site')}">`, 'Input that selects the datacenter / vCenter.')}
        ${fld('Cloud provider (Cloud Ops items)', `<select data-k="execution.cloud"><option value="" ${!x.cloud ? 'selected' : ''}>none (vSphere / other)</option><option value="aws" ${x.cloud === 'aws' ? 'selected' : ''}>AWS</option><option value="azure" ${x.cloud === 'azure' ? 'selected' : ''}>Azure</option></select>`, 'The job authenticates against this cloud using Admin > Cloud connections. Uncheck the vCenter option below for cloud items.')}
        <div class="field wide"><label class="toggle"><input type="checkbox" data-k="execution.requiresVCenter" data-t="bool" ${x.requiresVCenter !== false ? 'checked' : ''}> Open a vCenter session for the selected site before running the script</label></div>
      </div></section>

      <section class="card fieldset"><div class="section-bar"><h2 class="section-title" style="margin:0">Fixed parameters</h2>
          <button type="button" class="btn btn-sm" id="btnAddFx">+ Add fixed parameter</button></div>
        <p class="muted" style="margin:0 0 10px">Passed to the script but never shown to the requester (e.g. template, customization spec). Use "per site" when the value differs between vCenters.</p>
        <div id="fxList">${ed.fx.length ? ed.fx.map(fxRow).join('') : '<div class="muted">None.</div>'}</div>
      </section>

      <section class="card fieldset"><div class="section-bar"><h2 class="section-title" style="margin:0">Request form inputs (${d.inputs.length})</h2>
          <button type="button" class="btn btn-sm" id="btnAddInput">+ Add input</button></div>
        <p class="muted" style="margin:0 0 10px">Each input name must match a parameter of the script. Order here is the order in the form.</p>
        <div id="inList">${d.inputs.map(inputCard).join('')}</div>
      </section>

      <details class="card fieldset"><summary class="section-title" style="cursor:pointer">Advanced: JSON definition</summary>
        <textarea id="jsonBox" class="mono" style="min-height:280px;margin-top:10px"></textarea>
        <div class="actions" style="margin-top:8px"><button type="button" class="btn btn-sm" id="btnJsonRefresh">Refresh from form</button>
          <button type="button" class="btn btn-sm" id="btnJsonApply">Apply JSON to form</button></div>
      </details>

      <div class="sticky-actions card">
        <button type="button" class="btn" id="btnValidate">Validate</button>
        <button type="button" class="btn btn-primary" id="btnSave">${ed.mode === 'create' ? 'Create item' : 'Save changes'}</button>
        <a class="btn" href="#/admin/catalog">Cancel</a>
        <span class="muted" id="saveState"></span>
      </div>`;
    wireEditor(body);
    showErrors();
  }

  function fld(label, ctl, help = '', wide = false) {
    return `<div class="field${wide ? ' wide' : ''}"><label>${label}</label>${ctl}${help ? `<div class="help">${help}</div>` : ''}</div>`;
  }

  function fxRow(f, i) {
    return `<div class="fx-row" data-fx="${i}">
      <input type="text" data-fk="name" value="${esc(f.name)}" placeholder="ParameterName">
      <label class="toggle"><input type="checkbox" data-fk="perSite" ${f.perSite ? 'checked' : ''}> per site</label>
      ${f.perSite ? `<div class="fx-sites">${ed.sites.map((s) => `<label><span class="mono">${esc(s.code)}</span><input type="text" data-fk="site:${esc(s.code)}" value="${esc(f.siteValues[s.code] ?? '')}"></label>`).join('')}</div>`
                  : `<input type="text" data-fk="value" value="${esc(f.value)}" placeholder="value">`}
      <button type="button" class="btn btn-sm btn-danger" data-fxdel="${i}">&times;</button></div>`;
  }

  function inputCard(inp, i) {
    const src = inp.source || {}, v = inp.validation || {}, vw = inp.visibleWhen || {};
    const opts = (inp.options || []).map((o) => `${o.value}|${o.label}`).join('\n');
    const isSel = inp.type === 'select';
    return `<div class="in-card" data-in="${i}">
      <div class="in-head"><b class="mono">${esc(inp.name || '(new)')}</b> <span class="tag">${esc(inp.type)}</span> ${inp.required ? '<span class="tag tag-approval">required</span>' : ''}
        <span class="in-tools"><button type="button" class="btn btn-sm" data-mv="-1">&uarr;</button><button type="button" class="btn btn-sm" data-mv="1">&darr;</button>
        <button type="button" class="btn btn-sm btn-danger" data-indel>&times;</button></span></div>
      <div class="fields three">
        ${fld('Name (script parameter)', `<input type="text" data-ik="name" value="${esc(inp.name || '')}">`)}
        ${fld('Label', `<input type="text" data-ik="label" value="${esc(inp.label || '')}">`)}
        ${fld('Type', `<select data-ik="type" data-rerender>${INPUT_TYPES.map((t) => `<option ${inp.type === t ? 'selected' : ''}>${t}</option>`).join('')}</select>`)}
        ${fld('Form section', `<input type="text" data-ik="group" value="${esc(inp.group || '')}" placeholder="General">`)}
        ${fld('Default', `<input type="text" data-ik="default" value="${esc(inp.default ?? '')}">`)}
        <div class="field"><label>&nbsp;</label><label class="toggle"><input type="checkbox" data-ik="required" ${inp.required ? 'checked' : ''}> Required</label></div>
        ${fld('Help text', `<input type="text" data-ik="help" value="${esc(inp.help || '')}">`, '', true)}
        ${isSel ? `
          ${fld('Options source', `<select data-ik="source.type" data-rerender>${SOURCE_TYPES.map((t) => `<option value="${t}" ${(src.type || '') === t ? 'selected' : ''}>${t || 'static list'}</option>`).join('')}</select>`,
                'Dynamic sources come from the vCenter inventory cache.')}
          ${src.type ? `${fld('Depends on (inputs, comma)', `<input type="text" data-ik="source.dependsOn" data-t="list" value="${esc((src.dependsOn || []).join(', '))}" placeholder="Site">`)}
                        ${fld('Filter (regex)', `<input type="text" data-ik="source.filter" value="${esc(src.filter || '')}">`)}`
                     : fld('Options (one per line: value|label)', `<textarea data-ik="options" data-t="options" placeholder="App|Application\nDB|Database">${esc(opts)}</textarea>`, '', true)}` : ''}
        ${['text', 'textarea'].includes(inp.type) ? `
          ${fld('Validation regex', `<input type="text" data-ik="validation.pattern" value="${esc(v.pattern || '')}">`)}
          ${fld('Regex error message', `<input type="text" data-ik="validation.patternMessage" value="${esc(v.patternMessage || '')}">`)}
          ${fld('Max length', `<input type="number" data-ik="validation.maxLength" data-t="num" value="${esc(v.maxLength ?? '')}">`)}
          ${fld('Transform', `<select data-ik="transform"><option value=""></option>${['upper', 'lower', 'trim'].map((t) => `<option ${inp.transform === t ? 'selected' : ''}>${t}</option>`).join('')}</select>`)}` : ''}
        ${inp.type === 'number' ? `${fld('Min', `<input type="number" data-ik="validation.min" data-t="num" value="${esc(v.min ?? '')}">`)}
                                   ${fld('Max', `<input type="number" data-ik="validation.max" data-t="num" value="${esc(v.max ?? '')}">`)}` : ''}
        ${fld('Show only when input', `<input type="text" data-ik="visibleWhen.field" value="${esc(vw.field || '')}" placeholder="IpMode">`)}
        ${fld('...equals', `<input type="text" data-ik="visibleWhen.equals" value="${esc(vw.equals ?? '')}" placeholder="Static">`)}
      </div></div>`;
  }

  /* ---- model binding ---- */
  function setPath(obj, path, value) {
    const keys = path.split('.'); let o = obj;
    keys.slice(0, -1).forEach((k) => { if (o[k] == null || typeof o[k] !== 'object') o[k] = {}; o = o[k]; });
    o[keys[keys.length - 1]] = value;
  }
  function coerce(el) {
    const t = el.dataset.t;
    if (el.type === 'checkbox' || t === 'bool') return el.checked;
    if (t === 'num') return el.value === '' ? undefined : Number(el.value);
    if (t === 'list') return el.value.split(',').map((x) => x.trim()).filter(Boolean);
    if (t === 'options') return el.value.split('\n').map((l) => l.trim()).filter(Boolean).map((l) => { const [v, ...rest] = l.split('|'); return { value: v.trim(), label: (rest.join('|') || v).trim() }; });
    return el.value;
  }

  function wireEditor(body) {
    const d = ed.draft;
    body.querySelectorAll('[data-k]').forEach((el) => el.addEventListener(el.tagName === 'SELECT' || el.type === 'checkbox' ? 'change' : 'input', () => setPath(d, el.dataset.k, coerce(el))));
    body.querySelectorAll('[data-ik]').forEach((el) => {
      const i = Number(el.closest('[data-in]').dataset.in);
      el.addEventListener(el.tagName === 'SELECT' || el.type === 'checkbox' ? 'change' : 'input', () => {
        setPath(d.inputs[i], el.dataset.ik, coerce(el));
        if (el.dataset.ik === 'name') el.closest('.in-card').querySelector('.in-head b').textContent = el.value || '(new)';
        if ('rerender' in el.dataset) { syncChecks(); renderEditor(body); }
      });
    });
    body.querySelectorAll('[data-mv]').forEach((b) => b.addEventListener('click', () => {
      const i = Number(b.closest('[data-in]').dataset.in), j = i + Number(b.dataset.mv);
      if (j < 0 || j >= d.inputs.length) return;
      [d.inputs[i], d.inputs[j]] = [d.inputs[j], d.inputs[i]]; syncChecks(); renderEditor(body);
    }));
    body.querySelectorAll('[data-indel]').forEach((b) => b.addEventListener('click', () => {
      d.inputs.splice(Number(b.closest('[data-in]').dataset.in), 1); syncChecks(); renderEditor(body);
    }));
    document.getElementById('btnAddInput').addEventListener('click', () => {
      d.inputs.push({ name: '', label: '', type: 'text', required: false, group: 'General' }); syncChecks(); renderEditor(body);
      body.querySelector('#inList .in-card:last-child input')?.focus();
    });
    // fixed parameters
    body.querySelectorAll('[data-fk]').forEach((el) => el.addEventListener(el.type === 'checkbox' ? 'change' : 'input', () => {
      const f = ed.fx[Number(el.closest('[data-fx]').dataset.fx)], k = el.dataset.fk;
      if (k === 'perSite') { f.perSite = el.checked; if (f.perSite && f.value) ed.sites.forEach((s) => { f.siteValues[s.code] = f.siteValues[s.code] ?? f.value; }); syncChecks(); renderEditor(body); }
      else if (k.startsWith('site:')) f.siteValues[k.slice(5)] = el.value;
      else f[k] = el.value;
    }));
    body.querySelectorAll('[data-fxdel]').forEach((b) => b.addEventListener('click', () => { ed.fx.splice(Number(b.dataset.fxdel), 1); syncChecks(); renderEditor(body); }));
    document.getElementById('btnAddFx').addEventListener('click', () => { ed.fx.push({ name: '', perSite: false, value: '', siteValues: {} }); syncChecks(); renderEditor(body); });
    // script helpers
    document.getElementById('btnInspect').addEventListener('click', () => inspect(body));
    document.getElementById('btnStub').addEventListener('click', () => stub(body));
    // json
    const box = document.getElementById('jsonBox');
    const refreshJson = () => { box.value = JSON.stringify(buildItem(), null, 2); };
    refreshJson();
    document.getElementById('btnJsonRefresh').addEventListener('click', refreshJson);
    document.getElementById('btnJsonApply').addEventListener('click', () => {
      try {
        const obj = JSON.parse(box.value);
        ed.draft = obj; ed.draft.inputs = obj.inputs || []; ed.draft.execution = obj.execution || {};
        ed.draft.access = obj.access || { roles: [...ROLES] }; ed.draft.approval = obj.approval || { required: false };
        ed.fx = Object.entries(obj.execution?.fixedParameters || {}).map(([name, v]) =>
          (v && typeof v === 'object') ? { name, perSite: true, value: '', siteValues: { ...v } } : { name, perSite: false, value: v ?? '', siteValues: {} });
        renderEditor(body); P().toast('JSON applied to the form.');
      } catch (e) { P().toast(`Invalid JSON: ${e.message}`); }
    });
    document.getElementById('btnValidate').addEventListener('click', () => save(body, 'validate'));
    document.getElementById('btnSave').addEventListener('click', () => save(body, ed.mode));
  }

  // Checkbox groups are read on demand (they are not bound through data-k).
  function syncChecks() {
    const d = ed.draft;
    if (!document.getElementById('apprReq')) return;
    d.access = { roles: checkedValues('accRoles'), teams: checkedValues('accTeams') };
    d.vmNotes = !!val('edVmNotes');
    d.approval = { required: val('apprReq'), approverRoles: checkedValues('apprRoles') };
    d.sites = checkedValues('edSites');
  }

  function clean(o) {
    if (Array.isArray(o)) return o.map(clean);
    if (o && typeof o === 'object') {
      const r = {};
      Object.entries(o).forEach(([k, v]) => {
        const c = clean(v);
        if (c === '' || c === undefined || c === null) return;
        if (typeof c === 'object' && !Array.isArray(c) && Object.keys(c).length === 0) return;
        r[k] = c;
      });
      return r;
    }
    return o;
  }

  function buildItem() {
    syncChecks();
    const d = JSON.parse(JSON.stringify(ed.draft));
    const fixed = {};
    ed.fx.filter((f) => f.name).forEach((f) => { fixed[f.name] = f.perSite ? { ...f.siteValues } : f.value; });
    d.execution = d.execution || {}; d.execution.fixedParameters = fixed;
    d.inputs = (d.inputs || []).map((inp) => {
      const x = { ...inp };
      if (x.type !== 'select') { delete x.options; delete x.source; }
      else if (x.source && x.source.type) delete x.options; else delete x.source;
      if (x.visibleWhen && !x.visibleWhen.field) delete x.visibleWhen;
      if (x.type === 'boolean' && typeof x.default === 'string' && x.default !== '') x.default = x.default === 'true';
      if (x.type === 'number' && x.default !== '' && x.default !== undefined && !isNaN(Number(x.default))) x.default = Number(x.default);
      return clean(x);
    });
    const out = clean(d);
    out.execution.fixedParameters = fixed;                     // keep even when empty
    if (!('enabled' in out)) out.enabled = false;
    if (!out.approval) out.approval = { required: false };
    if (out.approval.required === undefined) out.approval.required = false;
    return out;
  }

  function showErrors() {
    const box = document.getElementById('edErrors'); if (!box) return;
    box.innerHTML = ed.errors.length ? `<div class="alert alert-err"><b>Fix the following before saving:</b><ul style="margin:6px 0 0;padding-left:18px">${ed.errors.map((e) => `<li>${esc(e)}</li>`).join('')}</ul></div>` : '';
  }

  async function save(body, mode) {
    const item = buildItem();
    const st = document.getElementById('saveState'); st.textContent = mode === 'validate' ? 'Validating...' : 'Saving...';
    try {
      await P().api('/api/admin/catalog', { method: 'POST', body: { item, mode } });
      ed.errors = []; showErrors();
      if (mode === 'validate') { st.textContent = 'Valid - ready to save.'; P().toast('Definition is valid.'); return; }
      P().toast(`Catalog item ${item.id} saved${item.enabled ? ' and published' : ' (disabled)'}.`);
      location.hash = '#/admin/catalog';
    } catch (e) {
      ed.errors = e.fields?.errors || [e.message]; showErrors(); st.textContent = '';
      document.getElementById('edErrors').scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  }

  async function inspect(body) {
    const out = document.getElementById('inspectOut');
    const handler = ed.draft.execution.handler;
    if (!handler) { P().toast('Enter the script first.'); return; }
    try {
      const r = await P().api('/api/admin/handlers/inspect', { method: 'POST', body: { handler } });
      const have = new Set([...ed.draft.inputs.map((i) => i.name.toLowerCase()), ...ed.fx.map((f) => f.name.toLowerCase())]);
      const params = r.parameters.filter((p) => p.name !== 'Context');
      out.innerHTML = `<div class="inspect"><div class="muted mono" style="margin-bottom:6px">${esc(r.path)}</div>
        <table><thead><tr><th>Parameter</th><th>Type</th><th>Mandatory</th><th>Allowed values</th><th>Covered by</th><th></th></tr></thead><tbody>
        ${params.map((p) => `<tr><td class="mono">${esc(p.name)}</td><td>${esc(p.type)}</td><td>${p.mandatory ? 'Yes' : ''}</td><td>${esc((p.validateSet || []).join(', '))}</td>
          <td>${have.has(p.name.toLowerCase()) ? '<span class="tag tag-auto">configured</span>' : '<span class="tag tag-approval">missing</span>'}</td>
          <td>${have.has(p.name.toLowerCase()) ? '' : `<button type="button" class="btn btn-sm" data-addp="${esc(p.name)}">Add as input</button> <button type="button" class="btn btn-sm" data-addfx="${esc(p.name)}">Add as fixed</button>`}</td></tr>`).join('')}
        </tbody></table>${params.some((p) => !have.has(p.name.toLowerCase())) ? '<button type="button" class="btn btn-sm" id="btnAddAll" style="margin-top:8px">Add all missing as inputs</button>' : ''}</div>`;
      const toInput = (p) => {
        const label = p.name.replace(/([a-z])([A-Z])/g, '$1 $2');
        const inp = { name: p.name, label, type: 'text', required: !!p.mandatory, group: 'General' };
        if ((p.validateSet || []).length) { inp.type = 'select'; inp.options = p.validateSet.map((v) => ({ value: v, label: v })); }
        else if (/^(int|int32|int64|long|double|decimal)$/i.test(p.type)) inp.type = 'number';
        else if (/^(bool|boolean|switch)$/i.test(p.type)) inp.type = 'boolean';
        return inp;
      };
      out.querySelectorAll('[data-addp]').forEach((b) => b.addEventListener('click', () => {
        const p = params.find((q) => q.name === b.dataset.addp); syncChecks(); ed.draft.inputs.push(toInput(p)); renderEditor(body); inspect(body);
      }));
      out.querySelectorAll('[data-addfx]').forEach((b) => b.addEventListener('click', () => {
        syncChecks(); ed.fx.push({ name: b.dataset.addfx, perSite: false, value: '', siteValues: {} }); renderEditor(body); inspect(body);
      }));
      document.getElementById('btnAddAll')?.addEventListener('click', () => {
        syncChecks(); params.filter((p) => !have.has(p.name.toLowerCase())).forEach((p) => ed.draft.inputs.push(toInput(p))); renderEditor(body); inspect(body);
      });
    } catch (e) { out.innerHTML = `<div class="alert alert-err" style="margin-top:8px">${esc(e.message)}</div>`; }
  }

  async function stub(body) {
    const x = ed.draft.execution;
    if (!x.handler) { P().toast('Enter a script name first (e.g. New-MyService.ps1).'); return; }
    const parameters = [...ed.draft.inputs.map((i) => i.name), ...ed.fx.map((f) => f.name)].filter(Boolean);
    try {
      const r = await P().api('/api/admin/handlers/stub', { method: 'POST', body: { handler: x.handler, parameters, requiresVCenter: x.requiresVCenter !== false } });
      P().toast(`Skeleton created: ${r.created}`);
      const h = await P().api('/api/admin/handlers'); ed.handlers = h.handlers;
      inspect(body);
    } catch (e) { P().toast(e.message, 6000); }
  }

  /* =====================================================================================================
     vCENTER CONNECTIONS
     ===================================================================================================== */
  async function vcenters(body) {
    const [s, inv] = await Promise.all([P().api('/api/admin/sites'), P().api('/api/admin/inventory').catch(() => ({ sites: [] }))]);
    const invBy = Object.fromEntries((inv.sites || []).map((x) => [x.site, x]));
    body.innerHTML = `
      <div class="alert alert-info">Credentials are stored encrypted (Windows DPAPI) for the account that runs the portal service and are used by every automation job. Leave the password empty to keep the current one.</div>
      <div class="site-cards wide-cards">${s.sites.map((x) => siteCard(x, invBy[x.code])).join('')}
        <div class="card card-pad"><h3>Add datacenter / vCenter</h3>
          <div class="fields" style="margin-top:10px">${fld('Site code', '<input type="text" id="newCode" placeholder="DC3" maxlength="8">')}
          ${fld('vCenter FQDN', '<input type="text" id="newVc" placeholder="vcenter03.corp.example.com">')}</div>
          <button class="btn btn-sm" id="btnNewSite" style="margin-top:12px">Add site</button></div>
      </div>`;
    body.querySelectorAll('[data-save]').forEach((b) => b.addEventListener('click', () => saveSite(body, b.dataset.save)));
    body.querySelectorAll('[data-test]').forEach((b) => b.addEventListener('click', () => testSite(body, b.dataset.test, b)));
    body.querySelectorAll('[data-inv]').forEach((b) => b.addEventListener('click', async () => {
      b.disabled = true;
      try { const r = await P().api('/api/admin/inventory/refresh', { method: 'POST', body: { site: b.dataset.inv } }); P().toast(r.started.length ? `Inventory refresh started: ${r.started.join(', ')}` : 'Refresh already running.'); }
      catch (e) { P().toast(e.message); } finally { setTimeout(() => vcenters(body), 1500); }
    }));
    document.getElementById('btnNewSite').addEventListener('click', async () => {
      try {
        await P().api('/api/admin/sites', { method: 'POST', body: { code: val('newCode'), vcenter: val('newVc'), new: true } });
        P().toast('Site added (disabled until you enable it).'); vcenters(body);
      } catch (e) { P().toast(e.message, 6000); }
    });
  }

  function siteCard(x, inv) {
    const c = x.credential, t = x.lastTest, id = (k) => `s_${x.code}_${k}`;
    const clusterList = (t && t.clusters) ? `<datalist id="${id('dl')}">${t.clusters.map((n) => `<option value="${esc(n)}">`).join('')}</datalist>` : '';
    const wc = x.workloadClusters || {};
    return `<div class="card card-pad">
      <div class="section-bar"><div><h3>${esc(x.code)} <span class="muted" style="font-weight:400">${esc(x.name)}</span></h3></div>
        ${t ? (t.ok ? '<span class="pill st-Succeeded">Connected</span>' : '<span class="pill st-Failed">Connection failed</span>') : '<span class="pill st-Queued">Not tested</span>'}</div>
      <div class="fields" style="margin-top:12px">
        ${fld('vCenter FQDN / IP', `<input type="text" id="${id('vc')}" value="${esc(x.vcenter)}">`)}
        ${fld('Display name', `<input type="text" id="${id('name')}" value="${esc(x.name)}">`)}
        ${fld('Service account', `<input type="text" id="${id('user')}" value="${esc(c.username)}" placeholder="svc-portal@vsphere.local" autocomplete="off">`,
              c.configured ? `Stored${c.updatedAt ? ' ' + P().fmtDate(c.updatedAt) : ''} (encrypted)`
                : c.type === 'SecretManagement' ? `Vault reference ${esc(c.vault)}/${esc(c.secret)} - enter an account here to store it in the portal, or use Test connection.`
                : '<span style="color:var(--err)">No credential stored</span>')}
        ${fld('Password', `<input type="password" id="${id('pw')}" placeholder="${c.configured ? 'unchanged' : 'required'}" autocomplete="new-password">`)}
        ${fld('APP cluster', `<input type="text" id="${id('app')}" value="${esc(wc.App || '')}" list="${id('dl')}">`, 'Target for Workload = Application.')}
        ${fld('DB cluster', `<input type="text" id="${id('db')}" value="${esc(wc.DB || '')}" list="${id('dl')}">`, 'Target for Workload = Database.')}
        ${fld('VM folder', `<input type="text" id="${id('folder')}" value="${esc(x.vmFolder)}">`)}
        ${fld('Certificate validation', `<select id="${id('cert')}">${[['Ignore', 'Ignore - accept self-signed / VMCA'], ['Warn', 'Warn - accept and log'], ['Fail', 'Fail - require a trusted CA']].map(([o, l]) => `<option value="${o}" ${x.invalidCertificateAction === o ? 'selected' : ''}>${l}</option>`).join('')}</select>`, 'Use Fail only after the VMCA root CA is trusted on the portal server.')}
        ${fld('DNS domain', `<input type="text" id="${id('dnsd')}" value="${esc(x.dnsDomain)}">`)}
        ${fld('DNS servers (comma)', `<input type="text" id="${id('dns')}" value="${esc((x.dnsServers || []).join(', '))}">`)}
        <div class="field wide"><label class="toggle"><input type="checkbox" id="${id('en')}" ${x.enabled ? 'checked' : ''}> Site enabled (offered in request forms)</label></div>
      </div>${clusterList}
      <div class="actions" style="margin-top:14px">
        <button class="btn btn-primary btn-sm" data-save="${esc(x.code)}">Save</button>
        <button class="btn btn-sm" data-test="${esc(x.code)}">Test connection</button>
        <button class="btn btn-sm" data-inv="${esc(x.code)}" ${inv && inv.running ? 'disabled' : ''}>Refresh inventory</button></div>
      <div class="conn-result" id="${id('res')}">${t ? testResult(t) : ''}</div>
      ${inv ? `<div class="muted" style="font-size:12.5px;margin-top:10px">Inventory: ${inv.collectedAt ? `${P().fmtDate(inv.collectedAt)} (${inv.ageMinutes} min ago)` : 'never collected'}${inv.running ? ' &middot; refreshing...' : ''}
        ${inv.counts ? ` &middot; ${Object.entries(inv.counts).map(([k, v]) => `${v} ${k}`).join(', ')}` : ''}${inv.lastError ? `<br><span style="color:var(--err)">${esc(inv.lastError)}</span>` : ''}</div>` : ''}
    </div>`;
  }

  function testResult(t) {
    if (!t.ok) return `<div class="alert alert-err" style="margin:12px 0 0">${esc(t.error)}<br><span class="muted">${P().fmtDate(t.testedAt)}</span></div>`;
    const wc = Object.entries(t.workloadClusters || {}).map(([k, v]) => `${esc(k)} &rarr; <span class="mono">${esc(v.cluster || '-')}</span> ${v.found ? '<span class="tag tag-auto">found</span>' : '<span class="tag tag-approval">not found</span>'}`).join('<br>');
    return `<div class="alert alert-ok" style="margin:12px 0 0"><b>${esc(t.vcenter)}</b> &middot; vCenter ${esc(t.version)} &middot; ${esc(t.user)} &middot; ${t.durationMs} ms<br>
      Datacenters: ${esc((t.datacenters || []).join(', '))}<br>Clusters: ${esc((t.clusters || []).join(', '))}${wc ? `<br>${wc}` : ''}
      <br><span class="muted">${P().fmtDate(t.testedAt)}</span></div>`;
  }

  async function saveSite(body, code, keepOpen = false) {
    const id = (k) => `s_${code}_${k}`;
    const payload = {
      code, name: val(id('name')), vcenter: val(id('vc')), enabled: val(id('en')), invalidCertificateAction: val(id('cert')),
      workloadClusters: { App: val(id('app')), DB: val(id('db')) }, vmFolder: val(id('folder')), dnsDomain: val(id('dnsd')),
      dnsServers: val(id('dns')).split(',').map((x) => x.trim()).filter(Boolean)
    };
    const user = val(id('user')), pw = document.getElementById(id('pw')).value;
    if (pw) {
      if (!user) { P().toast('Enter the service account (e.g. svc-portal@vsphere.local).'); return false; }
      payload.username = user; payload.password = pw;
    }
    try {
      await P().api('/api/admin/sites', { method: 'POST', body: payload });
      P().toast(`${code} saved${pw ? ' (credential stored)' : ''}.`);
      if (keepOpen) { document.getElementById(id('pw')).value = ''; return true; }
      vcenters(body); return true;
    }
    catch (e) { P().toast(e.message, 6000); return false; }
  }

  async function testSite(body, code, btn) {
    const res = document.getElementById(`s_${code}_res`);
    // Unsaved credential typed in the card? Save it first so the test uses it.
    if (document.getElementById(`s_${code}_pw`).value) {
      btn.disabled = true;
      const ok = await saveSite(body, code, true);
      if (!ok) { btn.disabled = false; return; }
    }
    btn.disabled = true; const t = btn.textContent; btn.textContent = 'Testing (up to 60 s)...';
    try { const r = await P().api(`/api/admin/sites/${encodeURIComponent(code)}/test`, { method: 'POST' }); res.innerHTML = testResult(r); if (r.ok) P().toast(`${code}: connected. Inventory refresh started.`); }
    catch (e) { res.innerHTML = `<div class="alert alert-err" style="margin:12px 0 0">${esc(e.message)}</div>`; }
    finally { btn.disabled = false; btn.textContent = t; }
  }

  /* =====================================================================================================
     CUSTOMIZATION (branding, teams, role mapping, VM notes, policies) - Admin only
     ===================================================================================================== */
  const cz = { s: null };

  async function customization(body) {
    cz.s = await P().api('/api/admin/settings');
    renderCustomization(body);
  }

  function renderCustomization(body) {
    const s = cz.s, b = s.branding, rm = s.roleMapping || {}, vn = s.vmNotes || { fields: [] }, pol = s.policies;
    const colorFld = (id, label, v) => fld(label, `<div class="color-row"><input type="color" id="${id}Pick" value="${esc(v)}"><input type="text" id="${id}" value="${esc(v)}" maxlength="7"></div>`);
    body.innerHTML = `
      <div class="alert alert-info">Changes apply immediately for every user (no restart). Sign-in providers, MFA and session rules are in Identity and Security.</div>
      ${can('catalog.manage') ? `
      <section class="card fieldset"><h2 class="section-title">Branding</h2><div class="fields">
        ${fld('Product name', `<input type="text" id="bProduct" value="${esc(b.productName)}">`, 'Shown in the header, browser tab and login page.')}
        ${fld('Organization', `<input type="text" id="bOrg" value="${esc(b.organization)}">`)}
        ${fld('Tagline', `<input type="text" id="bTagline" value="${esc(b.tagline)}">`)}
        ${fld('Support contact', `<input type="text" id="bSupport" value="${esc(b.supportContact)}" placeholder="infra-support@example.com">`)}
        ${colorFld('bPrimary', 'Header color', b.primaryColor)}
        ${colorFld('bAccent', 'Accent color (buttons, links)', b.accentColor)}
        ${fld('Login message', `<input type="text" id="bLogin" value="${esc(b.loginMessage)}">`, '', true)}
        ${fld('Footer text (login page)', `<input type="text" id="bFooter" value="${esc(b.footerText)}">`, '', true)}
        <div class="field wide"><label>Logo</label>
          <div style="display:flex;gap:14px;align-items:center;flex-wrap:wrap">
            ${b.logoUrl ? `<img class="logo-preview" src="${esc(b.logoUrl)}" alt="logo">` : '<span class="muted">No logo - the organization name is shown instead.</span>'}
            <input type="file" id="bLogoFile" accept="image/png,image/jpeg,image/webp" style="max-width:280px">
            ${b.logoUrl ? '<button type="button" class="btn btn-sm btn-danger" id="bLogoRemove">Remove logo</button>' : ''}
          </div><div class="help">PNG, JPEG or WebP, max 512 KB. Transparent PNG around 280x56 px works best on the header.</div></div>
      </div></section>

      <section class="card fieldset"><div class="section-bar"><h2 class="section-title" style="margin:0">Teams</h2><button type="button" class="btn btn-sm" id="tAdd">+ Add team</button></div>
        <p class="muted" style="margin:0 0 10px">Teams decide which catalog items a user sees and which requests an Approver can decide on (e.g. Infrastructure = datacenter items, Cloud = cloud items). AD members of the listed groups join the team; local users are assigned in Local users.</p>
        <div class="team-row row-head"><span>Team id</span><span>Display name</span><span>AD groups (comma separated)</span><span></span></div>
        <div id="tList">${(s.teams || []).map((t, i) => `<div class="team-row" data-t="${i}">
          <input type="text" data-tk="id" value="${esc(t.id)}" ${(s.teamUsage || {})[t.id] ? 'readonly title="Used by catalog items"' : ''}>
          <input type="text" data-tk="name" value="${esc(t.name)}">
          <input type="text" data-tk="adGroups" value="${esc((t.adGroups || []).join(', '))}">
          <button type="button" class="btn btn-sm btn-danger" data-tdel="${i}" ${(s.teamUsage || {})[t.id] ? `disabled title="Used by: ${esc((s.teamUsage[t.id] || []).join(', '))}"` : ''}>&times;</button></div>`).join('')}</div>
      </section>


      <section class="card fieldset"><div class="section-bar"><h2 class="section-title" style="margin:0">VM notes (new builds)</h2><button type="button" class="btn btn-sm" id="nAdd">+ Add field</button></div>
        <p class="muted" style="margin:0 0 10px">Extra section on every build item that has "VM notes" enabled. Values are written to the vSphere VM notes and as <span class="mono">Note-*</span> tags on AWS / Azure.</p>
        <div class="fields" style="margin-bottom:12px">
          <div class="field"><label class="toggle"><input type="checkbox" id="nEnabled" ${vn.enabled !== false ? 'checked' : ''}> Section enabled</label></div>
          ${fld('Section title', `<input type="text" id="nTitle" value="${esc(vn.title || 'VM notes')}">`)}
        </div>
        <div class="note-row row-head"><span>Key</span><span>Label</span><span>Type</span><span>Required</span><span>Options (select, comma) / help</span><span></span></div>
        <div id="nList">${(vn.fields || []).map((f, i) => `<div class="note-row" data-n="${i}">
          <input type="text" data-nk="key" value="${esc(f.key)}">
          <input type="text" data-nk="label" value="${esc(f.label)}">
          <select data-nk="type">${['text', 'textarea', 'select'].map((t) => `<option ${f.type === t ? 'selected' : ''}>${t}</option>`).join('')}</select>
          <label class="toggle"><input type="checkbox" data-nk="required" ${f.required ? 'checked' : ''}> yes</label>
          <input type="text" data-nk="${f.type === 'select' ? 'options' : 'help'}" value="${esc(f.type === 'select' ? (f.options || []).join(', ') : (f.help || ''))}" placeholder="${f.type === 'select' ? 'Production, QA, Development' : 'help text'}">
          <span style="display:flex;gap:4px"><button type="button" class="btn btn-sm" data-nmv="-1">&uarr;</button><button type="button" class="btn btn-sm" data-nmv="1">&darr;</button><button type="button" class="btn btn-sm btn-danger" data-ndel>&times;</button></span></div>`).join('')}</div>
      </section>` : ''}
      ${can('security.manage') ? `
      <section class="card fieldset"><h2 class="section-title">Role mapping (directory groups)</h2><div class="fields">
        ${(s.roles || ROLES).map((r) => fld(`${r} groups`, `<input type="text" id="rm${r}" value="${esc((rm[r] || []).join(', '))}">`, ROLE_HELP[r] || '')).join('')}
      </div><div class="help" style="margin-top:8px">Group names (CN) from Active Directory / OpenLDAP, comma separated. Directory users need at least one role group. Admin implies every role; Approver implies Requester. Saving asks for your password.</div></section>

      <section class="card fieldset"><h2 class="section-title">Approval policy</h2><div class="fields">
        <div class="field"><label class="toggle"><input type="checkbox" id="pSelf" ${pol.allowSelfApproval ? 'checked' : ''}> Allow requesters to approve their own requests</label><div class="help">Keep disabled in production (segregation of duties).</div></div>
      </div></section>` : ''}

      <div class="sticky-actions card"><button class="btn btn-primary" id="czSave">Save customization</button><span class="muted" id="czState"></span></div>`;
    wireCustomization(body);
  }

  function readCustomization() {
    const s = cz.s;
    const rows = (sel, attr) => [...document.querySelectorAll(sel)].map((row) => { const o = {}; row.querySelectorAll(`[${attr}]`).forEach((e) => { o[e.getAttribute(attr)] = e.type === 'checkbox' ? e.checked : e.value.trim(); }); return o; });
    const out = {};
    if (can('catalog.manage')) {
      out.branding = { productName: val('bProduct'), organization: val('bOrg'), tagline: val('bTagline'), supportContact: val('bSupport'),
                       primaryColor: val('bPrimary'), accentColor: val('bAccent'), loginMessage: val('bLogin'), footerText: val('bFooter') };
      out.teams = rows('#tList .team-row', 'data-tk').map((t) => ({ id: t.id, name: t.name, adGroups: list(t.adGroups) }));
      out.vmNotes = { enabled: val('nEnabled'), title: val('nTitle'),
                      fields: rows('#nList .note-row', 'data-nk').map((f) => { const o = { key: f.key, label: f.label, type: f.type, required: !!f.required };
                        if (f.type === 'select') o.options = list(f.options); else if (f.help) o.help = f.help;
                        const prev = (s.vmNotes.fields || []).find((p) => p.key === f.key); if (prev && prev.pattern) o.pattern = prev.pattern; return o; }) };
    }
    if (can('security.manage')) {
      out.roleMapping = {}; (s.roles || ROLES).forEach((r) => { out.roleMapping[r] = list(val(`rm${r}`)); });
      out.policies = { allowSelfApproval: val('pSelf') };
    }
    return out;
  }

  function wireCustomization(body) {
    const keep = () => { const r = readCustomization(); ['teams', 'vmNotes', 'roleMapping'].forEach((k) => { if (r[k]) cz.s[k] = r[k]; });
      if (r.policies) cz.s.policies = Object.assign({}, cz.s.policies, r.policies);
      if (r.branding) cz.s.branding = Object.assign({}, cz.s.branding, r.branding); };
    if (!can('catalog.manage')) {
      document.getElementById('czSave').addEventListener('click', async () => {
        try { cz.s = await P().api('/api/admin/settings', { method: 'POST', body: readCustomization() }); P().toast('Saved.'); renderCustomization(body); }
        catch (e) { P().toast(e.message, 7000); }
      });
      return;
    }
    ['bPrimary', 'bAccent'].forEach((id) => {
      const pick = document.getElementById(`${id}Pick`), txt = document.getElementById(id);
      pick.addEventListener('input', () => { txt.value = pick.value; window.applyBranding(Object.assign({}, cz.s.branding, { [id === 'bPrimary' ? 'primaryColor' : 'accentColor']: pick.value })); });
      txt.addEventListener('input', () => { if (/^#[0-9a-fA-F]{6}$/.test(txt.value)) { pick.value = txt.value; pick.dispatchEvent(new Event('input')); } });
    });
    document.getElementById('tAdd').addEventListener('click', () => { keep(); cz.s.teams.push({ id: '', name: '', adGroups: [] }); renderCustomization(body); });
    body.querySelectorAll('[data-tdel]').forEach((b) => b.addEventListener('click', () => { keep(); cz.s.teams.splice(Number(b.dataset.tdel), 1); renderCustomization(body); }));
    document.getElementById('nAdd').addEventListener('click', () => { keep(); cz.s.vmNotes.fields.push({ key: '', label: '', type: 'text', required: false }); renderCustomization(body); });
    body.querySelectorAll('[data-ndel]').forEach((b) => b.addEventListener('click', () => { keep(); cz.s.vmNotes.fields.splice(Number(b.closest('[data-n]').dataset.n), 1); renderCustomization(body); }));
    body.querySelectorAll('[data-nmv]').forEach((b) => b.addEventListener('click', () => {
      keep(); const f = cz.s.vmNotes.fields, i = Number(b.closest('[data-n]').dataset.n), j = i + Number(b.dataset.nmv);
      if (j < 0 || j >= f.length) return; [f[i], f[j]] = [f[j], f[i]]; renderCustomization(body);
    }));
    body.querySelectorAll('#nList select[data-nk="type"]').forEach((sel) => sel.addEventListener('change', () => { keep(); renderCustomization(body); }));
    const logoInput = document.getElementById('bLogoFile');
    logoInput.addEventListener('change', () => {
      const f = logoInput.files[0]; if (!f) return;
      if (f.size > 512 * 1024) { P().toast('Logo must be 512 KB or smaller.'); return; }
      const rd = new FileReader();
      rd.onload = async () => {
        try {
          keep();                                   // keep unsaved edits on the page
          const br = await P().api('/api/admin/settings/logo', { method: 'POST', body: { dataUrl: rd.result } });
          cz.s.branding.logoUrl = br.logoUrl; window.applyBranding(Object.assign({}, br, readCustomization().branding));
          P().toast('Logo updated.'); renderCustomization(body);
        }
        catch (e) { P().toast(e.message, 6000); }
      };
      rd.readAsDataURL(f);
    });
    document.getElementById('bLogoRemove')?.addEventListener('click', async () => {
      try { keep(); const br = await P().api('/api/admin/settings/logo', { method: 'POST', body: { dataUrl: '' } }); cz.s.branding.logoUrl = ''; window.applyBranding(Object.assign({}, br, readCustomization().branding)); P().toast('Logo removed.'); renderCustomization(body); }
      catch (e) { P().toast(e.message); }
    });
    document.getElementById('czSave').addEventListener('click', async () => {
      const st = document.getElementById('czState'); st.textContent = 'Saving...';
      try {
        cz.s = await P().api('/api/admin/settings', { method: 'POST', body: readCustomization() });
        window.applyBranding(cz.s.branding);
        const me = P().state.me; if (me) me.teams = (cz.s.teams || []).map((t) => ({ id: t.id, name: t.name }));
        P().toast('Customization saved.'); renderCustomization(body);
      } catch (e) { st.textContent = ''; P().toast(e.message, 7000); }
    });
  }

  /* =====================================================================================================
     CLOUD CONNECTIONS (AWS VPC / Azure VNet)
     ===================================================================================================== */
  const lines = (arr) => (arr || []).join('\n');
  const splitList = (v) => v.split(/[\n,]/).map((x) => x.trim()).filter(Boolean);

  async function clouds(body) {
    const r = await P().api('/api/admin/clouds');
    const aws = r.clouds.find((c) => c.provider === 'aws'), az = r.clouds.find((c) => c.provider === 'azure');
    body.innerHTML = `
      <div class="alert alert-info">Cloud Ops items deploy into these landing zones. Secrets are stored encrypted (DPAPI) for the portal service account and never returned to the browser; leave a secret empty to keep the current one.</div>
      <div class="site-cards wide-cards">${awsCard(aws)}${azureCard(az)}</div>`;
    body.querySelectorAll('[data-csave]').forEach((b) => b.addEventListener('click', () => saveCloud(body, b.dataset.csave)));
    body.querySelectorAll('[data-ctest]').forEach((b) => b.addEventListener('click', () => testCloud(body, b.dataset.ctest, b)));
  }

  const statusPill = (c) => !c.enabled ? '<span class="pill st-Cancelled">Disabled</span>'
    : c.lastTest ? (c.lastTest.ok ? '<span class="pill st-Succeeded">Connected</span>' : (c.lastTest.connected ? '<span class="pill st-PendingApproval">Check warnings</span>' : '<span class="pill st-Failed">Connection failed</span>'))
    : '<span class="pill st-Queued">Not tested</span>';

  function awsCard(c) {
    const im = c.images || {}, w = im.Windows2025 || {}, a = im.AlmaLinux || {};
    return `<div class="card card-pad">
      <div class="section-bar"><h3>AWS <span class="muted" style="font-weight:400">VPC landing zone</span></h3>${statusPill(c)}</div>
      <div class="fields" style="margin-top:12px">
        <div class="field wide"><label class="toggle"><input type="checkbox" id="aws_enabled" ${c.enabled ? 'checked' : ''}> Enabled (AWS items can be requested)</label></div>
        ${fld('Authentication', `<select id="aws_authMode">${[['AccessKey', 'Access key (IAM user)'], ['DefaultChain', 'Instance profile / environment']].map(([v, l]) => `<option value="${v}" ${c.authMode === v ? 'selected' : ''}>${l}</option>`).join('')}</select>`)}
        ${fld('Region', `<input type="text" id="aws_region" value="${esc(c.region)}" placeholder="us-east-1">`)}
        ${fld('Access key id', `<input type="text" id="aws_accessKeyId" value="${esc(c.accessKeyId)}" autocomplete="off">`)}
        ${fld('Secret access key', `<input type="password" id="aws_secret" placeholder="${c.secretConfigured ? 'stored - unchanged' : 'required for Access key'}" autocomplete="new-password">`)}
        ${fld('Assume role ARN (optional)', `<input type="text" id="aws_roleArn" value="${esc(c.roleArn)}" placeholder="arn:aws:iam::123456789012:role/SspPortalProvisioner">`, '', true)}
        ${fld('VPC id', `<input type="text" id="aws_vpcId" value="${esc(c.vpcId)}" placeholder="vpc-0123456789abcdef0">`)}
        ${fld('Key pair name', `<input type="text" id="aws_keyPairName" value="${esc(c.keyPairName)}">`)}
        ${fld('Subnets (one per line: subnet-id|label)', `<textarea id="aws_subnets" placeholder="subnet-0abc...|private-app-a">${esc(lines((c.subnets || []).map((x) => `${x.id}${x.label ? '|' + x.label : ''}`)))}</textarea>`, 'Offered to requesters. Must belong to the VPC.')}
        ${fld('Security group ids (comma / line)', `<textarea id="aws_sgs" placeholder="sg-0abc...">${esc(lines(c.securityGroupIds))}</textarea>`)}
        ${fld('Allowed instance types', `<input type="text" id="aws_types" value="${esc((c.instanceTypes || []).join(', '))}">`, '', true)}
        ${fld('Windows Server 2025 image (SSM parameter)', `<input type="text" id="aws_winSsm" value="${esc(w.ssmParameter || '')}">`, 'AWS-published latest AMI. Or pin an AMI id:')}
        ${fld('Windows Server 2025 AMI id (optional pin)', `<input type="text" id="aws_winAmi" value="${esc(w.amiId || '')}" placeholder="ami-...">`)}
        ${fld('AlmaLinux AMI id (optional pin)', `<input type="text" id="aws_almaAmi" value="${esc(a.amiId || '')}" placeholder="ami-...">`, 'Empty = newest image of the AlmaLinux owner account matching the pattern.')}
        ${fld('AlmaLinux image name pattern', `<input type="text" id="aws_almaPattern" value="${esc(a.namePattern || '')}">`)}
      </div>
      <div class="actions" style="margin-top:14px"><button class="btn btn-primary btn-sm" data-csave="aws">Save</button><button class="btn btn-sm" data-ctest="aws">Test connection</button></div>
      <div id="aws_res">${cloudResult(c.lastTest)}</div></div>`;
  }

  function azureCard(c) {
    const im = c.images || {}, w = im.Windows2025 || {}, a = im.AlmaLinux || {};
    return `<div class="card card-pad">
      <div class="section-bar"><h3>Azure <span class="muted" style="font-weight:400">VNet landing zone</span></h3>${statusPill(c)}</div>
      <div class="fields" style="margin-top:12px">
        <div class="field wide"><label class="toggle"><input type="checkbox" id="az_enabled" ${c.enabled ? 'checked' : ''}> Enabled (Azure items can be requested)</label></div>
        ${fld('Authentication', `<select id="az_authMode">${[['ServicePrincipal', 'Service principal (client secret)'], ['ManagedIdentity', 'Managed identity']].map(([v, l]) => `<option value="${v}" ${c.authMode === v ? 'selected' : ''}>${l}</option>`).join('')}</select>`)}
        ${fld('Location', `<input type="text" id="az_location" value="${esc(c.location)}" placeholder="eastus">`)}
        ${fld('Tenant id', `<input type="text" id="az_tenantId" value="${esc(c.tenantId)}">`)}
        ${fld('Subscription id', `<input type="text" id="az_subscriptionId" value="${esc(c.subscriptionId)}">`)}
        ${fld('Client (application) id', `<input type="text" id="az_clientId" value="${esc(c.clientId)}" autocomplete="off">`)}
        ${fld('Client secret', `<input type="password" id="az_secret" placeholder="${c.secretConfigured ? 'stored - unchanged' : 'required for service principal'}" autocomplete="new-password">`)}
        ${fld('Resource group (VMs)', `<input type="text" id="az_resourceGroup" value="${esc(c.resourceGroup)}">`)}
        ${fld('VNet resource group', `<input type="text" id="az_vnetResourceGroup" value="${esc(c.vnetResourceGroup)}" placeholder="same as VMs">`)}
        ${fld('VNet name', `<input type="text" id="az_vnetName" value="${esc(c.vnetName)}">`)}
        ${fld('NSG name (optional)', `<input type="text" id="az_nsgName" value="${esc(c.nsgName)}">`)}
        ${fld('Subnets offered (comma / line)', `<textarea id="az_subnets" placeholder="snet-app">${esc(lines(c.subnets))}</textarea>`)}
        ${fld('Allowed VM sizes', `<textarea id="az_sizes">${esc(lines(c.vmSizes))}</textarea>`)}
        ${fld('Admin username', `<input type="text" id="az_adminUsername" value="${esc(c.adminUsername)}">`)}
        ${fld('Key Vault (Windows admin passwords)', `<input type="text" id="az_keyVaultName" value="${esc(c.keyVaultName)}">`)}
        ${fld('SSH public key (AlmaLinux)', `<textarea id="az_ssh" placeholder="ssh-rsa AAAA...">${esc(c.sshPublicKey || '')}</textarea>`, '', true)}
        ${fld('Windows Server 2025 image URN', `<input type="text" id="az_winUrn" value="${esc(w.urn || '')}">`, '', true)}
        ${fld('AlmaLinux image URN', `<input type="text" id="az_almaUrn" value="${esc(a.urn || '')}">`, 'Marketplace plan is attached and terms accepted automatically.', true)}
      </div>
      <div class="actions" style="margin-top:14px"><button class="btn btn-primary btn-sm" data-csave="azure">Save</button><button class="btn btn-sm" data-ctest="azure">Test connection</button></div>
      <div id="azure_res">${cloudResult(c.lastTest)}</div></div>`;
  }

  function cloudResult(t) {
    if (!t) return '';
    if (!t.connected && !t.ok) return `<div class="alert alert-err" style="margin:12px 0 0">${esc(t.error)}<br><span class="muted">${P().fmtDate(t.testedAt)}</span></div>`;
    return `<div class="alert ${t.ok ? 'alert-ok' : 'alert-err'}" style="margin:12px 0 0"><b>${esc(t.identity)}</b> &middot; ${esc(t.scope)} &middot; ${t.durationMs} ms
      <ul style="margin:6px 0 0;padding-left:18px">${(t.checks || []).map((c) => `<li>${c.ok ? '&#10003;' : '&#10007;'} ${esc(c.name)} <span class="muted">${esc(c.detail || '')}</span></li>`).join('')}</ul>
      <span class="muted">${P().fmtDate(t.testedAt)}</span></div>`;
  }

  function cloudPayload(provider) {
    if (provider === 'aws') {
      return { provider, secret: document.getElementById('aws_secret').value, settings: {
        enabled: val('aws_enabled'), authMode: val('aws_authMode'), region: val('aws_region'), accessKeyId: val('aws_accessKeyId'), roleArn: val('aws_roleArn'),
        vpcId: val('aws_vpcId'), keyPairName: val('aws_keyPairName'),
        subnets: document.getElementById('aws_subnets').value.split('\n').map((l) => l.trim()).filter(Boolean).map((l) => { const [id, ...lab] = l.split('|'); return { id: id.trim(), label: lab.join('|').trim() }; }),
        securityGroupIds: splitList(document.getElementById('aws_sgs').value), instanceTypes: splitList(val('aws_types')),
        images: { Windows2025: { ssmParameter: val('aws_winSsm'), amiId: val('aws_winAmi') },
                  AlmaLinux: { ssmParameter: '', amiId: val('aws_almaAmi'), ownerId: '764336703387', namePattern: val('aws_almaPattern') } } } };
    }
    return { provider, secret: document.getElementById('az_secret').value, settings: {
      enabled: val('az_enabled'), authMode: val('az_authMode'), location: val('az_location'), tenantId: val('az_tenantId'), subscriptionId: val('az_subscriptionId'),
      clientId: val('az_clientId'), resourceGroup: val('az_resourceGroup'), vnetResourceGroup: val('az_vnetResourceGroup'), vnetName: val('az_vnetName'),
      nsgName: val('az_nsgName'), subnets: splitList(document.getElementById('az_subnets').value), vmSizes: splitList(document.getElementById('az_sizes').value),
      adminUsername: val('az_adminUsername'), keyVaultName: val('az_keyVaultName'), sshPublicKey: document.getElementById('az_ssh').value.trim(),
      images: { Windows2025: { urn: val('az_winUrn'), plan: false }, AlmaLinux: { urn: val('az_almaUrn'), plan: true } } } };
  }

  async function saveCloud(body, provider, keepOpen = false) {
    try {
      await P().api('/api/admin/clouds', { method: 'POST', body: cloudPayload(provider) });
      P().toast(`${provider === 'aws' ? 'AWS' : 'Azure'} settings saved.`);
      if (!keepOpen) clouds(body);
      return true;
    } catch (e) { P().toast(e.message, 6000); return false; }
  }

  async function testCloud(body, provider, btn) {
    btn.disabled = true;
    if (!(await saveCloud(body, provider, true))) { btn.disabled = false; return; }   // test what is on screen
    const t = btn.textContent; btn.textContent = 'Testing (up to 90 s)...';
    const res = document.getElementById(`${provider}_res`);
    try { const r = await P().api(`/api/admin/clouds/${provider}/test`, { method: 'POST' }); res.innerHTML = cloudResult(r); }
    catch (e) { res.innerHTML = `<div class="alert alert-err" style="margin:12px 0 0">${esc(e.message)}</div>`; }
    finally { btn.disabled = false; btn.textContent = t; }
  }

  /* =====================================================================================================
     LOCAL USERS
     ===================================================================================================== */
  async function users(body, editName) {
    const r = await P().api('/api/admin/users');
    const editing = editName ? r.users.find((u) => u.username === editName) : null;
    const u = editing || { username: '', displayName: '', email: '', roles: ['Requester'], teams: [], enabled: true, mustChangePassword: true, breakGlass: false };
    body.innerHTML = `
      <div class="alert alert-info">Local accounts sign in on the same page as directory users. Use them for first setup and break-glass;
        production access should come from directory groups (Admin &gt; Customization &gt; Role mapping). Changes ask for your password.</div>
      <div class="two-col">
        <section class="card"><div class="table-wrap"><table><thead><tr><th>Username</th><th>Name</th><th>Roles</th><th>Teams</th><th>MFA</th><th>Status</th><th>Password changed</th><th></th></tr></thead>
          <tbody>${r.users.map((x) => `<tr><td class="mono">${esc(x.username)}${`LOCAL\\${x.username}` === r.me ? ' <span class="tag">you</span>' : ''}
              ${x.breakGlass ? ' <span class="tag tag-approval" title="Works when local sign-in is disabled; every use is alerted">break-glass</span>' : ''}</td>
            <td>${esc(x.displayName)}<div class="muted" style="font-size:12px">${esc(x.email)}</div></td>
            <td>${esc(x.roles.join(', '))}</td><td>${esc((x.teams || []).join(', ') || '-')}</td>
            <td>${x.mfaEnrolled ? '<span class="tag tag-auto">On</span>' : '<span class="tag">Off</span>'}</td>
            <td>${x.enabled ? '<span class="tag tag-auto">Enabled</span>' : '<span class="tag">Disabled</span>'}${x.mustChangePassword ? '<div class="muted" style="font-size:11px">must change password</div>' : ''}</td>
            <td>${P().fmtDate(x.passwordChangedAt || x.createdAt)}</td>
            <td class="row-actions"><button class="btn btn-sm" data-edit="${esc(x.username)}">Edit</button>
              <button class="btn btn-sm btn-danger" data-udel="${esc(x.username)}">Delete</button></td></tr>`).join('')}</tbody></table></div></section>
        <aside class="card card-pad aside">
          <h2 class="section-title">${editing ? `Edit ${esc(u.username)}` : 'New local user'}</h2>
          <div class="stack">
            ${fld('Username', `<input type="text" id="uName" value="${esc(u.username)}" ${editing ? 'readonly' : ''} autocomplete="off">`, '3-32 characters. Signs in as this name (or LOCAL\\name).')}
            ${fld('Display name', `<input type="text" id="uDisp" value="${esc(u.displayName)}">`)}
            ${fld('Email', `<input type="text" id="uMail" value="${esc(u.email)}">`)}
            <div class="field"><label>Roles</label><div class="checks">${roleBoxes('uRoles', u.roles, r.roles || ROLES)}</div><div class="help">Hover a role for its scope. Admin implies every role.</div></div>
            <div class="field"><label>Teams</label><div class="checks">${teamBoxes('uTeams', u.teams || [])}</div><div class="help">Catalog items are shown per team (e.g. Infrastructure = datacenter items, Cloud = cloud items).</div></div>
            ${fld(editing ? 'New password (optional)' : 'Password', '<input type="password" id="uPw" autocomplete="new-password">', 'Must follow the password policy (Admin > Security).')}
            ${fld('Confirm password', '<input type="password" id="uPw2" autocomplete="new-password">')}
            <label class="toggle"><input type="checkbox" id="uMust" ${u.mustChangePassword ? 'checked' : ''}> Must change password at next sign-in</label>
            <label class="toggle"><input type="checkbox" id="uBg" ${u.breakGlass ? 'checked' : ''}> Break-glass account</label>
            <label class="toggle"><input type="checkbox" id="uEn" ${u.enabled ? 'checked' : ''}> Enabled</label>
            <div class="actions"><button class="btn btn-primary" id="uSave">${editing ? 'Save changes' : 'Create user'}</button>
              ${editing ? '<button class="btn" id="uCancel">Cancel</button>' : ''}
              ${editing && editing.mfaEnrolled ? '<button class="btn btn-danger" id="uMfa">Reset MFA</button>' : ''}</div>
          </div>
        </aside>
      </div>`;
    body.querySelectorAll('[data-edit]').forEach((b) => b.addEventListener('click', () => users(body, b.dataset.edit)));
    document.getElementById('uCancel')?.addEventListener('click', () => users(body));
    document.getElementById('uMfa')?.addEventListener('click', async (ev) => {
      if (!armed(ev.target, 'Confirm reset')) return;
      try { await P().api('/api/admin/security/mfa/reset', { method: 'POST', body: { username: `LOCAL\\${editing.username}` } }); P().toast('Authenticator removed; the user enrols again at next sign-in.'); users(body, editing.username); }
      catch (e) { P().toast(e.message, 6000); }
    });
    body.querySelectorAll('[data-udel]').forEach((b) => b.addEventListener('click', async () => {
      if (!armed(b, 'Confirm')) return;
      try { await P().api(`/api/admin/users/${encodeURIComponent(b.dataset.udel)}`, { method: 'DELETE' }); P().toast('User deleted.'); users(body); }
      catch (e) { P().toast(e.message, 6000); }
    }));
    document.getElementById('uSave').addEventListener('click', async () => {
      const pw = document.getElementById('uPw').value, pw2 = document.getElementById('uPw2').value;
      if (pw !== pw2) { P().toast('Passwords do not match.'); return; }
      const roles = checkedValues('uRoles');
      if (!roles.length) { P().toast('Select at least one role.'); return; }
      const payload = { username: val('uName'), displayName: val('uDisp'), email: val('uMail'), roles, teams: checkedValues('uTeams'), enabled: val('uEn'),
                        mustChangePassword: val('uMust'), breakGlass: val('uBg'), new: !editing };
      if (pw) payload.password = pw;
      try { await P().api('/api/admin/users', { method: 'POST', body: payload }); P().toast(editing ? 'User updated.' : 'User created.'); users(body); }
      catch (e) { P().toast(e.message, 6000); }
    });
  }

  /* =====================================================================================================
     IDENTITY (local accounts + Active Directory / OpenLDAP providers)
     ===================================================================================================== */
  const idn = { d: null, edit: false };
  const FLAVOR_DEFAULTS = {
    ad: { port: 636, security: 'ldaps', bindMode: 'direct', groupMode: 'nested', userFilter: '(&(objectCategory=person)(objectClass=user)(sAMAccountName={0}))', groupFilter: '' },
    openldap: { port: 636, security: 'ldaps', bindMode: 'search', groupMode: 'search', userFilter: '(&(objectClass=inetOrgPerson)(uid={0}))',
                groupFilter: '(|(&(objectClass=groupOfNames)(member={dn}))(&(objectClass=groupOfUniqueNames)(uniqueMember={dn}))(&(objectClass=posixGroup)(memberUid={uid})))' }
  };

  async function identity(body) {
    idn.d = await P().api('/api/admin/identity');
    idn.edit = false;
    renderIdentity(body);
  }

  function renderIdentity(body) {
    const d = idn.d;
    const rows = (d.providers || []).map((p) => `<tr><td class="mono">${esc(p.id)}${p.id === d.defaultProvider ? ' <span class="tag">default</span>' : ''}</td>
      <td>${esc(p.name || '')}</td><td>${p.flavor === 'ad' ? 'Active Directory' : 'OpenLDAP'}</td>
      <td class="mono">${esc((p.hosts || []).join(', '))}:${esc(p.port)} <span class="tag">${esc(p.security)}</span></td>
      <td class="mono">${esc((p.domains || []).join(', '))}</td>
      <td>${p.enabled ? '<span class="tag tag-auto">Enabled</span>' : '<span class="tag">Disabled</span>'}</td>
      <td class="row-actions"><button class="btn btn-sm" data-pedit="${esc(p.id)}">Edit</button><button class="btn btn-sm" data-ptest="${esc(p.id)}">Test</button>
        <button class="btn btn-sm btn-danger" data-pdel="${esc(p.id)}">Delete</button></td></tr>`).join('');
    body.innerHTML = `
      <section class="card card-pad">
        <div class="section-bar"><h2 class="section-title" style="margin:0">Sign-in providers</h2><button class="btn btn-primary" id="pNew">+ Add directory</button></div>
        <p class="muted" style="margin:0 0 10px">Users type <span class="mono">user</span>, <span class="mono">DOMAIN\\user</span> or <span class="mono">user@domain</span>.
          A bare name signs in as a local account when one exists, otherwise with the default provider. Connections are always encrypted (LDAPS or StartTLS${d.platform === 'windows' ? '; Kerberos/NTLM sealing for AD on Windows' : ''}).</p>
        <div class="table-wrap"><table><thead><tr><th>Id</th><th>Name</th><th>Type</th><th>Servers</th><th>Domains</th><th>Status</th><th></th></tr></thead>
          <tbody>${rows || '<tr><td colspan="7" class="muted">No directory configured - only local accounts can sign in.</td></tr>'}</tbody></table></div>
        <div id="pTestOut"></div>
        <div class="fields" style="margin-top:14px">
          ${fld('Default provider (bare usernames)', `<select id="pDefault"><option value="">(none)</option>${(d.providers || []).map((p) => `<option ${p.id === d.defaultProvider ? 'selected' : ''}>${esc(p.id)}</option>`).join('')}</select>`)}
          <div class="field"><label class="toggle"><input type="checkbox" id="pLocal" ${d.localUsersEnabled ? 'checked' : ''}> Local accounts enabled</label>
            <div class="help">When disabled only break-glass accounts (Admin &gt; Local users) can sign in locally.</div></div>
        </div>
        <button class="btn" id="pOpts">Save options</button>
      </section>
      <section class="card card-pad" id="pEditor" style="margin-top:16px"></section>
      <section class="card card-pad" style="margin-top:16px">
        <h2 class="section-title">Sign-in simulation</h2>
        <p class="muted" style="margin:0 0 10px">Checks an account against its provider and shows the groups, roles and teams it would get. No session is created.</p>
        <div class="inline"><input type="text" id="simUser" placeholder="DOMAIN\\user or user@domain" style="width:260px">
          <input type="password" id="simPw" placeholder="password" style="width:200px" autocomplete="off"><button class="btn" id="simGo">Simulate</button></div>
        <div id="simOut" style="margin-top:12px"></div>
      </section>`;
    document.getElementById('pNew').addEventListener('click', () => providerEditor(body, null));
    body.querySelectorAll('[data-pedit]').forEach((b) => b.addEventListener('click', () => providerEditor(body, d.providers.find((p) => p.id === b.dataset.pedit))));
    body.querySelectorAll('[data-pdel]').forEach((b) => b.addEventListener('click', async () => {
      if (!armed(b, 'Confirm')) return;
      try { await P().api(`/api/admin/identity/${encodeURIComponent(b.dataset.pdel)}`, { method: 'DELETE' }); P().toast('Provider deleted.'); identity(body); } catch (e) { P().toast(e.message, 6000); }
    }));
    body.querySelectorAll('[data-ptest]').forEach((b) => b.addEventListener('click', async () => {
      const out = document.getElementById('pTestOut'); out.innerHTML = '<div class="muted" style="margin-top:10px">Testing...</div>';
      try { out.innerHTML = stepsHtml(await P().api(`/api/admin/identity/${encodeURIComponent(b.dataset.ptest)}/test`, { method: 'POST', body: {} })); }
      catch (e) { out.innerHTML = `<div class="alert alert-err" style="margin-top:10px">${esc(e.message)}</div>`; }
    }));
    document.getElementById('pOpts').addEventListener('click', async () => {
      try { await P().api('/api/admin/identity/options', { method: 'POST', body: { defaultProvider: val('pDefault'), localUsersEnabled: val('pLocal') } }); P().toast('Options saved.'); identity(body); }
      catch (e) { P().toast(e.message, 6000); }
    });
    document.getElementById('simGo').addEventListener('click', async () => {
      const out = document.getElementById('simOut'); out.innerHTML = '<span class="muted">Checking...</span>';
      try {
        const r = await P().api('/api/admin/identity/simulate', { method: 'POST', body: { username: val('simUser'), password: document.getElementById('simPw').value } });
        document.getElementById('simPw').value = '';
        out.innerHTML = r.ok ? `<dl class="kv"><dt>Provider</dt><dd class="mono">${esc(r.provider)}</dd><dt>Portal user</dt><dd class="mono">${esc(r.username)}</dd>
            <dt>Groups</dt><dd><div class="chip-list">${(r.groups || []).map((g) => `<span class="tag">${esc(g)}</span>`).join('') || '-'}</div></dd>
            <dt>Roles</dt><dd>${(r.roles || []).join(', ') || '<b>none - cannot sign in</b>'}</dd><dt>Teams</dt><dd>${(r.teams || []).join(', ') || '-'}</dd>
            <dt>MFA</dt><dd>${r.mfaRequired ? 'required for this role' : 'optional'}</dd></dl>`
          : `<div class="alert alert-err">${esc(r.provider)}: ${esc(r.message)}</div>`;
      } catch (e) { out.innerHTML = `<div class="alert alert-err">${esc(e.message)}</div>`; }
    });
    if (idn.edit !== false) providerEditor(body, idn.edit); else document.getElementById('pEditor').classList.add('hidden');
  }

  function stepsHtml(t) {
    return `<ul class="steps-result">${(t.steps || []).map((s) => `<li>${dot(s.ok ? 'ok' : 'bad')}${esc(s.step)}${s.groups ? ` <span class="muted">groups: ${esc(s.groups.join(', '))}</span>` : ''}</li>`).join('')}
      <li class="muted">${t.ok ? 'OK' : 'Failed'} in ${esc(t.elapsedMs)} ms</li></ul>`;
  }

  function providerEditor(body, p) {
    idn.edit = p;
    const ed2 = document.getElementById('pEditor'); ed2.classList.remove('hidden');
    const isNew = !p;
    const x = Object.assign({ id: '', name: '', enabled: true, flavor: 'ad', domains: [], hosts: [], tls: { verify: true, caFile: '' }, attributes: {} }, FLAVOR_DEFAULTS[(p && p.flavor) || 'ad'], p || {});
    const sel = (id, opts, v) => `<select id="${id}">${opts.map(([k, l]) => `<option value="${k}" ${String(v) === String(k) ? 'selected' : ''}>${l}</option>`).join('')}</select>`;
    ed2.innerHTML = `<h2 class="section-title">${isNew ? 'New directory' : `Edit ${esc(x.id)}`}</h2>
      <div class="fields">
        ${fld('Id', `<input type="text" id="xId" value="${esc(x.id)}" ${isNew ? '' : 'readonly'} placeholder="corp">`, 'Lowercase, used in logs and as default username prefix.')}
        ${fld('Display name', `<input type="text" id="xName" value="${esc(x.name)}" placeholder="Corporate AD">`)}
        ${fld('Type', sel('xFlavor', [['ad', 'Active Directory'], ['openldap', 'OpenLDAP / other LDAP v3']], x.flavor))}
        ${fld('Domains (login routing)', `<input type="text" id="xDomains" value="${esc((x.domains || []).join(', '))}" placeholder="corp.example.com, CORP">`, 'user@domain and DOMAIN\\user are sent to this provider.')}
        ${fld('Servers', `<input type="text" id="xHosts" value="${esc((x.hosts || []).join(', '))}" placeholder="dc01.corp.example.com, dc02.corp.example.com">`, 'Tried in order.')}
        ${fld('Security', sel('xSec', [['ldaps', 'LDAPS (636)'], ['starttls', 'StartTLS (389)'], ...(idn.d.platform === 'windows' ? [['negotiate', 'Kerberos/NTLM sign+seal (389, Windows + AD)']] : [])], x.security))}
        ${fld('Port', `<input type="number" id="xPort" value="${esc(x.port)}">`)}
        ${fld('Base DN', `<input type="text" id="xBase" value="${esc(x.baseDn || '')}" placeholder="DC=corp,DC=example,DC=com">`)}
        ${fld('Bind mode', sel('xBind', [['direct', 'Direct: bind as the user (AD, no service account)'], ['search', 'Search: service account finds the user, then binds as the user']], x.bindMode))}
        ${fld('Service account (vault)', sel('xCred', [['', '(none)'], ...(idn.d.bindCredentials || []).map((c) => [c.id, `${c.name} (${c.username})`])], x.bindCredential || ''), 'Vault entry with system scope (Admin > Vault). Required for search mode.')}
        ${fld('UPN suffix (direct bind)', `<input type="text" id="xUpn" value="${esc(x.upnSuffix || '')}" placeholder="corp.example.com">`)}
        ${fld('Username prefix', `<input type="text" id="xPrefix" value="${esc(x.usernamePrefix || '')}" placeholder="CORP">`, 'Portal usernames become PREFIX\\user.')}
        ${fld('User filter', `<input type="text" id="xUserF" class="mono" value="${esc(x.userFilter)}">`, '{0} = login name (escaped).', true)}
        ${fld('Group membership', sel('xGroupMode', [['nested', 'Nested (AD transitive)'], ['memberOf', 'memberOf attribute'], ['search', 'Search group filter']], x.groupMode))}
        ${fld('Group base DN (optional)', `<input type="text" id="xGroupBase" value="${esc(x.groupBaseDn || '')}">`)}
        ${fld('Group filter (search mode)', `<input type="text" id="xGroupF" class="mono" value="${esc(x.groupFilter || '')}">`, '{dn} = user DN, {uid} = user id.', true)}
        ${fld('CA certificate file (Linux)', `<input type="text" id="xCa" value="${esc((x.tls || {}).caFile || '')}" placeholder="/etc/ssp/ca/ldap-ca.pem">`, 'PEM bundle of the CA that signed the directory certificate.')}
        <div class="field"><label class="toggle"><input type="checkbox" id="xVerify" ${(x.tls || {}).verify !== false ? 'checked' : ''}> Verify server certificate</label><div class="help">Disable only in a lab.</div></div>
        <div class="field"><label class="toggle"><input type="checkbox" id="xEnabled" ${x.enabled ? 'checked' : ''}> Enabled</label></div>
      </div>
      <div class="actions" style="margin-top:12px"><button class="btn btn-primary" id="xSave">${isNew ? 'Create provider' : 'Save provider'}</button><button class="btn" id="xCancel">Close</button></div>`;
    document.getElementById('xFlavor').addEventListener('change', () => {
      const d2 = FLAVOR_DEFAULTS[val('xFlavor')];
      document.getElementById('xUserF').value = d2.userFilter; document.getElementById('xGroupF').value = d2.groupFilter;
      document.getElementById('xBind').value = d2.bindMode; document.getElementById('xGroupMode').value = d2.groupMode;
    });
    document.getElementById('xSec').addEventListener('change', () => { document.getElementById('xPort').value = val('xSec') === 'ldaps' ? 636 : 389; });
    document.getElementById('xCancel').addEventListener('click', () => { idn.edit = false; ed2.classList.add('hidden'); });
    document.getElementById('xSave').addEventListener('click', async () => {
      const prov = { id: val('xId'), name: val('xName'), flavor: val('xFlavor'), enabled: val('xEnabled'), domains: list(val('xDomains')), hosts: list(val('xHosts')),
        security: val('xSec'), port: Number(val('xPort')), baseDn: val('xBase'), bindMode: val('xBind'), bindCredential: val('xCred'), upnSuffix: val('xUpn'),
        usernamePrefix: val('xPrefix'), userFilter: val('xUserF'), groupMode: val('xGroupMode'), groupBaseDn: val('xGroupBase'), groupFilter: val('xGroupF'),
        tls: Object.assign({}, x.tls || {}, { verify: val('xVerify'), caFile: val('xCa') }), attributes: x.attributes || {}, timeoutSeconds: x.timeoutSeconds || 10 };
      if (x.allowInsecure) prov.allowInsecure = true;
      try { await P().api('/api/admin/identity', { method: 'POST', body: { provider: prov, mode: isNew ? 'create' : 'update' } }); P().toast('Provider saved.'); idn.edit = false; identity(body); }
      catch (e) { P().toast(e.message, 7000); }
    });
    ed2.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  /* =====================================================================================================
     SECURITY (session, password, lockout, MFA, admin networks, sessions)
     ===================================================================================================== */
  async function security(body) {
    const d = await P().api('/api/admin/security');
    const p = d.policy, n = (id, v, min, max) => `<input type="number" id="${id}" value="${esc(v)}" min="${min}" max="${max}">`;
    body.innerHTML = `
      ${(d.breakGlass || []).length ? `<div class="alert alert-warn"><b>Break-glass sign-ins:</b> ${d.breakGlass.map((b) => `${esc(b.actor)} ${P().fmtDate(b.ts)} from ${esc((b.details || {}).ip || '?')}`).join(' &middot; ')}</div>` : ''}
      <div class="grid-2">
        <section class="card fieldset"><h2 class="section-title">Session</h2><div class="fields">
          ${fld('Idle timeout (minutes)', n('sIdle', p.session.idleTimeoutMinutes, 5, 120), 'Signed out after this time without using the portal.')}
          ${fld('Maximum session (minutes)', n('sAbs', p.session.absoluteTimeoutMinutes, 30, 1440), 'Sign in again after this time. Applied at next restart.')}
          ${fld('Warning before sign-out (seconds)', n('sWarn', p.session.warningSeconds, 30, 600))}
          ${fld('Re-authentication window (minutes)', n('sRe', p.session.reauthWindowMinutes, 1, 60), 'Sensitive actions ask for the password again after this time.')}
        </div></section>
        <section class="card fieldset"><h2 class="section-title">Local passwords</h2><div class="fields">
          ${fld('Minimum length', n('pwLen', p.password.minLength, 8, 128))}
          ${fld('Character classes (of 4)', n('pwCls', p.password.requireClasses, 1, 4), 'lowercase, uppercase, digit, symbol')}
          ${fld('History (previous passwords)', n('pwHist', p.password.history, 0, 24))}
          ${fld('Maximum age (days, 0 = never)', n('pwAge', p.password.maxAgeDays, 0, 3650))}
        </div></section>
        <section class="card fieldset"><h2 class="section-title">Lockout</h2><div class="fields">
          ${fld('Failed attempts', n('lkTh', p.lockout.threshold, 3, 50), 'Per username; an IP is locked after 4x this number.')}
          ${fld('Within (minutes)', n('lkWin', p.lockout.windowMinutes, 1, 1440))}
          ${fld('Lock duration (minutes)', n('lkDur', p.lockout.durationMinutes, 1, 1440))}
        </div></section>
        <section class="card fieldset"><h2 class="section-title">Multi-factor authentication</h2>
          <div class="field"><label>Required for roles</label><div class="checks">${roleBoxes('mfaRoles', p.mfa.requiredRoles, d.roles)}</div>
            <div class="help">Users with these roles must enrol an authenticator app (TOTP) at next sign-in. Everyone else can enrol voluntarily.</div></div>
          ${fld('Issuer name in the app', `<input type="text" id="mfaIssuer" value="${esc(p.mfa.issuer)}" placeholder="(product name)">`)}
        </section>
        <section class="card fieldset"><h2 class="section-title">Networks</h2><div class="fields">
          ${fld('Admin networks (CIDR)', `<textarea id="nAdmin" rows="3" placeholder="10.10.0.0/16">${esc((p.adminAllowedCidrs || []).join('\n'))}</textarea>`, `Administrative roles only work from these networks. Empty = anywhere. Your address: <span class="mono">${esc(d.clientIp)}</span>`)}
          ${fld('Trusted reverse proxies', `<textarea id="nProxy" rows="3" placeholder="10.10.1.5">${esc((p.trustedProxies || []).join('\n'))}</textarea>`, 'X-Forwarded-For is only honoured from these addresses.')}
        </div></section>
        <section class="card fieldset"><h2 class="section-title">Separation of duties</h2>
          <div class="field"><label class="toggle"><input type="checkbox" id="sodVault" ${p.separationOfDuties.vaultAdminCanApprove ? 'checked' : ''}> Vault administrators may approve jobs that use vault credentials</label>
          <div class="help">Disabled by default: the custodian of the credentials does not approve their use.</div></div>
          <p class="muted" style="margin:10px 0 0">Vault master key: <span class="mono">${esc(d.vault.provider)}</span> &middot; <span class="mono">${esc(d.vault.location)}</span></p>
        </section>
      </div>
      <div class="sticky-actions card"><button class="btn btn-primary" id="secSave">Save security policy</button><span class="muted">Saving asks for your password.</span></div>

      <section class="card" style="margin-top:16px"><div class="card-pad"><h2 class="section-title" style="margin:0">Active sessions (${d.sessions.length})</h2></div>
        <div class="table-wrap"><table><thead><tr><th>User</th><th>Provider</th><th>Address</th><th>Signed in</th><th>Last activity</th><th></th></tr></thead>
        <tbody>${d.sessions.map((x) => `<tr><td>${esc(x.name)} <span class="mono muted">${esc(x.username)}</span>${x.breakGlass ? ' <span class="tag tag-approval">break-glass</span>' : ''}</td>
          <td>${esc(x.provider)}</td><td class="mono">${esc(x.ip)}</td><td>${P().fmtDate(x.loginAt)}</td><td>${P().fmtDate(x.lastActivity)}</td>
          <td class="row-actions"><button class="btn btn-sm btn-danger" data-rev="${esc(x.id)}">End session</button></td></tr>`).join('') || '<tr><td colspan="6" class="muted">No active sessions.</td></tr>'}</tbody></table></div></section>

      <section class="card" style="margin-top:16px"><div class="card-pad"><h2 class="section-title" style="margin:0">Locked accounts and addresses</h2></div>
        <div class="table-wrap"><table><thead><tr><th>Kind</th><th>Name</th><th>Locked until</th><th></th></tr></thead>
        <tbody>${d.lockouts.map((x) => `<tr><td>${esc(x.kind)}</td><td class="mono">${esc(x.name)}</td><td>${P().fmtDate(x.lockedUntil)}</td>
          <td class="row-actions"><button class="btn btn-sm" data-unlock="${esc(x.key)}">Unlock</button></td></tr>`).join('') || '<tr><td colspan="4" class="muted">Nothing locked.</td></tr>'}</tbody></table></div></section>

      <section class="card card-pad" style="margin-top:16px"><h2 class="section-title">Reset a directory user's authenticator</h2>
        <div class="inline"><input type="text" id="mfaResetUser" placeholder="CORP\\jdoe" style="width:240px"><button class="btn btn-danger" id="mfaResetGo">Reset MFA</button></div>
        <div class="help">Local users: Admin &gt; Local users &gt; Edit &gt; Reset MFA.</div></section>`;
    document.getElementById('secSave').addEventListener('click', async () => {
      const num = (id) => Number(val(id));
      const policy = {
        session: { idleTimeoutMinutes: num('sIdle'), absoluteTimeoutMinutes: num('sAbs'), warningSeconds: num('sWarn'), reauthWindowMinutes: num('sRe') },
        password: { minLength: num('pwLen'), requireClasses: num('pwCls'), history: num('pwHist'), maxAgeDays: num('pwAge') },
        lockout: { threshold: num('lkTh'), windowMinutes: num('lkWin'), durationMinutes: num('lkDur') },
        mfa: { requiredRoles: checkedValues('mfaRoles'), issuer: val('mfaIssuer') },
        adminAllowedCidrs: list(val('nAdmin')), trustedProxies: list(val('nProxy')),
        separationOfDuties: { vaultAdminCanApprove: val('sodVault') }
      };
      try { await P().api('/api/admin/security/policy', { method: 'POST', body: policy }); P().toast('Security policy saved.'); security(body); }
      catch (e) { P().toast(e.message, 7000); }
    });
    body.querySelectorAll('[data-rev]').forEach((b) => b.addEventListener('click', async () => {
      if (!armed(b, 'Confirm')) return;
      try { await P().api('/api/admin/security/sessions/revoke', { method: 'POST', body: { id: b.dataset.rev } }); P().toast('Session ended.'); security(body); } catch (e) { P().toast(e.message); }
    }));
    body.querySelectorAll('[data-unlock]').forEach((b) => b.addEventListener('click', async () => {
      try { await P().api('/api/admin/security/lockouts/clear', { method: 'POST', body: { key: b.dataset.unlock } }); P().toast('Unlocked.'); security(body); } catch (e) { P().toast(e.message); }
    }));
    document.getElementById('mfaResetGo').addEventListener('click', async (ev) => {
      if (!val('mfaResetUser')) return;
      if (!armed(ev.target, 'Confirm reset')) return;
      try { await P().api('/api/admin/security/mfa/reset', { method: 'POST', body: { username: val('mfaResetUser') } }); P().toast('Authenticator reset; sessions of that user were ended.'); } catch (e) { P().toast(e.message); }
    });
  }

  /* =====================================================================================================
     VAULT (credentials for the automation - write-only)
     ===================================================================================================== */
  const vlt = { d: null };
  const VAULT_TYPES = { UsernamePassword: 'Username + password', SshKey: 'SSH private key', ApiToken: 'API token', Certificate: 'Certificate (PFX, base64)', ServicePrincipal: 'Service principal / access key' };

  async function vault(body, editId) {
    vlt.d = await P().api('/api/admin/vault');
    const d = vlt.d, st = d.status;
    const e = editId ? d.entries.find((x) => x.id === editId) : null;
    const x = e || { id: '', name: '', type: 'UsernamePassword', description: '', username: '', target: '', scope: { system: false, teams: [], items: [] }, tags: [], expiresAt: '' };
    body.innerHTML = `
      <div class="alert ${st.healthy ? 'alert-info' : 'alert-err'}">${st.healthy
        ? `${dot('ok')}Vault healthy: AES-256-GCM, master key <span class="mono">${esc(st.keyProvider)}</span> (${esc(st.keyLocation)}). Secrets are write-only: they can be replaced, never displayed. ${st.expired ? `<b>${st.expired} expired.</b>` : ''} ${st.expiring ? `${st.expiring} expiring within 30 days.` : ''}`
        : `${dot('bad')}${esc(st.error)}`}</div>
      <div class="two-col">
        <section class="card"><div class="table-wrap"><table><thead><tr><th>Credential</th><th>Type / account</th><th>Scope</th><th>Used by</th><th>Last use</th><th></th></tr></thead>
          <tbody>${d.entries.map((v) => `<tr><td><b>${esc(v.name)}</b>${v.state !== 'ok' ? ` <span class="tag ${v.state === 'expired' ? 'tag-approval' : ''}">${esc(v.state)}</span>` : ''}
              <div class="mono muted" style="font-size:12px">${esc(v.id)} &middot; v${esc(v.version)}</div></td>
            <td>${esc(VAULT_TYPES[v.type] || v.type)}<div class="mono muted" style="font-size:12px;word-break:break-all">${esc(v.username || '')}</div></td>
            <td>${v.scope.system ? '<span class="tag">platform</span> ' : ''}${(v.scope.items || []).map((i) => `<span class="tag">${esc(i === '*' ? 'any item' : i)}</span>`).join(' ')}${(v.scope.teams || []).length ? `<div class="muted" style="font-size:11px">teams: ${esc(v.scope.teams.join(', '))}</div>` : ''}</td>
            <td class="mono" style="font-size:12px">${esc((v.usedBy || []).join(', ') || '-')}</td>
            <td style="white-space:nowrap">${v.lastUsedAt ? `${P().fmtDate(v.lastUsedAt)}<div class="muted" style="font-size:11px">${esc(v.useCount)} uses</div>` : '<span class="muted">never</span>'}</td>
            <td class="row-actions"><button class="btn btn-sm" data-vedit="${esc(v.id)}">Edit</button><button class="btn btn-sm btn-danger" data-vdel="${esc(v.id)}" ${(v.usedBy || []).length ? 'disabled title="In use"' : ''}>Delete</button></td></tr>`).join('')
            || '<tr><td colspan="6" class="muted">No credentials yet.</td></tr>'}</tbody></table></div></section>
        <aside class="card card-pad aside">
          <h2 class="section-title">${e ? `Edit ${esc(e.id)}` : 'New credential'}</h2>
          <div class="stack">
            ${fld('Id', `<input type="text" id="vId" value="${esc(x.id)}" ${e ? 'readonly' : ''} placeholder="guest-windows-admin">`, 'Lowercase; referenced by catalog items (execution.credentials) and connections.')}
            ${fld('Name', `<input type="text" id="vName" value="${esc(x.name)}">`)}
            ${fld('Type', `<select id="vType">${Object.entries(VAULT_TYPES).map(([k, l]) => `<option value="${k}" ${x.type === k ? 'selected' : ''}>${l}</option>`).join('')}</select>`)}
            ${fld('Username / client id / access key', `<input type="text" id="vUser" value="${esc(x.username)}" autocomplete="off">`)}
            ${fld(e ? 'New secret (leave empty to keep)' : 'Secret', '<textarea id="vSecret" rows="3" autocomplete="off" spellcheck="false"></textarea>', 'Password, private key, token or base64 PFX.')}
            ${fld('Passphrase (keys / certificates)', '<input type="password" id="vPass" autocomplete="new-password">')}
            ${fld('Target (optional)', `<input type="text" id="vTarget" value="${esc(x.target || '')}" placeholder="host, URL or account name">`)}
            ${fld('Expires (optional)', `<input type="date" id="vExp" value="${esc((x.expiresAt || '').slice(0, 10))}">`, 'Shown as expiring 30 days before; expired entries are refused.')}
            <div class="field"><label class="toggle"><input type="checkbox" id="vSys" ${x.scope.system ? 'checked' : ''}> Platform use (vCenter, cloud, directory bind)</label></div>
            <div class="field"><label>Catalog items allowed to use it</label><div class="checks">
              <label class="toggle"><input type="checkbox" name="vItems" value="*" ${(x.scope.items || []).includes('*') ? 'checked' : ''}> any item</label>
              ${d.items.map((i) => `<label class="toggle"><input type="checkbox" name="vItems" value="${esc(i.id)}" ${(x.scope.items || []).includes(i.id) ? 'checked' : ''}> ${esc(i.name)}</label>`).join('')}</div></div>
            <div class="field"><label>Only for requests of teams</label><div class="checks">${d.teams.map((t) => `<label class="toggle"><input type="checkbox" name="vTeams" value="${esc(t.id)}" ${(x.scope.teams || []).includes(t.id) ? 'checked' : ''}> ${esc(t.name)}</label>`).join('')}</div>
              <div class="help">Empty = any team.</div></div>
            ${fld('Tags', `<input type="text" id="vTags" value="${esc((x.tags || []).join(', '))}" placeholder="windows, guest">`, 'Credential inputs can filter by tag (vaultTags).')}
            ${fld('Description', `<input type="text" id="vDesc" value="${esc(x.description || '')}">`)}
            <div class="actions"><button class="btn btn-primary" id="vSave">${e ? 'Save' : 'Store credential'}</button>${e ? '<button class="btn" id="vCancel">Cancel</button>' : ''}</div>
          </div>
        </aside>
      </div>`;
    body.querySelectorAll('[data-vedit]').forEach((b) => b.addEventListener('click', () => vault(body, b.dataset.vedit)));
    document.getElementById('vCancel')?.addEventListener('click', () => vault(body));
    body.querySelectorAll('[data-vdel]').forEach((b) => b.addEventListener('click', async () => {
      if (!armed(b, 'Confirm')) return;
      try { await P().api(`/api/admin/vault/${encodeURIComponent(b.dataset.vdel)}`, { method: 'DELETE' }); P().toast('Credential deleted.'); vault(body); } catch (err) { P().toast(err.message, 6000); }
    }));
    document.getElementById('vSave').addEventListener('click', async () => {
      const payload = { mode: e ? 'update' : 'create', id: val('vId'), name: val('vName'), type: val('vType'), username: val('vUser'), target: val('vTarget'),
        description: val('vDesc'), expiresAt: val('vExp'), tags: list(val('vTags')),
        scope: { system: val('vSys'), items: checkedValues('vItems'), teams: checkedValues('vTeams') } };
      const secret = document.getElementById('vSecret').value;
      if (secret) { payload.secret = secret; payload.passphrase = document.getElementById('vPass').value; }
      try {
        await P().api('/api/admin/vault', { method: 'POST', body: payload });
        document.getElementById('vSecret').value = ''; document.getElementById('vPass').value = '';
        P().toast(e ? 'Credential updated.' : 'Credential stored.'); vault(body);
      } catch (err) { P().toast(err.message, 7000); }
    });
  }

  /* =====================================================================================================
     AUDIT
     ===================================================================================================== */
  async function audit(body) {
    const a = await P().api('/api/admin/audit');
    body.innerHTML = `<section class="card"><div class="table-wrap"><table><thead><tr><th>Time</th><th>Actor</th><th>Action</th><th>Target</th><th>Details</th></tr></thead>
      <tbody>${a.entries.slice(0, 200).map((x) => `<tr><td>${P().fmtDate(x.ts)}</td><td>${esc(x.actor)}</td><td class="mono">${esc(x.action)}</td>
        <td class="mono">${x.target && /^REQ-/.test(x.target) ? `<a href="#/requests/${esc(x.target)}">${esc(x.target)}</a>` : esc(x.target || '')}</td>
        <td class="muted" style="word-break:break-all">${esc(x.details && Object.keys(x.details).length ? JSON.stringify(x.details) : '')}</td></tr>`).join('')}</tbody></table></div></section>`;
  }

  /* ---------------- data files (software repository, version / hardening baselines, backup policies) ---------------- */
  async function dataFiles(body, sel) {
    const d = await P().api('/api/admin/datafiles');
    const files = d.files || [];
    const cur = files.find((f) => f.name === sel) || files[0];
    if (!cur) { body.innerHTML = '<div class="card card-pad muted">No data files.</div>'; return; }
    const HELP = {
      software: 'Packages installed by "Install agent baseline" (Windows / Linux). Only status Approved is installed; Pending / Retired packages are skipped and reported. Sets group packages per OS.',
      versionBaseline: 'Target builds for vCenter, ESXi, VMware Tools and VM hardware, plus advisories (fixed build). Used by "Version compliance".',
      hardeningBaseline: 'Checks used by "Hardening compliance": ESXi advanced settings, services and VM advanced settings (operator eq / ne / le / ge / range / nonEmpty).',
      backup: 'Backup policies offered by "Backup policy". Connector vsphereTag writes the policy as a vSphere tag (vendor-agnostic); other connectors are templates until a backup product is approved.',
    };
    body.innerHTML = `<div class="two-col">
      <section class="card card-pad stack">
        <div style="display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap">
          <h2 class="section-title" style="margin:0">${esc(cur.title)} <span class="muted mono" style="font-size:12px">${esc(cur.file)}</span></h2>
          <div class="actions"><button class="btn btn-sm" id="dfValidate">Validate</button><button class="btn btn-primary btn-sm" id="dfSave">Save</button></div>
        </div>
        <p class="muted small" style="margin:0">${esc(HELP[cur.name] || '')}</p>
        <div id="dfMsg"></div>
        <textarea id="dfJson" class="datafile-editor" spellcheck="false">${esc(JSON.stringify(cur.content, null, 2))}</textarea>
      </section>
      <aside class="aside card card-pad stack"><h2 class="section-title">Files</h2>
        <ul class="report-list">${files.map((f) => `<li><a href="#/admin/datafiles/${esc(f.name)}"${f.name === cur.name ? ' style="font-weight:600"' : ''}>${esc(f.title)}</a>
          <span class="muted small">${f.updated ? P().fmtDate(f.updated) : 'default'}</span></li>`).join('')}</ul>
        <p class="muted small" style="margin:0">Saving keeps the previous version in config/_backup and asks you to confirm your password.</p></aside></div>`;
    const msg = (cls, html) => { document.getElementById('dfMsg').innerHTML = `<div class="alert ${cls}">${html}</div>`; };
    const showErrors = (e) => { const errs = Array.isArray(e) ? e : [e]; msg('alert-err', `<b>The file is not valid.</b><ul style="margin:6px 0 0;padding-left:18px">${errs.map((x) => `<li>${esc(x)}</li>`).join('')}</ul>`); };
    document.getElementById('dfValidate').addEventListener('click', async () => {
      try {
        const r = await P().api(`/api/admin/datafiles/${encodeURIComponent(cur.name)}`, { method: 'POST', body: { json: val('dfJson'), validateOnly: true } });
        if (r.valid) msg('alert-ok', 'Valid.'); else showErrors(r.errors || []);
      } catch (e) { msg('alert-err', esc(e.message)); }
    });
    document.getElementById('dfSave').addEventListener('click', async () => {
      try {
        await P().api(`/api/admin/datafiles/${encodeURIComponent(cur.name)}`, { method: 'POST', body: { json: val('dfJson') } });
        P().toast(`${cur.title} saved.`); dataFiles(body, cur.name);
      } catch (e) { if (e.fields && e.fields.errors) showErrors(e.fields.errors); else msg('alert-err', esc(e.message)); }
    });
  }

  window.PortalAdmin = { view };
})();
