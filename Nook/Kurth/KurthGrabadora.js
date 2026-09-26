// Licensed under GPL-3.0. See LICENSE.
//
// KurthGrabadora.js — Nook (rama kurth)
//
// El grabador de workflows (KurthWorkflows.swift). Corre en su propio mundo de contenido
// ("KurthGrabadora"): ve el DOM de la página pero no sus variables, y la página no lo ve ni puede
// hablarle a su canal. Nook lo pone en todas las páginas al inicio de la carga; quieto no escucha
// nada: al cargar pregunta a Nook si hay una grabación en su ventana y solo entonces se activa.
//
// Qué manda, un mensaje por paso (lo que una persona contaría como paso, no cada evento):
//   clic      — con rol, texto visible o etiqueta, y un selector estable de respaldo
//   escribir  — un paso por campo con su valor final (se manda al salir del campo, al pulsar Enter,
//               al dar clic en otra cosa o al irse de la página)
//   elegir    — listas <select>;  marcar — casillas y radios;  archivo — nombres de lo que se subió
//   tecla     — Enter, Esc y atajos con ⌘ o ⌃ (no ⌘C/⌘V/⌘A/⌘Z dentro de un campo: eso ya es escribir)
//   enviar    — un formulario enviado sin clic ni Enter (esos ya se contaron)
//   scroll    — solo desplazamientos grandes (¾ de pantalla o más) y hechos por Kurth, no por la página
//
// Nunca sale de la página el valor de una contraseña, un campo de tarjeta o un código de un solo
// uso: se manda «secreto». Tampoco lo que una vez fue contraseña y la página cambió a texto (el
// botón de "mostrar contraseña").
//
// Solo cuenta eventos de verdad (isTrusted): un clic que la página se da a sí misma no es de Kurth.
// La prueba sin Nook (kurth/checks/workflows.sh) enciende `pruebas.sinteticos` para poder
// simular eventos desde JavaScript.
//
(() => {
  'use strict';
  if (window.__kurthGrabadora) return;

  const canal = () => {
    try { return window.webkit.messageHandlers.kurthGrabadora; } catch (_) { return null; }
  };

  let activo = false;
  let sinteticos = false;
  let control = null;
  /** Campo con escritura sin mandar todavía: { el, desde }. */
  let pendiente = null;
  let ultimoClic = null;
  let ultimaTecla = null;
  /** Última rueda, toque o tecla de desplazamiento de Kurth: separa su scroll del de la página. */
  let ultimaEntrada = 0;
  let rollo = null;
  let rolloTimer = 0;
  /** Campos que fueron contraseña alguna vez en esta página. */
  const fueronClave = new WeakSet();

  const ahora = () => Date.now();
  const limpio = (s, max = 80) => {
    const t = String(s || '').replace(/\s+/g, ' ').trim();
    return t.length > max ? t.slice(0, max - 1) + '…' : t;
  };

  const mandar = (paso) => {
    const c = canal();
    if (!c) return;
    if (!paso.ts) paso.ts = ahora();
    for (const k of Object.keys(paso)) if (paso[k] === undefined || paso[k] === '') delete paso[k];
    try {
      const r = c.postMessage({ tipo: 'paso', paso });
      if (r && r.catch) r.catch(() => {});
    } catch (_) {}
  };

  // ── Qué es cada cosa ────────────────────────────────────────────────────────────────────

  const TIPOS_DE_TEXTO = new Set(['text', 'search', 'email', 'url', 'tel', 'number', 'password',
    'date', 'datetime-local', 'month', 'week', 'time', '']);

  const esCampoDeTexto = (el) => !!el && el.nodeType === 1 && (
    (el.tagName === 'INPUT' && TIPOS_DE_TEXTO.has((el.getAttribute('type') || 'text').toLowerCase())) ||
    el.tagName === 'TEXTAREA' || el.isContentEditable);

  const esCasilla = (el) => !!el && el.tagName === 'INPUT' && /^(checkbox|radio)$/i.test(el.type);

  const rolDe = (el) => {
    const explicito = el.getAttribute && el.getAttribute('role');
    if (explicito) return explicito.split(/\s+/)[0];
    const t = el.tagName;
    if (t === 'A' && el.hasAttribute('href')) return 'link';
    if (t === 'BUTTON' || t === 'SUMMARY') return 'button';
    if (t === 'INPUT') {
      const tipo = (el.type || 'text').toLowerCase();
      if (['button', 'submit', 'reset', 'image'].includes(tipo)) return 'button';
      if (tipo === 'checkbox' || tipo === 'radio' || tipo === 'file') return tipo;
      if (tipo === 'range') return 'slider';
      return 'textbox';
    }
    if (t === 'TEXTAREA' || el.isContentEditable) return 'textbox';
    if (t === 'SELECT') return 'combobox';
    if (/^H[1-6]$/.test(t)) return 'heading';
    if (t === 'IMG') return 'img';
    if (t === 'LABEL') return 'label';
    if (t === 'FORM') return 'form';
    return 'generic';
  };

  const textoDeIds = (ids) => ids.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean)
    .map((n) => n.innerText || n.textContent || '').join(' ');

  /** La etiqueta de un campo, como la leería una persona. */
  const etiquetaDe = (el) => {
    const aria = el.getAttribute('aria-label');
    if (aria && aria.trim()) return limpio(aria);
    const por = el.getAttribute('aria-labelledby');
    if (por) { const t = limpio(textoDeIds(por)); if (t) return t; }
    if (el.labels && el.labels.length) {
      const t = limpio(Array.from(el.labels).map((l) => l.innerText || l.textContent).join(' '));
      if (t) return t;
    }
    for (const a of ['placeholder', 'title', 'name']) {
      const v = el.getAttribute(a);
      if (v && v.trim()) return limpio(v);
    }
    return '';
  };

  /** El nombre de algo que se toca: su texto visible, o lo que lo nombra si no tiene texto (iconos). */
  const nombreDe = (el) => {
    const aria = el.getAttribute('aria-label');
    if (aria && aria.trim()) return limpio(aria);
    const por = el.getAttribute('aria-labelledby');
    if (por) { const t = limpio(textoDeIds(por)); if (t) return t; }
    if (el.tagName === 'INPUT') return limpio(el.value || el.getAttribute('alt') || etiquetaDe(el));
    const texto = limpio(el.innerText || el.textContent || '');
    if (texto) return texto;
    const hijo = el.querySelector && el.querySelector('img[alt],svg[aria-label],[title]');
    if (hijo) {
      const v = hijo.getAttribute('alt') || hijo.getAttribute('aria-label') || hijo.getAttribute('title');
      if (v) return limpio(v);
    }
    return limpio(el.getAttribute('title') || '');
  };

  // ── Selector de respaldo ───────────────────────────────────────────────────────────────

  const escapar = (s) => (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/[^\w-]/g, '\\$&');
  const comillas = (s) => '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  /** Ids y valores que genera un framework en cada carga: no sirven para volver a encontrar nada. */
  const pareceGenerado = (s) => s.length > 40 || /\d{4,}|[0-9a-f]{8,}|^[:_]|^(ember|react|radix|mui|headlessui|rc-|yui_|__)|:r[0-9a-z]+:/i.test(s);
  const unico = (sel, raiz) => { try { return raiz.querySelectorAll(sel).length === 1; } catch (_) { return false; } };

  const selectorDe = (el) => {
    const raiz = el.getRootNode ? el.getRootNode() : document;
    const tag = el.tagName.toLowerCase();
    if (el.id && !pareceGenerado(el.id) && unico('#' + escapar(el.id), raiz)) return '#' + escapar(el.id);
    for (const a of ['data-testid', 'data-test', 'data-qa', 'data-cy', 'name', 'aria-label', 'placeholder', 'title']) {
      const v = el.getAttribute(a);
      if (!v || v.length > 60) continue;
      if ((a === 'name' || a.startsWith('data-')) && pareceGenerado(v)) continue;
      const s = `${tag}[${a}=${comillas(v)}]`;
      if (unico(s, raiz)) return s;
    }
    if (tag === 'a') {
      const h = el.getAttribute('href');
      if (h && h.length <= 120) { const s = `a[href=${comillas(h)}]`; if (unico(s, raiz)) return s; }
    }
    // Ruta corta (hasta 5 niveles), anclada en el ancestro más cercano con un id que no cambia.
    const partes = [];
    let n = el;
    for (let i = 0; n && n.nodeType === 1 && i < 5; i++) {
      if (n !== el && n.id && !pareceGenerado(n.id)) { partes.unshift('#' + escapar(n.id)); break; }
      const t = n.tagName.toLowerCase();
      const padre = n.parentElement;
      if (padre) {
        const hermanos = Array.from(padre.children).filter((c) => c.tagName === n.tagName);
        partes.unshift(hermanos.length > 1 ? `${t}:nth-of-type(${hermanos.indexOf(n) + 1})` : t);
      } else {
        partes.unshift(t);
      }
      n = padre;
      const s = partes.join(' > ');
      if (unico(s, raiz)) return s;
    }
    return partes.join(' > ');
  };

  const describir = (el) => {
    const d = { rol: rolDe(el), nombre: nombreDe(el), selector: selectorDe(el) };
    if (el.tagName === 'A' && el.href) d.href = String(el.href).slice(0, 300);
    return d;
  };

  // ── Secretos ────────────────────────────────────────────────────────────────────────────

  const PISTAS_DE_SECRETO = /passw|contrase|\bpin\b|\bnip\b|cvv|cvc|\bcsc\b|card.?(num|no\b|number)|cc.?(num|number|csc|exp)|tarjeta|security.?code|c[oó]digo de seguridad|expir|vencimiento|one.?time|\botp\b|verification.?code|c[oó]digo de verificaci|\bclabe\b/i;

  const luhn = (d) => {
    let suma = 0;
    for (let i = 0; i < d.length; i++) {
      let x = +d[d.length - 1 - i];
      if (i % 2 === 1) { x *= 2; if (x > 9) x -= 9; }
      suma += x;
    }
    return suma % 10 === 0;
  };

  const pareceTarjeta = (v) => {
    const d = String(v || '').replace(/[\s-]/g, '');
    return /^\d{13,19}$/.test(d) && luhn(d);
  };

  const esSecreto = (el, valor) => {
    if (fueronClave.has(el)) return true;
    if (el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'password') return true;
    const autocompletar = (el.getAttribute('autocomplete') || '').toLowerCase();
    if (/cc-|password|one-time-code/.test(autocompletar)) return true;
    const pistas = [el.getAttribute('name'), el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder'),
      el.getAttribute('data-testid'), etiquetaDe(el)].filter(Boolean).join(' ');
    return PISTAS_DE_SECRETO.test(pistas) || pareceTarjeta(valor);
  };

  const valorDe = (el) => String(el.isContentEditable ? (el.innerText || '') : (el.value || '')).slice(0, 500);

  // ── Escritura: un paso por campo ─────────────────────────────────────────────────────────

  const vaciar = () => {
    if (!pendiente) return;
    const { el, desde } = pendiente;
    pendiente = null;
    const valor = valorDe(el);
    const secreto = esSecreto(el, valor);
    mandar({
      tipo: 'escribir', rol: 'textbox', nombre: etiquetaDe(el), selector: selectorDe(el),
      valor: secreto ? '«secreto»' : valor, secreto: secreto || undefined, ts: desde,
    });
  };

  // ── Escuchas ─────────────────────────────────────────────────────────────────────────────

  const confiable = (e) => e.isTrusted || sinteticos;
  const origenDe = (e) => (e.composedPath && e.composedPath()[0]) || e.target;

  const INTERACTIVO = 'a[href],button,input,select,textarea,summary,label,[role=button],[role=link],[role=tab],' +
    '[role=menuitem],[role=menuitemcheckbox],[role=menuitemradio],[role=option],[role=checkbox],[role=radio],' +
    '[role=switch],[role=treeitem],[role=gridcell],[role=row],[onclick],[contenteditable=""],[contenteditable=true]';

  /** Lo que realmente se tocó: el botón o enlace que contiene al ícono, no el ícono. */
  const clicable = (n) => {
    const el = n && n.nodeType === 1 ? n : (n && n.parentElement);
    if (!el || !el.closest) return null;
    const c = el.closest(INTERACTIVO);
    if (c) return c;
    // Un div con manejador de clic no se anuncia; la mano del cursor lo delata.
    for (let x = el, i = 0; x && i < 4; x = x.parentElement, i++) {
      if (getComputedStyle(x).cursor === 'pointer') return x;
    }
    return null;
  };

  const modificadores = (e) => (e.ctrlKey ? '⌃' : '') + (e.altKey ? '⌥' : '') + (e.shiftKey ? '⇧' : '') + (e.metaKey ? '⌘' : '');

  const alClic = (e) => {
    if (!confiable(e) || e.button !== 0) return;
    const el = clicable(origenDe(e));
    if (!el) return;
    // Campos, listas y casillas los cuentan escribir, elegir y marcar.
    if (esCampoDeTexto(el) || el.tagName === 'SELECT' || esCasilla(el)) return;
    if (el.tagName === 'INPUT' && /^(file|range|color)$/i.test(el.type)) return;
    if (el.tagName === 'LABEL') {
      const c = el.control;
      if (c && (esCasilla(c) || esCampoDeTexto(c) || c.tagName === 'SELECT' || c.type === 'file')) return;
    }
    vaciar();
    const d = describir(el);
    const form = el.form || null;
    const envia = form && (el.type === 'submit' || (el.tagName === 'BUTTON' && (el.getAttribute('type') || 'submit') === 'submit'));
    ultimoClic = { ts: ahora(), form: envia ? form : null };
    const mods = modificadores(e);
    mandar(Object.assign({ tipo: 'clic', doble: e.detail >= 2 || undefined, tecla: mods || undefined }, d));
  };

  const alEntrar = (e) => {
    const el = origenDe(e);
    if (el && el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'password') fueronClave.add(el);
  };

  const alEscribir = (e) => {
    if (!confiable(e)) return;
    const el = origenDe(e);
    if (!esCampoDeTexto(el)) return;
    if (el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'password') fueronClave.add(el);
    if (pendiente && pendiente.el !== el) vaciar();
    if (!pendiente) pendiente = { el, desde: ahora() };
  };

  const alCambiar = (e) => {
    if (!confiable(e)) return;
    const el = origenDe(e);
    if (!el || el.nodeType !== 1) return;
    if (el.tagName === 'SELECT') {
      vaciar();
      const valor = Array.from(el.selectedOptions || []).map((o) => limpio(o.textContent || o.value)).join(', ');
      mandar({ tipo: 'elegir', rol: 'combobox', nombre: etiquetaDe(el), selector: selectorDe(el), valor });
      return;
    }
    if (esCasilla(el)) {
      vaciar();
      const radio = el.type === 'radio';
      mandar({
        tipo: 'marcar', rol: radio ? 'radio' : 'checkbox', nombre: etiquetaDe(el) || limpio(el.value),
        selector: selectorDe(el), valor: radio ? 'elegido' : (el.checked ? 'sí' : 'no'),
      });
      return;
    }
    if (el.tagName === 'INPUT' && el.type === 'file') {
      vaciar();
      const nombres = Array.from(el.files || []).map((f) => f.name).join(', ');
      mandar({ tipo: 'archivo', rol: 'file', nombre: etiquetaDe(el), selector: selectorDe(el), valor: nombres });
      return;
    }
    if (pendiente && pendiente.el === el) vaciar();
  };

  const alSalir = (e) => {
    if (pendiente && pendiente.el === origenDe(e)) vaciar();
  };

  const NOMBRES_DE_TECLA = { Enter: 'Enter', Escape: 'Esc', Tab: 'Tab', ArrowDown: '↓', ArrowUp: '↑',
    ArrowLeft: '←', ArrowRight: '→', Backspace: '⌫', Delete: '⌦', ' ': 'Espacio' };
  const TECLAS_DE_DESPLAZAMIENTO = new Set(['PageDown', 'PageUp', ' ', 'ArrowDown', 'ArrowUp', 'Home', 'End']);

  const alTecla = (e) => {
    if (!confiable(e) || e.isComposing) return;
    if (['Meta', 'Control', 'Alt', 'Shift', 'CapsLock', 'Fn'].includes(e.key)) return;
    const el = origenDe(e);
    const editable = esCampoDeTexto(el);
    // Una tecla de desplazamiento: se anota dónde estaba la página antes de que se mueva.
    if (!editable && TECLAS_DE_DESPLAZAMIENTO.has(e.key)) { ultimaEntrada = ahora(); empezarRollo(principal()); }
    let registrar = false;
    if (e.key === 'Enter') {
      // En un textarea, Enter solo es un salto de línea; en un editable (chats), manda, salvo con ⇧.
      if (el.tagName === 'TEXTAREA') registrar = e.metaKey || e.ctrlKey;
      else registrar = !(el.isContentEditable && e.shiftKey);
    } else if (e.key === 'Escape') {
      registrar = true;
    } else if (e.metaKey || e.ctrlKey) {
      registrar = !(editable && /^[acvxzy]$/i.test(e.key));
    }
    if (!registrar) return;
    vaciar();
    ultimaTecla = { ts: ahora(), form: el.form || null };
    const nombre = NOMBRES_DE_TECLA[e.key] || (e.key.length === 1 ? e.key.toUpperCase() : e.key);
    const paso = { tipo: 'tecla', tecla: modificadores(e) + nombre };
    if (editable) Object.assign(paso, { rol: 'textbox', nombre: etiquetaDe(el), selector: selectorDe(el) });
    mandar(paso);
  };

  const alEnviar = (e) => {
    const f = origenDe(e);
    vaciar();
    const t = ahora();
    if (ultimoClic && ultimoClic.form === f && t - ultimoClic.ts < 1500) return;
    if (ultimaTecla && ultimaTecla.form === f && t - ultimaTecla.ts < 1500) return;
    if (!confiable(e) || !f || f.tagName !== 'FORM') return;
    mandar({ tipo: 'enviar', rol: 'form', nombre: limpio(f.getAttribute('aria-label') || f.getAttribute('name') || ''), selector: selectorDe(f) });
  };

  // ── Scroll: solo el grande y el de Kurth ────────────────────────────────────────────────

  const principal = () => document.scrollingElement || document.documentElement;
  const altoDe = (blanco) => (blanco === principal() ? window.innerHeight : blanco.clientHeight) || 1;

  const alRueda = () => { ultimaEntrada = ahora(); };

  /** El encabezado a la vista en la mitad de arriba; si no hay, el de la sección en que se quedó. */
  const encabezadoVisible = () => {
    const lista = document.querySelectorAll('h1,h2,h3,[role=heading]');
    let anterior = null;
    for (let i = 0; i < lista.length && i < 300; i++) {
      const r = lista[i].getBoundingClientRect();
      if (r.height === 0) continue;
      if (r.bottom > 0 && r.top < window.innerHeight * 0.5) return limpio(lista[i].innerText || lista[i].textContent, 60);
      if (r.top < 0) anterior = lista[i];
    }
    return anterior ? limpio(anterior.innerText || anterior.textContent, 60) : '';
  };

  const cerrarRollo = () => {
    clearTimeout(rolloTimer);
    if (!rollo) return;
    const { blanco, desde, ts } = rollo;
    rollo = null;
    const alto = altoDe(blanco);
    const y = blanco.scrollTop;
    const dy = y - desde;
    if (Math.abs(dy) < alto * 0.75) return;
    const max = Math.max(1, blanco.scrollHeight - alto);
    const pantallas = (Math.abs(dy) / alto).toFixed(1).replace('.0', '');
    mandar({
      tipo: 'scroll', valor: dy > 0 ? 'abajo' : 'arriba', ts,
      detalle: `${pantallas} ${pantallas === '1' ? 'pantalla' : 'pantallas'} (al ${Math.round(Math.min(1, y / max) * 100)} %)`,
      nombre: encabezadoVisible(), selector: blanco === principal() ? undefined : selectorDe(blanco),
    });
  };

  const alDesplazar = (e) => {
    const t = e.target;
    const blanco = (t === window || t === document || t === document.documentElement || t === document.body) ? principal() : t;
    if (!blanco || blanco.nodeType !== 1) return;
    if (blanco !== principal() && blanco.clientHeight < window.innerHeight * 0.5) return;
    if (!sinteticos && ahora() - ultimaEntrada > 1200) return; // lo movió la página, no Kurth
    empezarRollo(blanco);
  };

  /** Abre (o sigue) un desplazamiento: se cierra 700 ms después del último evento. */
  const empezarRollo = (blanco) => {
    if (rollo && rollo.blanco !== blanco) cerrarRollo();
    if (!rollo) rollo = { blanco, desde: blanco.scrollTop, ts: ahora() };
    clearTimeout(rolloTimer);
    rolloTimer = setTimeout(cerrarRollo, 700);
  };

  // El primer evento de scroll ya trae la página movida; con esto se sabe dónde estaba antes.
  const alEmpezarRueda = (e) => {
    alRueda();
    if (rollo) return;
    const t = e.target && e.target.nodeType === 1 ? e.target : null;
    let x = t;
    while (x && x !== document.documentElement) {
      if (x.scrollHeight > x.clientHeight + 4 && x.clientHeight >= window.innerHeight * 0.5) {
        const estilo = getComputedStyle(x).overflowY;
        if (estilo === 'auto' || estilo === 'scroll') break;
      }
      x = x.parentElement;
    }
    empezarRollo(x && x !== document.documentElement ? x : principal());
  };

  const alIrse = () => { vaciar(); cerrarRollo(); };

  // ── Encender y apagar ────────────────────────────────────────────────────────────────────

  const activar = () => {
    if (activo) return true;
    activo = true;
    control = new AbortController();
    const c = { capture: true, signal: control.signal };
    const pasivo = { capture: true, passive: true, signal: control.signal };
    window.addEventListener('click', alClic, c);
    window.addEventListener('focusin', alEntrar, c);
    window.addEventListener('input', alEscribir, c);
    window.addEventListener('change', alCambiar, c);
    window.addEventListener('focusout', alSalir, c);
    window.addEventListener('keydown', alTecla, c);
    window.addEventListener('submit', alEnviar, c);
    window.addEventListener('wheel', alEmpezarRueda, pasivo);
    window.addEventListener('touchmove', alRueda, pasivo);
    window.addEventListener('scroll', alDesplazar, pasivo);
    window.addEventListener('pagehide', alIrse, { signal: control.signal });
    // Si Kurth ya tenía un campo de contraseña enfocado al empezar.
    if (document.activeElement) alEntrar({ target: document.activeElement });
    return true;
  };

  const desactivar = () => {
    if (!activo) return true;
    alIrse();
    activo = false;
    if (control) control.abort();
    control = null;
    return true;
  };

  window.__kurthGrabadora = Object.freeze({
    activar,
    desactivar,
    vaciar: () => { alIrse(); return true; },
    get activo() { return activo; },
    pruebas: Object.freeze({ sinteticos: (v) => { sinteticos = !!v; return sinteticos; } }),
  });

  // Al cargar: ¿hay una grabación en la ventana de esta pestaña? Nook contesta por el mismo canal.
  const c = canal();
  if (c) {
    try {
      const r = c.postMessage({ tipo: 'hola' });
      if (r && r.then) r.then((v) => { if (v && v.grabando) activar(); }).catch(() => {});
    } catch (_) {}
  }
})();
