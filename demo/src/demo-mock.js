/* Online demo: answers the portal API in the browser with sample data. No automation runs. */
(() => {
  'use strict';
  const realFetch = window.fetch.bind(window);
  let cap = null;
  const loadCap = () => cap || (cap = realFetch('data/capture.json').then((r) => r.json()));
  const now = () => new Date().toISOString();
  const ago = (min) => new Date(Date.now() - min * 60000).toISOString();
  const pad = (n) => String(n).padStart(2, '0');
  const stamp = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
  const err = (status, msg, fields) => json({ error: msg, fields }, status);
  const ME = { username: 'LOCAL\\admin', name: 'Portal Administrator', email: '' };

  /* ---------- sample inventory used by the form lookups ---------- */
  const INV = {
    clusters: [['CL-APP-01', 4], ['CL-DB-01', 4]],
    vms: [['APP-SQL01', 'CL-DB-01', 'PoweredOn'], ['APP-SQL02', 'CL-DB-01', 'PoweredOn'], ['APP-WEB01', 'CL-APP-01', 'PoweredOn'], ['APP-WEB02', 'CL-APP-01', 'PoweredOn'],
          ['APP-RPT01', 'CL-DB-01', 'PoweredOn'], ['DC-NEW01', 'CL-APP-01', 'PoweredOn'], ['APP-OLD03', 'CL-APP-01', 'PoweredOff']],
    hosts: [['esx-app-01.corp.example.com', 'CL-APP-01'], ['esx-app-02.corp.example.com', 'CL-APP-01'], ['esx-db-01.corp.example.com', 'CL-DB-01'], ['esx-db-02.corp.example.com', 'CL-DB-01']],
    datastores: [['DS-APP-01', 1800, 4096, 'CL-APP-01'], ['DS-APP-02', 950, 4096, 'CL-APP-01'], ['DS-DB-01', 2600, 8192, 'CL-DB-01']],
    portgroups: [['VL-210', 210], ['VL-220', 220], ['VL-300-BACKUP', 300]],
    folders: ['DC-MAIN', 'DC-MAIN/Apps', 'DC-MAIN/Apps/Prod', 'DC-MAIN/Databases', 'DC-MAIN/Portal-Provisioned'],
    templates: ['TPL-WIN2025', 'TPL-ALMALINUX9']
  };
  const VAULT = [
    ['guest-windows', 'Windows template administrator', 'Administrator'], ['guest-linux', 'Linux guest', 'svc-portal'],
    ['domain-join', 'Domain join account', 'CORP\\svc-join'], ['domain-admin', 'Domain admin (DC promotion)', 'CORP\\da-portal'],
    ['dsrm', 'DSRM password', 'dsrm'], ['ad-admin', 'AD computer mover', 'CORP\\svc-ou-mover'], ['local-account', 'Local ops account', 'localops'],
    ['ad-join', 'Domain join (installs)', 'CORP\\svc-join'], ['sql-service', 'SQL Server service account', 'CORP\\svc-sql']
  ];
  const opt = (value, label) => ({ value, label: label || value });

  function lookup(item, name, values) {
    const f = (item.inputs || []).find((i) => i.name === name);
    if (!f) return [];
    if (f.type === 'credential') {
      const tags = f.vaultTags || [];
      return VAULT.filter(([t]) => !tags.length || tags.includes(t)).map(([t, n, u]) => opt(`${t}-01`, `${n} (${u})`));
    }
    const src = f.source || {};
    const cl = values.Cluster;
    switch (src.type) {
      case 'clusters': return INV.clusters.map(([n, h]) => opt(n, `${n} (${h} hosts)`));
      case 'vms': return INV.vms.filter(([, c, p]) => (!src.powerState || p === src.powerState) && (!src.byCluster || !cl || c === cl)).map(([n, c]) => opt(n, `${n} (${c})`));
      case 'hosts': return INV.hosts.filter(([, c]) => !cl || c === cl).map(([n, c]) => opt(n, `${n} - ${c} - ESXi 8.0.3 build 24022515 - connected`));
      case 'datastores': return INV.datastores.filter(([, , , c]) => !cl || c === cl).map(([n, f2, cap2]) => opt(n, `${n} - ${f2.toLocaleString()} GB free (${Math.round(100 * f2 / cap2)}%)`));
      case 'datastoreClusters': return [opt('DSC-APP', 'DSC-APP - 2,750 GB free')];
      case 'portgroups': return INV.portgroups.map(([n, v]) => opt(n, `${n} (VLAN ${v})`));
      case 'folders': return INV.folders.map((p) => opt(p));
      case 'templates': return INV.templates.map((t) => opt(t));
      case 'vdSwitches': return [opt('VDS-01', 'VDS-01 (v8.0.0, 8 hosts)')];
      case 'storageDevices': return [opt('naa.600a0980383041', 'naa.600a0980383041 - 2048 GB - NETAPP LUN C-Mode (demo sample)')];
      case 'adDirectories': return [opt('ad', 'Active Directory (corp.example.com)')];
      case 'adOus': return ['Servers', 'Servers / SQL', 'Servers / SQL / Prod', 'Servers / Web', 'Staging'].map((p) => opt('OU=' + p.split(' / ').reverse().join(',OU=') + ',DC=corp,DC=example,DC=com', p));
      case 'awsSubnets': return [opt('subnet-0a1b2c3d', 'App private A (subnet-0a1b2c3d)'), opt('subnet-0e4f5a6b', 'App private B (subnet-0e4f5a6b)')];
      case 'awsInstanceTypes': return ['t3.medium', 't3.large', 'm6i.large', 'm6i.xlarge'].map((t) => opt(t));
      case 'azureSubnets': return [opt('snet-app', 'snet-app (vnet-prod)'), opt('snet-db', 'snet-db (vnet-prod)')];
      case 'azureVmSizes': return ['Standard_D2s_v5', 'Standard_D4s_v5', 'Standard_E4s_v5'].map((t) => opt(t));
      case 'sites': return [opt('DC1', 'DC1 - Primary Datacenter'), opt('DC2', 'DC2 - Secondary Datacenter')];
      default: {
        const c = cap.options[`${item.id}/${name}`];
        return c && c.s === 200 ? (c.j.options || []) : [];
      }
    }
  }

  /* ---------- requests ---------- */
  const REPORT = {
    'vm-troubleshoot': [['troubleshooting.html', 'html', 38], ['evidence-APP-SQL01.zip', 'zip', 61], ['aria-report-APP-SQL01.pdf', 'pdf', 412]],
    'vm-incident-evidence': [['incident-evidence.html', 'html', 34], ['evidence-APP-SQL01.zip', 'zip', 58]],
    'report-orphaned-vmdk': [['orphaned-vmdk.html', 'html', 22], ['orphaned-vmdk-06-full-inventory.csv', 'csv', 3]],
    'vm-windows-batch': [['build-closure.html', 'html', 19], ['build-closure-02-validation-checks.csv', 'csv', 2]],
    'report-drs-compliance': [['drs-compliance.html', 'html', 16]],
    'report-change-impact': [['change-impact.html', 'html', 21]],
    'guest-data-disks': [['data-disks.html', 'html', 6]],
    'guest-local-groups': [['local-groups.html', 'html', 7]],
    'ad-move-computer': [['ad-move.html', 'html', 6]]
  };
  const RESULT = {
    'vm-troubleshoot': { VM: 'APP-SQL01', Window: 'around the incident, 60 min before / 30 after (UTC)', Verdict: 'Snapshot / backup activity during the latency peak', Confidence: 'high',
      TopFindings: ['[CRITICAL] Snapshot / backup activity during the latency peak (vSphere)', '[CRITICAL] Storage latency peak: 58 ms (vSphere, Aria Operations)', '[CRITICAL] Guest disk L: low on space (7 % free) (Guest OS)', '[CRITICAL] Aria alert: Virtual machine disk latency is high (Aria Operations)', '[WARN] Guest memory in use 91.2 % (Guest OS)'],
      Sources: ['vSphere: OK (5 min samples, 9 counters, 3 events)', 'Guest OS: OK (Microsoft Windows Server 2022 Standard)', 'Aria Operations: OK (14 samples, 1 alert(s))'],
      Report: 'troubleshooting.html', EvidencePack: 'evidence-APP-SQL01.zip', AriaReport: 'aria-report-APP-SQL01.pdf',
      NextSteps: ['Review the backup / snapshot schedule of this VM and its datastore; consider moving the job out of business hours.', 'Compare with other VMs of the same datastore (Aria Operations datastore view) and the storage array.'] },
    'vm-incident-evidence': { VM: 'APP-SQL01', Window: 'incident +- 30 min (UTC)', Events: 3, AriaAlerts: 1, Aria: 'OK (8 samples, 1 alerts)', Report: 'incident-evidence.html', EvidencePack: 'evidence-APP-SQL01.zip' },
    'report-orphaned-vmdk': { Scope: ['DC1', 'DC2'], OrphanedTB: 0.59, ReclaimableTB: 0.57, Items: 4, DatastoresScanned: 2, NotScanned: 1, Report: 'orphaned-vmdk.html', NextSteps: ['Validate the items with backup / replication owners before any deletion; this report changes nothing.'] },
    'vm-windows-batch': { VMs: 3, Built: 2, Failed: 1, Profile: 'Standard', Details: ['APP-WEB01: OK (DONE)', 'APP-WEB02: OK (DONE)', 'APP-SQL-PRODUCTION-01: FAIL (FAILED) - NETWORK: Gateway 10.10.220.1 is not reachable after setting 10.10.220.15/24 (VLAN / portgroup?).'], Report: 'build-closure.html', ChangeTicket: 'CHG0042',
      NextSteps: ['Failed / stuck VMs were kept for troubleshooting: open the console, fix the cause and use the Day 2 items, or delete them with the decommission item.'] },
    'report-drs-compliance': { Cluster: 'CL-DB-01', Rules: 4, Compliant: 1, Violations: 2, HostsOvercommitted: 0, Report: 'drs-compliance.html', NonCompliant: ['AA-SQL-PROD: SQL-PROD-01 + SQL-PROD-02 share esx-db-01.', 'AA-SQL-MISSING: Rule not found in vCenter.'] },
    'report-change-impact': { Change: 'MTU 9000 iSCSI', Hosts: 3, Improved: 7, Worse: 0, KeyResults: ['Datastore read latency (ms) (avg): 9.5 -> 4.5 (OK improved)', 'Datastore write latency (ms) (avg): 18.5 -> 6.5 (OK improved)', 'Device max latency (ms) (p95): 41 -> 13 (OK improved)', 'Dropped packets rx (sum): 155 -> 5 (OK improved)'], Report: 'change-impact.html' },
    'guest-data-disks': { DryRun: true, VMs: 1, Formatted: 0, Skipped: 0, Errors: 0, Report: 'data-disks.html', Details: ['WIN-01 D: PLAN disk 1 100 GB (RAW, Offline) - CD-ROM moved off D:', 'WIN-01 L: PLAN disk 2 50 GB (GPT, Online)'], NextSteps: ['Review the plan, then submit again with "Dry run" cleared.'] },
    'guest-local-groups': { VMs: 2, Group: 'Both', Added: 4, AlreadyPresent: 1, Failed: 1, Report: 'local-groups.html' },
    'ad-move-computer': { Directory: 'ad', TargetOU: 'OU=Prod,OU=Servers,DC=corp,DC=example,DC=com', Moved: 1, AlreadyThere: 1, Failed: 1, Details: ['SQL01: OK moved (was OU=Staging,DC=corp,DC=example,DC=com)', 'SQL02: OK already in the OU', 'SQL99: ERROR not found in the directory'], Report: 'ad-move.html' }
  };
  const STEPS = {
    'vm-troubleshoot': [['STEP', 'Window: incident window (UTC) - symptom: Slowness'], ['STEP', 'Connecting to Aria Operations ops01.corp.example.com'], ['OK', 'Aria Operations token acquired (VCF Operations 9.0.1).'], ['STEP', 'vSphere: collecting APP-SQL01'], ['WARN', 'Counters not available at this interval (statistics level): cpu.costop.summation'], ['OK', 'vSphere: host esx-db-01.corp.example.com, 0 snapshot(s), 3 event(s).'], ['STEP', 'Guest OS: running read-only diagnostics through VMware Tools'], ['INFO', 'Guest (PowerShell) on APP-SQL01: read-only diagnostics'], ['OK', 'Guest OS: uptime 430.5 h, memory 91.2 %, 1 event group(s).'], ['STEP', 'Aria Operations: collecting APP-SQL01'], ['OK', 'Aria Operations: health 62, 1 alert(s) in the window.'], ['STEP', 'Aria Operations: generating report definition d-vm-ts'], ['OK', 'Aria report ready: aria-report-APP-SQL01.pdf'], ['OK', 'Verdict: Snapshot / backup activity during the latency peak (confidence high)'], ['INFO', 'Aria Operations token released.']],
    'vm-windows-batch': [['STEP', 'Validating the VM list and placement'], ['INFO', '3 VM(s), 0 invalid row(s).'], ['STEP', 'Cloning 3 VM(s) from TPL-WIN2025'], ['INFO', 'APP-WEB01: DEPLOY -> CUSTOMIZING (powered on)'], ['STEP', 'Bootstrap (profile Standard, up to 5 VM(s) in parallel)'], ['INFO', 'APP-WEB01: CUSTOMIZING -> NETWORK (customization done)'], ['INFO', 'APP-WEB01: NETWORK -> RENAME (IP set)'], ['INFO', 'APP-WEB01: RENAME -> REBOOTING (then UPDATES)'], ['INFO', 'APP-WEB01: UPDATES -> UPDATES_WAIT (round 1)'], ['INFO', 'APP-WEB01: UPDATES_WAIT -> REBOOTING (then UPDATES)'], ['INFO', 'APP-SQL-PRODUCTION-01: NETWORK -> FAILED (NETWORK)'], ['INFO', 'APP-WEB01: ACTIVATION -> FIREWALL (licensed: yes)'], ['INFO', 'APP-WEB01: DOMAIN_JOIN -> REBOOTING (then ACCOUNTS)'], ['INFO', 'APP-WEB01: CLEANUP -> DONE'], ['STEP', 'Validation'], ['OK', '2 of 3 VM(s) built; 1 failed.']]
  };
  const reqs = [];
  let seq = 0x3A10;
  const newId = () => { const d = new Date(); return `REQ-${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${(seq++).toString(16).toUpperCase().padStart(6, '0')}`; };
  const hist = (status, actor, note, min) => ({ status, ts: min === undefined ? now() : ago(min), actor, note });
  function makeLog(itemId, item, minAgo) {
    const t0 = Date.now() - minAgo * 60000;
    const lines = [['STEP', `Request - ${item.name} v${item.version}`], ['INFO', `Requested by ${ME.name} (${ME.username})`]];
    if (item.approvalRequired) lines.push(['INFO', 'Approved by approver1']);
    lines.push(['STEP', 'Connecting to vCenter vcenter01.corp.example.com (site DC1)'], ['OK', 'Connected to vcenter01.corp.example.com - vCenter 8.0.3 build 24022515']);
    (STEPS[itemId] || [['STEP', `Invoking handler (demo mode)`], ['INFO', 'Demo: no automation ran; this log is a sample.']]).forEach((l) => lines.push(l));
    lines.push(['OK', 'Job completed successfully.'], ['INFO', 'Disconnected from vCenter.']);
    return lines.map(([lv, m], i) => `${stamp(new Date(t0 + i * 4000))} [${lv.padEnd(5)}] ${m}`).join('\n');
  }
  function addSample(itemId, status, minAgo, inputs, extra = {}) {
    const item = cap.items[itemId]; if (!item) return;
    const r = { id: newId(), itemId, itemName: item.name, category: item.category, status, site: inputs.Site || '', target: extra.target || inputs.VMName || inputs.Cluster || '',
      requester: { ...ME }, createdAt: ago(minAgo), updatedAt: ago(Math.max(0, minAgo - 3)), inputs,
      approval: { required: item.approvalRequired, approverRoles: ['Approver', 'Admin'] }, history: [hist('Submitted', ME.name, '', minAgo)], result: null, error: null, reports: [], log: '' };
    if (item.approvalRequired && status !== 'PendingApproval') { Object.assign(r.approval, { decision: 'Approved', decidedBy: 'approver1', decidedAt: ago(minAgo - 1), comment: 'OK for the change window.' }); r.history.push(hist('Approved', 'approver1', 'OK for the change window.', minAgo - 1)); }
    if (status === 'PendingApproval') r.history[0].status = 'PendingApproval';
    if (status === 'Succeeded') {
      r.history.push(hist('Running', 'runner', 'PID 4120', minAgo - 1), hist('Succeeded', 'runner', 'Completed', Math.max(0, minAgo - 3)));
      r.result = RESULT[itemId] || { Status: 'Done (demo sample)' };
      r.reports = (REPORT[itemId] || []).map(([name, type, sizeKB]) => ({ name, type, sizeKB }));
      r.log = makeLog(itemId, item, minAgo);
    }
    reqs.push(r);
  }
  function seed() {
    addSample('vm-windows-batch', 'Succeeded', 190, { Site: 'DC1', Cluster: 'CL-APP-01', Datastore: 'DS-APP-01', Profile: 'Standard', VmList: 'VMName,CPU,MemoryGB,Portgroup,IP,PrefixLength,Gateway,ExtraDisksGB,DriveLetters\nAPP-WEB01,4,16,VL-210,10.10.210.21,24,10.10.210.1,100;50,D;L\nAPP-WEB02,2,8,VL-210,,,,,\nAPP-SQL-PRODUCTION-01,8,64,VL-220,10.10.220.15,24,10.10.220.1,100,', JoinDomain: true, ChangeTicket: 'CHG0042' }, { target: '3 VMs' });
    addSample('report-change-impact', 'Succeeded', 160, { Site: 'DC1', Cluster: 'CL-DB-01', ChangeDescription: 'MTU 9000 iSCSI', WindowMode: 'AroundChange', Hours: 24 });
    addSample('report-drs-compliance', 'Succeeded', 130, { Site: 'DC1', Cluster: 'CL-DB-01' });
    addSample('report-orphaned-vmdk', 'Succeeded', 95, { Site: 'DC1', AllSites: true, AgeThresholdDays: 90 }, { target: 'All sites' });
    addSample('vm-incident-evidence', 'Succeeded', 60, { Site: 'DC1', VMName: 'APP-SQL01', IncidentTime: '2026-10-27 03:40', MinutesBefore: 30, MinutesAfter: 30, Reference: 'INC0012345' });
    addSample('vm-troubleshoot', 'Succeeded', 35, { Site: 'DC1', VMName: 'APP-SQL01', Symptom: 'Slowness', WindowMode: 'Incident', IncidentTime: '2026-10-27 03:40', UseGuest: true, UseAria: true, AriaReport: 'd-vm-ts' });
    addSample('dc-promote', 'PendingApproval', 12, { Site: 'DC1', VMName: 'DC-NEW01', Mode: 'Promote', Domain: 'corp.example.com', InstallDns: true, ConfirmVMName: 'DC-NEW01' });
    addSample('guest-data-disks', 'PendingApproval', 5, { Site: 'DC1', VMNames: 'APP-WEB01', DriveLetters: 'D,L', DryRun: false });
  }
  const summary = (r) => ({ id: r.id, itemId: r.itemId, itemName: r.itemName, category: r.category, status: r.status, site: r.site, target: r.target, requester: r.requester, createdAt: r.createdAt, updatedAt: r.updatedAt, approvalRequired: r.approval.required });
  const view = (r) => ({ ...r, canCancel: ['PendingApproval', 'Queued'].includes(r.status), canApprove: r.status === 'PendingApproval' });

  function run(r) {
    const item = cap.items[r.itemId];
    const set = (status, note, actor = 'runner') => { r.status = status; r.updatedAt = now(); r.history.push(hist(status, actor, note)); };
    set('Queued', 'Waiting for a runner', 'dispatcher');
    const lines = makeLog(r.itemId, item, 0).split('\n');
    setTimeout(() => {
      set('Running', 'PID 5512 (demo)');
      let i = 0;
      const t = setInterval(() => {
        r.log += (r.log ? '\n' : '') + lines[i++];
        if (i >= lines.length) {
          clearInterval(t);
          r.result = RESULT[r.itemId] ? { ...RESULT[r.itemId], Note: 'Demo sample result: no automation ran.' } : { Status: 'Done', Note: 'Demo: no automation ran.' };
          r.reports = (REPORT[r.itemId] || []).map(([name, type, sizeKB]) => ({ name, type, sizeKB }));
          set('Succeeded', 'Completed');
        }
      }, 700);
    }, 2500);
  }

  function visible(f, values) {
    if (!f.visibleWhen) return true;
    return String(values[f.visibleWhen.field] ?? '') === String(f.visibleWhen.equals);
  }

  /* ---------- router ---------- */
  async function handle(path, method, body) {
    await ready;
    const [p, qs] = path.split('?');
    const q = new URLSearchParams(qs || '');
    let m;
    if (p === '/api/branding') return json(cap.branding);
    if (p === '/api/me') {
      const me = JSON.parse(JSON.stringify(cap.me));
      me.session.expiresAt = new Date(Date.now() + 8 * 3600000).toISOString(); me.session.idleTimeoutMinutes = 600; me.session.reauthValidUntil = new Date(Date.now() + 3600000).toISOString();
      me.sites = [{ code: 'DC1', name: 'Primary Datacenter' }, { code: 'DC2', name: 'Secondary Datacenter' }];
      return json(me);
    }
    if (p.startsWith('/api/session/') || p === '/api/me/password') return json({ ok: true });
    if (p === '/api/me/mfa/begin' || p === '/api/me/mfa/confirm') return err(422, 'Demo: MFA enrollment is not available here.');
    if (p === '/api/catalog') return json(cap['/api/catalog'].j);
    if ((m = p.match(/^\/api\/catalog\/([^/]+)\/options\/([^/]+)$/))) {
      const item = cap.items[decodeURIComponent(m[1])];
      await new Promise((r) => setTimeout(r, 120));
      return json({ options: lookup(item, decodeURIComponent(m[2]), (body && body.values) || {}) });
    }
    if ((m = p.match(/^\/api\/catalog\/([^/]+)$/))) { const it = cap.items[decodeURIComponent(m[1])]; return it ? json(it) : err(404, 'Catalog item not found.'); }
    if (p === '/api/requests' && method === 'POST') {
      const item = cap.items[body.itemId]; const values = body.inputs || {};
      const errors = {};
      (item.inputs || []).forEach((f) => { if (f.required && f.type !== 'boolean' && visible(f, values) && (values[f.name] === undefined || String(values[f.name]).trim() === '')) errors[f.name] = `${f.label} is required.`; });
      if (Object.keys(errors).length) return err(422, 'Please correct the highlighted fields.', errors);
      const inputs = {}; (item.inputs || []).forEach((f) => { if (visible(f, values) && values[f.name] !== undefined && values[f.name] !== '') inputs[f.name] = values[f.name]; });
      const r = { id: newId(), itemId: item.id, itemName: item.name, category: item.category, status: item.approvalRequired ? 'PendingApproval' : 'Submitted', site: inputs.Site || '', target: inputs.VMName || inputs.Cluster || inputs.VMNames || '',
        requester: { ...ME }, createdAt: now(), updatedAt: now(), inputs, approval: { required: item.approvalRequired, approverRoles: ['Approver', 'Admin'] },
        history: [hist(item.approvalRequired ? 'PendingApproval' : 'Submitted', ME.name, '')], result: null, error: null, reports: [], log: '' };
      reqs.push(r);
      if (!item.approvalRequired) run(r);
      return json({ id: r.id, status: r.status });
    }
    if (p === '/api/requests') {
      const scope = q.get('scope') || 'mine';
      const list = reqs.filter((r) => scope !== 'approvals' || r.status === 'PendingApproval').slice().sort((a, b) => b.createdAt.localeCompare(a.createdAt));
      return json({ requests: list.map(summary) });
    }
    if ((m = p.match(/^\/api\/requests\/([^/]+)\/log$/))) { const r = reqs.find((x) => x.id === m[1]); return json({ status: r.status, log: r.log }); }
    if ((m = p.match(/^\/api\/requests\/([^/]+)\/(approve|reject|cancel)$/))) {
      const r = reqs.find((x) => x.id === m[1]);
      if (m[2] === 'approve') { Object.assign(r.approval, { decision: 'Approved', decidedBy: ME.name, decidedAt: now(), comment: body.comment || '' }); r.history.push(hist('Approved', ME.name, body.comment || '')); run(r); }
      else if (m[2] === 'reject') { Object.assign(r.approval, { decision: 'Rejected', decidedBy: ME.name, decidedAt: now(), comment: body.comment }); r.status = 'Rejected'; r.history.push(hist('Rejected', ME.name, body.comment)); }
      else { r.status = 'Cancelled'; r.history.push(hist('Cancelled', ME.name, '')); }
      return json({ id: r.id, status: r.status });
    }
    if ((m = p.match(/^\/api\/requests\/([^/]+)$/))) { const r = reqs.find((x) => x.id === m[1]); return r ? json(view(r)) : err(404, 'Request not found.'); }
    if (p === '/api/storage/scan') return json({ running: false, cooldownSeconds: 0, lastRescanAt: ago(240), lastRescanBy: 'LOCAL\\admin', state: 'Done', devices: 1 });
    if (p === '/api/storage/rescan') return json({ started: true });
    if (p.startsWith('/api/admin/')) {
      if (method === 'GET' && cap[path]) return json(cap[path].j);
      if (p.match(/\/aria\/test$/)) { const sv = cap['/api/admin/sites'].j; return json(sv.sites[0].aria.lastTest); }
      if (p.match(/\/test$/)) return json({ ok: true, testedAt: now(), durationMs: 640, vcenter: 'vcenter01.corp.example.com', version: '8.0.3 build 24022515', user: 'svc-portal@vsphere.local', datacenters: ['DC-MAIN'], clusters: ['CL-APP-01', 'CL-DB-01'], workloadClusters: { App: { cluster: 'CL-APP-01', found: true }, DB: { cluster: 'CL-DB-01', found: true } } });
      if (p === '/api/admin/sites') return json({ saved: true, sites: cap['/api/admin/sites'].j.sites });
      if (p === '/api/admin/settings') return json(cap['/api/admin/settings'].j);
      if (p === '/api/admin/inventory/refresh') return json({ started: [] });
      if (method === 'GET') return json({});
      return json({ saved: true, note: 'Demo: nothing is stored.' });
    }
    return err(404, 'Not available in the online demo.');
  }

  window.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    if (!url.startsWith('/api/')) return realFetch(input, init);
    let body = null; try { body = init.body ? JSON.parse(init.body) : null; } catch { body = null; }
    try { return await handle(url, (init.method || 'GET').toUpperCase(), body); }
    catch (e) { return err(500, `Demo: ${e.message}`); }
  };
  const ready = loadCap().then((c) => {
    cap = c;
    c.items = {}; c.me = c['/api/me'].j;
    Object.keys(c).forEach((k) => { const mm = k.match(/^\/api\/catalog\/([^/]+)$/); if (mm) c.items[mm[1]] = c[k].j; });
    return realFetch('data/branding.json').then((r) => r.json()).then((b) => { c.branding = b; seed(); });
  });

  /* ---------- reports open in a viewer inside the page ---------- */
  window.labSignOut = () => window.Portal && window.Portal.toast('Demo: sign-out is disabled.');
  document.addEventListener('click', async (e) => {
    const a = e.target.closest('a[data-lab-report]'); if (!a) return;
    e.preventDefault();
    const name = a.dataset.labReport;
    if (!/\.html$/.test(name)) { window.Portal.toast(`Demo: ${name} is listed as an example; downloads are not available here.`, 4500); return; }
    const html = await (await realFetch('reports/' + name)).text();
    const box = document.createElement('div'); box.className = 'lab-viewer';
    box.innerHTML = `<div class="lab-viewer-bar"><b>${name}</b><span class="muted">sample report from the offline handler tests</span><button class="btn btn-sm" type="button" id="labClose">Close</button></div><iframe title="${name}" sandbox=""></iframe>`;
    document.body.appendChild(box);
    box.querySelector('iframe').srcdoc = html;
    box.querySelector('#labClose').addEventListener('click', () => box.remove());
    box.addEventListener('keydown', (ev) => { if (ev.key === 'Escape') box.remove(); });
    box.querySelector('#labClose').focus();
  });
  window.addEventListener('hashchange', () => document.querySelectorAll('.lab-viewer').forEach((v) => v.remove()));
})();
