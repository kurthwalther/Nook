// Licensed under GPL-3.0. See LICENSE.
//
// KurthPasswords.js — Nook (rama kurth)
//
// Contraseñas de Apple (Passwords / llavero de iCloud) en cualquier página, sin permisos de Apple.
// La extensión oficial no puede correr en Nook (su ayudante solo arranca bajo navegadores de una
// lista de Apple), pero un campo de contraseña nativo de AppKit sí recibe el botón "Passwords…"
// del sistema en cualquier app. Este script pone una llave dentro del campo de usuario o
// contraseña que tiene el foco; al pulsarla, KurthPasswords.swift monta un campo nativo invisible
// encima, el sistema pide Touch ID y entrega usuario y contraseña, y aquí se escriben en la página.
//
// Corre en el mundo aislado "KurthCopilot": la página no ve `webkit.messageHandlers` ni
// `window.__kurthClaves`, solo el DOM que compartimos (la llave es un <div> normal).

(() => {
  if (window.__kurthClaves) return;

  const post = (m) => { try { webkit.messageHandlers.kurthPasswords.postMessage(m); } catch (e) { /* sin canal */ } };

  const RE_USUARIO = /user|usuario|email|correo|login|account|cuenta|identifier|phone|tel/i;
  const ICONO = '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.9" '
    + 'stroke-linecap="round" stroke-linejoin="round"><circle cx="5.5" cy="10.5" r="3.4"/>'
    + '<path d="M8 8l6-6M11.3 4.7l2 2M9.3 6.7l2 2"/></svg>';

  function visible(el) {
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) > 0.01;
  }

  const esPassword = (el) => el instanceof HTMLInputElement && el.type === 'password';

  function esUsuario(el) {
    if (!(el instanceof HTMLInputElement)) return false;
    const t = (el.type || 'text').toLowerCase();
    if (!['text', 'email', 'tel'].includes(t)) return false;
    const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
    if (/username|email|tel/.test(ac)) return true;
    if (t === 'email') return true;
    return RE_USUARIO.test([el.name, el.id, el.placeholder, el.getAttribute('aria-label')].join(' '));
  }

  const candidato = (el) => esPassword(el) || esUsuario(el);

  /// El campo de usuario que acompaña a un campo de contraseña: el último de texto/email visible
  /// antes de él, en el mismo formulario si lo hay.
  function usuarioPara(pass) {
    const inputs = Array.from((pass.form || document).querySelectorAll('input'))
      .filter((i) => i !== pass && visible(i) && esUsuario(i));
    let mejor = null;
    for (const i of inputs) {
      if (i.compareDocumentPosition(pass) & Node.DOCUMENT_POSITION_FOLLOWING) mejor = i;
    }
    return mejor || inputs[0] || null;
  }

  function passwordPara(user) {
    return Array.from((user.form || document).querySelectorAll('input[type=password]')).find(visible) || null;
  }

  /// Escribe como lo haría una persona para que React, Angular y compañía se enteren.
  function poner(el, valor) {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    el.focus();
    setter.call(el, valor);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // MARK: la llave

  let llave = null;
  let campo = null;
  let reloj = 0;
  let ocultarTimer = 0;

  function crearLlave() {
    const b = document.createElement('div');
    b.setAttribute('data-kurth-claves', '');
    b.setAttribute('title', 'Contraseñas de Apple');
    b.innerHTML = ICONO;
    Object.assign(b.style, {
      position: 'fixed', zIndex: '2147483647', width: '22px', height: '22px', borderRadius: '7px',
      display: 'flex', alignItems: 'center', justifyContent: 'center', boxSizing: 'border-box',
      cursor: 'pointer', background: 'rgba(128,128,128,0.18)', opacity: '0', pointerEvents: 'none',
      transition: 'background 120ms ease, opacity 120ms ease', userSelect: 'none', WebkitUserSelect: 'none',
    });
    // mousedown sin preventDefault le quitaría el foco al campo y la llave se esconde sola.
    b.addEventListener('mousedown', (e) => { e.preventDefault(); e.stopPropagation(); });
    b.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); pedir(); });
    b.addEventListener('mouseenter', () => { b.style.background = 'rgba(128,128,128,0.30)'; });
    b.addEventListener('mouseleave', () => { b.style.background = 'rgba(128,128,128,0.18)'; });
    return b;
  }

  function colocar() {
    if (!campo || !llave) return;
    const r = campo.getBoundingClientRect();
    if (r.width < 60 || r.height < 16 || !visible(campo)) { llave.style.opacity = '0'; llave.style.pointerEvents = 'none'; return; }
    const lado = Math.min(22, Math.max(16, Math.round(r.height - 8)));
    llave.style.width = llave.style.height = lado + 'px';
    llave.style.left = Math.round(r.right - lado - 6) + 'px';
    llave.style.top = Math.round(r.top + (r.height - lado) / 2) + 'px';
    llave.style.color = getComputedStyle(campo).color;
    llave.style.opacity = '0.85';
    llave.style.pointerEvents = 'auto';
  }

  function mostrar(el) {
    campo = el;
    if (!llave) { llave = crearLlave(); document.documentElement.appendChild(llave); }
    clearTimeout(ocultarTimer);
    colocar();
    clearInterval(reloj);
    reloj = setInterval(colocar, 250); // cambios de layout que no disparan scroll ni resize
  }

  function ocultar() {
    campo = null;
    clearInterval(reloj);
    if (llave) { llave.style.opacity = '0'; llave.style.pointerEvents = 'none'; }
  }

  function pedir() {
    if (!campo) return;
    const r = campo.getBoundingClientRect();
    post({ tipo: 'pedir', esPassword: esPassword(campo), host: location.host,
      rect: { x: r.left, y: r.top, w: r.width, h: r.height } });
  }

  document.addEventListener('focusin', (e) => {
    const el = e.target;
    if (candidato(el) && visible(el)) {
      mostrar(el);
      post({ tipo: 'foco', esPassword: esPassword(el), host: location.host });
    } else if (el !== llave) {
      ocultar();
    }
  }, true);

  document.addEventListener('focusout', (e) => {
    if (e.target !== campo) return;
    clearTimeout(ocultarTimer);
    ocultarTimer = setTimeout(() => { if (document.activeElement !== campo) ocultar(); }, 250);
  }, true);

  addEventListener('scroll', colocar, { capture: true, passive: true });
  addEventListener('resize', colocar, { passive: true });

  // Si la página ya abrió con el foco en un campo de acceso (Google lo hace en el paso 2).
  if (candidato(document.activeElement) && visible(document.activeElement)) {
    mostrar(document.activeElement);
    post({ tipo: 'foco', esPassword: esPassword(document.activeElement), host: location.host });
  }

  // MARK: lo que llama Swift

  window.__kurthClaves = {
    /// Escribe usuario y/o contraseña en los campos que corresponden al que tiene el foco (o al
    /// primer formulario de acceso visible). Devuelve qué se llenó.
    llenar(usuario, contrasena) {
      const activo = campo || (candidato(document.activeElement) ? document.activeElement : null);
      let u = null, p = null;
      if (activo && esPassword(activo)) { p = activo; u = usuario ? usuarioPara(activo) : null; }
      else if (activo) { u = activo; p = contrasena ? passwordPara(activo) : null; }
      else {
        p = Array.from(document.querySelectorAll('input[type=password]')).find(visible) || null;
        u = p ? usuarioPara(p) : (Array.from(document.querySelectorAll('input')).find((i) => visible(i) && esUsuario(i)) || null);
      }
      const hecho = [];
      if (u && usuario && (!u.value || u.value === usuario)) { poner(u, usuario); hecho.push('usuario'); }
      if (p && contrasena) { poner(p, contrasena); hecho.push('contraseña'); }
      const ultimo = (p && contrasena) ? p : (u && usuario ? u : null);
      if (ultimo) ultimo.focus();
      ocultar();
      return { hecho, hayPassword: !!p, hayUsuario: !!u };
    },
    hayPassword() {
      return Array.from(document.querySelectorAll('input[type=password]')).some(visible);
    },
  };
})();
