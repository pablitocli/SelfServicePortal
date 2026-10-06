/* Applies the portal branding (Admin > Customization) to the current page. Shared by login and app. */
window.applyBranding = function applyBranding(b) {
  if (!b) return;
  const set = (id, v) => { const e = document.getElementById(id); if (e && v !== undefined) e.textContent = v; };
  set('brandOrg', b.organization);
  set('portalName', b.productName);
  set('loginMessage', b.loginMessage);
  set('footerText', b.footerText);
  document.title = document.title.replace(/Self-Service Portal.*$/, '') + b.productName;
  const logo = document.getElementById('brandLogo');
  if (logo) {
    if (b.logoUrl) { logo.src = b.logoUrl; logo.alt = b.organization || ''; logo.classList.remove('hidden'); }
    else { logo.removeAttribute('src'); logo.classList.add('hidden'); }
  }
  const hex = /^#[0-9a-fA-F]{6}$/;
  const root = document.documentElement.style;
  if (hex.test(b.primaryColor || '')) { root.setProperty('--navy-900', b.primaryColor); root.setProperty('--navy-800', b.primaryColor); }
  if (hex.test(b.accentColor || '')) { root.setProperty('--navy-700', b.accentColor); root.setProperty('--accent', b.accentColor); }
};
