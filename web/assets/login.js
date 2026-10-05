/* Self-Service Portal - sign-in page (external file: works with a strict Content-Security-Policy, no inline script). */
(() => {
  const $ = (id) => document.getElementById(id);
  const show = (id, msg) => { const e = $(id); e.textContent = msg; e.classList.toggle('hidden', !msg); };
  const reasons = {
    signedout: 'You have signed out.',
    idle: 'You were signed out after a period of inactivity.',
    expired: 'Your session expired. Please sign in again.',
    revoked: 'Your session was ended by an administrator.'
  };
  let reason = null;
  try { reason = sessionStorage.getItem('ssp-logout-reason'); sessionStorage.removeItem('ssp-logout-reason'); } catch { /* private mode */ }
  if (reason && reasons[reason]) show('info', reasons[reason]);
  else if (new URLSearchParams(location.search).has('error')) show('err', 'Sign-in expired before it completed. Please try again.');

  fetch('/api/branding').then((r) => r.ok ? r.json() : null).then((b) => { if (b) window.applyBranding(b); }).catch(() => {});

  let busy = false;
  $('loginForm').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    if (busy) return;
    const body = { username: $('username').value.trim(), password: $('password').value, otp: $('otp').value.trim() };
    if (!body.username || !body.password) return show('err', 'Enter your username and password.');
    busy = true; $('submitBtn').disabled = true; show('err', ''); show('info', '');
    try {
      const res = await fetch('/api/auth/login', {
        method: 'POST', credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json', 'X-Portal-Request': '1' },
        body: JSON.stringify(body)
      });
      const data = await res.json().catch(() => ({}));
      if (data.ok && data.ticket) {
        $('tUser').value = body.username; $('tTicket').value = data.ticket;
        $('password').value = '';
        $('ticketForm').submit();
        return;
      }
      if (data.next === 'mfa') {
        $('credStep').classList.add('hidden'); $('otpStep').classList.remove('hidden');
        $('submitBtn').textContent = 'Verify';
        if (body.otp) show('err', data.message || 'The verification code is not valid.'); else show('info', data.message || '');
        $('otp').value = ''; $('otp').focus();
      }
      else {
        show('err', data.message || 'Sign-in failed.');
        $('otpStep').classList.add('hidden'); $('credStep').classList.remove('hidden'); $('otp').value = '';
        $('submitBtn').textContent = 'Sign in'; $('password').value = ''; $('password').focus();
      }
    }
    catch { show('err', 'The portal is not reachable. Try again in a moment.'); }
    finally { busy = false; $('submitBtn').disabled = false; }
  });
})();
