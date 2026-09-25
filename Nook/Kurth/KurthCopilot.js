// Licensed under GPL-3.0. See LICENSE.
//
// KurthCopilot.js — Nook (rama kurth)
//
// Corre en un mundo de JavaScript aislado ("KurthCopilot"): la página no lo ve ni lo puede tocar,
// pero comparte el DOM. Da al agente una "foto" de la página con referencias estables (@e1,
// @e2…) a cada elemento con el que se puede interactuar, y las acciones de respaldo en JavaScript
// para cuando no hay eventos nativos (pestaña sin ventana). La foto es texto, no imagen: cabe en
// el contexto del agente y cada línea dice qué es, cómo se llama y su estado.
//
// Las referencias se guardan en un Map ref → WeakRef y en un WeakMap elemento → ref, así el
// mismo elemento conserva su @eN entre fotos mientras la página no cambie.

(() => {
  if (window.__kurth) return;

  const refs = new Map();      // 'e12' → WeakRef(elemento)
  const ids = new WeakMap();   // elemento → 'e12'
  let next = 1;
  let lastClick = null;

  const ROLES = new Set(['button', 'link', 'checkbox', 'radio', 'tab', 'menuitem', 'menuitemcheckbox',
    'menuitemradio', 'option', 'switch', 'combobox', 'textbox', 'searchbox', 'slider', 'spinbutton',
    'treeitem', 'listbox']);
  const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK']);

  const clean = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const cut = (s, n = 80) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
  const q = (s) => JSON.stringify(s);

  function visible(el) {
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) > 0.01;
  }

  function inViewport(el) {
    const r = el.getBoundingClientRect();
    return r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
  }

  function roleOf(el) {
    const explicit = el.getAttribute('role');
    if (explicit) return explicit;
    const t = el.tagName.toLowerCase();
    if (t === 'a') return el.hasAttribute('href') ? 'link' : null;
    if (t === 'button' || t === 'summary') return 'button';
    if (t === 'select') return el.multiple ? 'listbox' : 'combobox';
    if (t === 'textarea') return 'textbox';
    if (t === 'input') {
      const ty = (el.type || 'text').toLowerCase();
      return ({ checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button',
        image: 'button', range: 'slider', number: 'spinbutton', search: 'searchbox', file: 'file' })[ty] || 'textbox';
    }
    if (/^h[1-6]$/.test(t)) return 'heading';
    if (el.isContentEditable) return 'textbox';
    return null;
  }

  function isInteractive(el) {
    const t = el.tagName;
    if (t === 'A') return el.hasAttribute('href');
    if (t === 'BUTTON' || t === 'SELECT' || t === 'TEXTAREA' || t === 'SUMMARY') return true;
    if (t === 'INPUT') return el.type !== 'hidden';
    const r = el.getAttribute('role');
    if (r && ROLES.has(r)) return true;
    if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return true;
    if (el.hasAttribute('onclick')) return true;
    const ti = el.getAttribute('tabindex');
    return ti !== null && Number(ti) >= 0;
  }

  function nameOf(el) {
    const aria = el.getAttribute('aria-label');
    if (clean(aria)) return clean(aria);
    const by = el.getAttribute('aria-labelledby');
    if (by) {
      const s = by.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean)
        .map((n) => n.innerText || n.textContent).join(' ');
      if (clean(s)) return clean(s);
    }
    if (el.labels && el.labels.length) {
      const s = Array.from(el.labels).map((l) => l.innerText || l.textContent).join(' ');
      if (clean(s)) return clean(s);
    }
    const t = el.tagName;
    if (t === 'INPUT' && ['button', 'submit', 'reset'].includes(el.type)) return clean(el.value);
    if (t === 'IMG' || (t === 'INPUT' && el.type === 'image')) return clean(el.alt);
    if (t !== 'INPUT' && t !== 'TEXTAREA' && t !== 'SELECT') {
      const inner = clean(el.innerText || el.textContent);
      if (inner) return inner;
      const img = el.querySelector && el.querySelector('img[alt]');
      if (img && clean(img.alt)) return clean(img.alt);
    }
    return clean(el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('name') || '');
  }

  function refFor(el) {
    let id = ids.get(el);
    if (!id) { id = 'e' + next++; ids.set(el, id); }
    refs.set(id, new WeakRef(el));
    return id;
  }

  function line(el, role, ref) {
    let s = '- ' + role;
    const name = cut(nameOf(el));
    if (name) s += ' ' + q(name);
    if (ref) s += ' [@' + ref + ']';
    const t = el.tagName;
    if (role === 'heading') s += ' (' + t.toLowerCase() + ')';
    if (t === 'INPUT' || t === 'TEXTAREA') {
      const ty = (el.type || '').toLowerCase();
      if (ty && !['text', 'checkbox', 'radio', 'submit', 'button', 'search'].includes(ty)) s += ' tipo=' + ty;
      if (ty === 'checkbox' || ty === 'radio') s += el.checked ? ' marcado' : ' sin marcar';
      else if (ty === 'password') s += el.value ? ' (con contraseña escrita)' : '';
      else if (el.value) s += ' valor=' + q(cut(el.value, 60));
    }
    if (t === 'SELECT') {
      const opt = el.options[el.selectedIndex];
      if (opt) s += ' elegido=' + q(cut(clean(opt.text), 40));
      s += ' opciones=' + q(cut(Array.from(el.options).map((o) => clean(o.text)).join(' | '), 120));
    }
    if (t === 'A') {
      const href = el.getAttribute('href') || '';
      if (href && !href.startsWith('javascript:')) s += ' → ' + cut(href, 60);
    }
    const expanded = el.getAttribute('aria-expanded');
    if (expanded !== null) s += expanded === 'true' ? ' abierto' : ' cerrado';
    if (el.getAttribute('aria-checked') === 'true' || el.getAttribute('aria-selected') === 'true') s += ' activo';
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') s += ' deshabilitado';
    if (!inViewport(el)) s += ' (fuera de vista)';
    return s;
  }

  function visit(el, out) {
    if (out.lines.length >= out.max || SKIP.has(el.tagName)) return;
    const interactive = isInteractive(el);
    const role = roleOf(el);
    if ((interactive || role === 'heading') && visible(el)) {
      out.lines.push(line(el, role || 'elemento', interactive ? refFor(el) : null));
      // Adentro de un enlace o un botón no hay nada más que tocar por separado.
      if (interactive && (el.tagName === 'A' || el.tagName === 'BUTTON')) return;
    }
    if (el.shadowRoot) for (const c of el.shadowRoot.children) visit(c, out);
    for (const c of el.children) visit(c, out);
  }

  function element(ref) {
    const clave = String(ref).replace(/^@/, '');
    const e = refs.get(clave) && refs.get(clave).deref();
    if (!e || !e.isConnected) throw new Error('La referencia @' + clave + ' ya no existe en la página; toma otra foto (snapshot).');
    return e;
  }

  function describe(el) {
    const role = roleOf(el) || el.tagName.toLowerCase();
    const name = cut(nameOf(el), 50);
    return role + (name ? ' ' + q(name) : '');
  }


  // ── Señalar: marcas de Kurth (azul) y del agente (ámbar) ─────────────────────────────────
  // Cajas, resaltados de texto, notas, pines numerados y el anillo de guía. Todo vive en un
  // shadow root cerrado dentro de <kurth-capa>, en coordenadas del documento: se mueve con el
  // scroll solo y la página no lo puede estilizar ni leer. El texto se resalta con la API de
  // resaltado de CSS (CSS.highlights), que no toca el HTML. Diseño: kurth/diseño-señalar.md.
  const COLOR = { tu: '#0A84FF', agente: '#FF9F0A' };
  const registro = new Map();   // id → { autor, tipo, nodos: [], rango?, elemento?, caja?, nota }
  let capa = null, sombra = null;

  function asegurarCapa() {
    if (capa && capa.isConnected) return sombra;
    capa = document.createElement('kurth-capa');
    capa.style.cssText = 'position:absolute;top:0;left:0;width:0;height:0;z-index:2147483647;pointer-events:none;';
    sombra = capa.attachShadow({ mode: 'closed' });
    const estilo = document.createElement('style');
    estilo.textContent = `
      .caja{position:absolute;border:2px solid var(--c);border-radius:8px;background:color-mix(in srgb,var(--c) 10%,transparent);box-sizing:border-box}
      .nota{position:absolute;width:max-content;max-width:260px;font:500 12px -apple-system,system-ui;color:#fff;background:var(--c);
            padding:5px 9px;border-radius:9px;box-shadow:0 2px 8px rgba(0,0,0,.18);line-height:1.35}
      .pin{position:absolute;min-width:20px;height:20px;padding:0 5px;border-radius:10px;background:var(--c);color:#fff;
           font:700 11px -apple-system,system-ui;display:flex;align-items:center;justify-content:center;
           box-shadow:0 1px 4px rgba(0,0,0,.25);pointer-events:auto;cursor:pointer}
      .pulso{position:absolute;border:3px solid var(--c);border-radius:12px;animation:pulso 1.2s ease-out infinite}
      @keyframes pulso{0%{box-shadow:0 0 0 0 color-mix(in srgb,var(--c) 55%,transparent)}100%{box-shadow:0 0 0 14px transparent}}
      .destello{animation:destello .9s ease-out 2}
      @keyframes destello{0%,100%{opacity:1}50%{opacity:.25}}`;
    sombra.appendChild(estilo);
    document.documentElement.appendChild(capa);
    // ::highlight tiene que vivir en el documento: el shadow root no pinta texto de afuera.
    if (!document.getElementById('kurth-resaltados')) {
      const h = document.createElement('style');
      h.id = 'kurth-resaltados';
      h.textContent = '::highlight(kurth-tu){background-color:rgba(10,132,255,.28)} ::highlight(kurth-agente){background-color:rgba(255,159,10,.38)}';
      (document.head || document.documentElement).appendChild(h);
    }
    return sombra;
  }

  const docRect = (r) => ({ x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height });

  function nodo(clase, autor, css) {
    const n = document.createElement('div');
    n.className = clase;
    n.style.cssText = css;
    n.style.setProperty('--c', COLOR[autor] || COLOR.agente);
    asegurarCapa().appendChild(n);
    return n;
  }

  function colocar(n, x, y, w, h) {
    n.style.left = x + 'px'; n.style.top = y + 'px';
    if (w !== undefined) { n.style.width = w + 'px'; n.style.height = h + 'px'; }
  }

  function repintarResaltados() {
    if (typeof Highlight !== 'function' || !CSS.highlights) return;
    for (const autor of ['tu', 'agente']) {
      const rangos = [...registro.values()].filter((m) => m.autor === autor && m.rango).map((m) => m.rango);
      if (rangos.length) CSS.highlights.set('kurth-' + autor, new Highlight(...rangos));
      else CSS.highlights.delete('kurth-' + autor);
    }
  }

  // Los rectángulos de un Range, uno por renglón y en coordenadas del documento. getClientRects
  // devuelve un rectángulo por cada inline anidado (enlace, negrita) y por cada nodo de texto, así
  // que se funden los que comparten renglón (misma altura, a 2 px) en uno solo.
  function renglonesDe(rango) {
    const salida = [];
    for (const r of rango.getClientRects()) {
      if (r.width < 1 || r.height < 1) continue;
      const d = docRect(r);
      const igual = salida.find((s) => Math.abs(s.y - d.y) <= 2 && Math.abs(s.h - d.h) <= 2);
      if (igual) {
        const x2 = Math.max(igual.x + igual.w, d.x + d.w);
        igual.x = Math.min(igual.x, d.x); igual.w = x2 - igual.x;
      } else salida.push(d);
    }
    return salida;
  }

  function union(rects) {
    const x = Math.min(...rects.map((r) => r.x)), y = Math.min(...rects.map((r) => r.y));
    return { x, y, w: Math.max(...rects.map((r) => r.x + r.w)) - x, h: Math.max(...rects.map((r) => r.y + r.h)) - y };
  }

  // Dibuja nota y pin junto a un rectángulo del documento.
  function adornos(m, id, rect, numero, nota) {
    if (numero) {
      const pin = nodo('pin', m.autor, '');
      pin.textContent = String(numero);
      colocar(pin, rect.x - 10, rect.y - 10);
      pin.addEventListener('click', () => destellar(id));
      m.nodos.push(pin);
    }
    if (nota) {
      const n = nodo('nota', m.autor, '');
      n.textContent = nota;
      colocar(n, rect.x, rect.y + rect.h + 6);
      m.nodos.push(n);
    }
  }

  // Busca un texto en la página (sin distinguir espacios ni mayúsculas) y devuelve un Range.
  // Con prefijo/sufijo desempata entre apariciones repetidas.
  function buscarTexto(exacto, prefijo, sufijo) {
    const norm = (t) => t.replace(/\s+/g, ' ').toLowerCase();
    const buscado = norm(clean(exacto));
    if (!buscado) return null;
    const nodos = [], tramos = [];
    let todo = '';
    const tw = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
    for (let t = tw.nextNode(); t; t = tw.nextNode()) {
      if (!t.parentElement || SKIP.has(t.parentElement.tagName) || t.parentElement.closest('kurth-capa')) continue;
      const v = norm(t.nodeValue);
      if (!v.trim()) continue;
      nodos.push(t); tramos.push([todo.length, todo.length + v.length]); todo += v;
    }
    let mejor = -1, puntos = -1;
    for (let i = todo.indexOf(buscado); i !== -1; i = todo.indexOf(buscado, i + 1)) {
      let p = 0;
      if (prefijo && todo.slice(Math.max(0, i - 60), i).includes(norm(prefijo).slice(-20))) p++;
      if (sufijo && todo.slice(i + buscado.length, i + buscado.length + 60).includes(norm(sufijo).slice(0, 20))) p++;
      if (p > puntos) { puntos = p; mejor = i; }
    }
    if (mejor < 0) return null;
    const fin = mejor + buscado.length;
    const ubicar = (pos) => {
      for (let k = 0; k < nodos.length; k++) {
        const [a, b] = tramos[k];
        if (pos >= a && pos <= b) return [nodos[k], Math.min(pos - a, nodos[k].nodeValue.length)];
      }
      return null;
    };
    const ini = ubicar(mejor), fn = ubicar(fin);
    if (!ini || !fn) return null;
    const r = document.createRange();
    r.setStart(ini[0], ini[1]); r.setEnd(fn[0], fn[1]);
    return r;
  }

  function contexto(rango, n) {
    const todo = (document.body && document.body.innerText) || '';
    const exacto = clean(rango.toString());
    const i = todo.replace(/\s+/g, ' ').indexOf(exacto);
    const plano = todo.replace(/\s+/g, ' ');
    return i < 0 ? { prefijo: '', sufijo: '' }
      : { prefijo: plano.slice(Math.max(0, i - n), i), sufijo: plano.slice(i + exacto.length, i + exacto.length + n) };
  }

  // Selector CSS corto para volver a encontrar un contenedor.
  function selectorDe(el) {
    if (!el || el === document.body) return 'body';
    if (el.id && /^[A-Za-z][\w-]*$/.test(el.id)) return '#' + el.id;
    const partes = [];
    for (let e = el; e && e !== document.body && partes.length < 6; e = e.parentElement) {
      let s = e.tagName.toLowerCase();
      if (e.id && /^[A-Za-z][\w-]*$/.test(e.id)) { partes.unshift('#' + e.id); break; }
      const hermanos = e.parentElement ? Array.from(e.parentElement.children).filter((h) => h.tagName === e.tagName) : [];
      if (hermanos.length > 1) s += ':nth-of-type(' + (hermanos.indexOf(e) + 1) + ')';
      partes.unshift(s);
    }
    return partes.join(' > ');
  }

  function destellar(id) {
    const m = registro.get(id);
    if (!m) return false;
    const objetivo = m.elemento || (m.rango && m.rango.startContainer.parentElement);
    if (objetivo) objetivo.scrollIntoView({ block: 'center', behavior: 'smooth' });
    else if (m.caja) window.scrollTo({ top: Math.max(0, m.caja.y - innerHeight / 3), behavior: 'smooth' });
    for (const n of m.nodos) { n.classList.remove('destello'); void n.offsetWidth; n.classList.add('destello'); }
    return true;
  }

  const marcas = {
    // Caja libre: x, y, w, h en coordenadas del viewport (px CSS).
    caja(o) {
      const rect = { x: o.x + scrollX, y: o.y + scrollY, w: o.w, h: o.h };
      const m = { autor: o.autor, tipo: 'caja', nodos: [], caja: rect, nota: o.nota || '' };
      registro.set(o.id, m);
      const n = nodo('caja', o.autor, '');
      colocar(n, rect.x, rect.y, rect.w, rect.h);
      m.nodos.push(n);
      adornos(m, o.id, rect, o.numero, o.nota);
      return o.id;
    },
    elemento(o) {
      const e = element(o.ref);
      const r = docRect(e.getBoundingClientRect());
      const pad = 4;
      const rect = { x: r.x - pad, y: r.y - pad, w: r.w + pad * 2, h: r.h + pad * 2 };
      const m = { autor: o.autor, tipo: o.pulso ? 'pulso' : 'elemento', nodos: [], elemento: e, caja: rect, nota: o.nota || '' };
      registro.set(o.id, m);
      const n = nodo(o.pulso ? 'pulso' : 'caja', o.autor, '');
      colocar(n, rect.x, rect.y, rect.w, rect.h);
      m.nodos.push(n);
      adornos(m, o.id, rect, o.numero, o.nota);
      return describe(e);
    },
    texto(o) {
      const rango = buscarTexto(o.texto, o.prefijo, o.sufijo);
      if (!rango) throw new Error('No encontré ese texto en la página: ' + q(cut(o.texto, 60)));
      const m = { autor: o.autor, tipo: 'texto', nodos: [], rango, nota: o.nota || '' };
      registro.set(o.id, m);
      repintarResaltados();
      // Además del resaltado del texto, un recuadro por renglón, como las cajas que pone Kurth
      // (24 sep: "que sus marcas igual sean recuadros, no solo globos"). El ::highlight solo tiñe el
      // fondo de las letras y en una página clara casi no se nota.
      const renglones = renglonesDe(rango);
      const pad = 3;
      for (const r of renglones) {
        const n = nodo('caja', o.autor, '');
        colocar(n, r.x - pad, r.y - pad, r.w + pad * 2, r.h + pad * 2);
        m.nodos.push(n);
      }
      const primero = renglones[0] || docRect(rango.getBoundingClientRect());
      m.caja = renglones.length ? union(renglones) : primero;
      adornos(m, o.id, { x: primero.x - pad, y: primero.y - pad, w: primero.w + pad * 2, h: primero.h + pad * 2 }, o.numero, o.nota);
      return clean(rango.toString());
    },
    destellar,
    quitar(id) {
      const m = registro.get(id);
      if (!m) return false;
      m.nodos.forEach((n) => n.remove());
      registro.delete(id);
      repintarResaltados();
      return true;
    },
    limpiar(autor) {
      for (const [id, m] of [...registro]) if (!autor || m.autor === autor) marcas.quitar(id);
      return registro.size;
    },
    lista() { return [...registro].map(([id, m]) => ({ id, autor: m.autor, tipo: m.tipo, nota: m.nota })); },

    // Ancla de un elemento (su caja en el viewport), para guardarlo como zona.
    anclaDe(ref) {
      const r = element(ref).getBoundingClientRect();
      return marcas.contenido({ x: r.left - 4, y: r.top - 4, w: r.width + 8, h: r.height + 8 }).ancla;
    },

    // Lo que queda dentro de una caja del viewport: texto, elementos con referencia e imágenes,
    // y un ancla para volver a encontrarla (contenedor + posición relativa + texto citado).
    contenido(o) {
      const dentro = (r) => {
        const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        return cx >= o.x && cx <= o.x + o.w && cy >= o.y && cy <= o.y + o.h;
      };
      const textos = [];
      const tw = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
      for (let t = tw.nextNode(); t && textos.length < 400; t = tw.nextNode()) {
        const p = t.parentElement;
        if (!p || SKIP.has(p.tagName) || p.closest('kurth-capa') || !clean(t.nodeValue)) continue;
        const r = document.createRange(); r.selectNodeContents(t);
        if (Array.from(r.getClientRects()).some(dentro)) textos.push(clean(t.nodeValue));
      }
      const elementos = [];
      const imagenes = [];
      for (const el of document.querySelectorAll('*')) {
        if (elementos.length >= 40) break;
        if (SKIP.has(el.tagName) || el.closest('kurth-capa')) continue;
        const r = el.getBoundingClientRect();
        if (r.width < 1 || !dentro(r)) continue;
        if (isInteractive(el) && visible(el)) elementos.push(line(el, roleOf(el) || 'elemento', refFor(el)));
        else if (el.tagName === 'IMG' && imagenes.length < 10) imagenes.push(clean(el.alt) || cut(el.currentSrc || el.src, 80));
      }
      const centro = document.elementFromPoint(o.x + o.w / 2, o.y + o.h / 2);
      let contenedor = centro;
      while (contenedor && contenedor !== document.body) {
        const r = contenedor.getBoundingClientRect();
        if (r.left <= o.x && r.top <= o.y && r.right >= o.x + o.w && r.bottom >= o.y + o.h) break;
        contenedor = contenedor.parentElement;
      }
      const rc = (contenedor || document.body).getBoundingClientRect();
      const texto = cut(textos.join(' '), 2000);
      return {
        texto, elementos, imagenes,
        ancla: { selector: selectorDe(contenedor || document.body),
                 relativa: { x: o.x - rc.left, y: o.y - rc.top, w: o.w, h: o.h },
                 cita: cut(texto, 120), documento: { x: o.x + scrollX, y: o.y + scrollY, w: o.w, h: o.h } },
      };
    },

    // Lo que el usuario tiene seleccionado, con contexto para re-anclarlo.
    seleccion() {
      const sel = getSelection();
      if (!sel || sel.isCollapsed || !clean(sel.toString())) return null;
      const r = sel.getRangeAt(0);
      const c = contexto(r, 40);
      return { texto: cut(clean(r.toString()), 2000), prefijo: c.prefijo, sufijo: c.sufijo };
    },

    // Vuelve a dibujar marcas guardadas (persistencia). Cajas: por su contenedor y posición
    // relativa; si el contenedor ya no está, por su posición en el documento.
    restaurar(lista) {
      let n = 0;
      for (const m of lista || []) {
        if (registro.has(m.id)) continue;
        try {
          if (m.tipo === 'texto') { marcas.texto(Object.assign({}, m, { texto: m.cita })); n++; continue; }
          const a = m.ancla || {};
          let x, y;
          const cont = a.selector && document.querySelector(a.selector);
          if (cont && a.relativa) { const rc = cont.getBoundingClientRect(); x = rc.left + a.relativa.x; y = rc.top + a.relativa.y; }
          else if (a.documento) { x = a.documento.x - scrollX; y = a.documento.y - scrollY; }
          else continue;
          const w = (a.relativa || a.documento).w, h = (a.relativa || a.documento).h;
          marcas.caja({ id: m.id, autor: m.autor, x, y, w, h, nota: m.nota, numero: m.numero });
          n++;
        } catch (e) { /* la página cambió: esa marca ya no se ancla */ }
      }
      return n;
    },
  };

  // Pide a Nook las marcas guardadas de esta dirección en cuanto carga la página.
  try {
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kurthSenalar;
    if (h && window.top === window) setTimeout(() => h.postMessage({ tipo: 'pedirMarcas', url: location.href }), 600);
  } catch (e) { /* sin canal: marcas solo en vivo */ }

  window.__kurth = {
    marcas,

    snapshot(max) {
      const out = { lines: [], max: max || 400 };
      visit(document.body || document.documentElement, out);
      const header = 'Página: ' + (document.title || '(sin título)') + ' — ' + location.href +
        '\nScroll: ' + Math.round(scrollY) + ' de ' + Math.max(0, document.documentElement.scrollHeight - innerHeight) + ' px';
      const tail = out.lines.length >= out.max ? '\n… (la foto se cortó en ' + out.max + ' elementos)' : '';
      const frames = document.querySelectorAll('iframe').length;
      const note = frames ? '\n(' + frames + ' iframe(s) no incluidos en la foto)' : '';
      return header + '\n\n' + out.lines.join('\n') + tail + note;
    },

    // Deja el elemento a la vista y devuelve su centro en coordenadas del viewport (px CSS), para
    // el click nativo. Arma una sonda que anota el siguiente click que llegue, y si fue humano.
    prepare(ref) {
      const e = element(ref);
      e.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const r = e.getBoundingClientRect();
      const x = r.left + r.width / 2;
      const y = r.top + r.height / 2;
      const hit = document.elementFromPoint(x, y);
      const covered = hit && hit !== e && !e.contains(hit) && !hit.contains(e) ? describe(hit) : null;
      lastClick = null;
      window.addEventListener('click', (ev) => {
        lastClick = { trusted: ev.isTrusted, onTarget: ev.target === e || e.contains(ev.target) };
      }, { capture: true, once: true });
      return { x, y, vw: innerWidth, vh: innerHeight, covered, target: describe(e) };
    },

    lastClick() { return lastClick; },

    clickJS(ref) {
      const e = element(ref);
      e.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const r = e.getBoundingClientRect();
      const base = { bubbles: true, cancelable: true, composed: true, button: 0,
        clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
      const secuencia = [['pointerdown', PointerEvent], ['mousedown', MouseEvent], ['pointerup', PointerEvent],
        ['mouseup', MouseEvent], ['click', MouseEvent]];
      for (const [tipo, Clase] of secuencia) {
        e.dispatchEvent(new Clase(tipo, Object.assign({ pointerType: 'mouse', isPrimary: true }, base)));
      }
      if (typeof e.focus === 'function') e.focus();
      return describe(e);
    },

    hoverJS(ref) {
      const e = element(ref);
      e.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const r = e.getBoundingClientRect();
      const base = { bubbles: true, composed: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
      for (const tipo of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) {
        const Clase = tipo.startsWith('pointer') ? PointerEvent : MouseEvent;
        e.dispatchEvent(new Clase(tipo, Object.assign({ pointerType: 'mouse' }, base)));
      }
      return describe(e);
    },

    focus(ref, clear) {
      const e = element(ref);
      e.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      if (typeof e.focus === 'function') e.focus();
      if (clear) {
        if (e.isContentEditable) document.execCommand('selectAll');
        else if (typeof e.select === 'function') e.select();
      }
      return document.activeElement === e || e.contains(document.activeElement);
    },

    valueOf(ref) {
      const e = element(ref);
      return e.isContentEditable ? (e.innerText || '') : (e.value !== undefined ? String(e.value) : '');
    },

    // Escribe sin eventos nativos. Primero por el camino de edición del navegador
    // (execCommand insertText, que dispara beforeinput/input como al teclear); si el valor no
    // cambió, con el setter nativo de value + input/change, que es lo que React escucha en un
    // input controlado.
    typeJS(ref, text, clear) {
      const e = element(ref);
      window.__kurth.focus(ref, clear);
      const antes = window.__kurth.valueOf(ref);
      try { document.execCommand('insertText', false, text); } catch (err) { /* sigue abajo */ }
      if (window.__kurth.valueOf(ref) !== antes || (antes.endsWith(text) && !clear)) return window.__kurth.valueOf(ref);
      if (e.isContentEditable) return window.__kurth.valueOf(ref);
      const proto = e instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      setter.call(e, (clear ? '' : e.value) + text);
      e.dispatchEvent(new Event('input', { bubbles: true }));
      e.dispatchEvent(new Event('change', { bubbles: true }));
      return window.__kurth.valueOf(ref);
    },

    select(ref, wanted) {
      const e = element(ref);
      if (e.tagName !== 'SELECT') throw new Error('@' + ref + ' no es una lista de opciones (select).');
      const w = clean(String(wanted)).toLowerCase();
      const opt = Array.from(e.options).find((o) => o.value.toLowerCase() === w || clean(o.text).toLowerCase() === w)
        || Array.from(e.options).find((o) => clean(o.text).toLowerCase().includes(w));
      if (!opt) throw new Error('No hay una opción ' + q(String(wanted)) + '. Opciones: ' + Array.from(e.options).map((o) => clean(o.text)).join(' | '));
      const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set;
      setter.call(e, opt.value);
      e.dispatchEvent(new Event('input', { bubbles: true }));
      e.dispatchEvent(new Event('change', { bubbles: true }));
      return clean(opt.text);
    },

    scroll(ref, dx, dy) {
      const target = ref ? element(ref) : null;
      if (target) target.scrollBy({ left: dx, top: dy, behavior: 'instant' });
      else window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
      return Math.round(scrollY);
    },

    // Teclas sin eventos nativos: solo sirven para páginas que escuchan keydown; no escriben
    // texto ni activan comportamientos del navegador (eso lo hacen las nativas).
    keyJS(key, mods) {
      const t = document.activeElement || document.body;
      const o = Object.assign({ key, bubbles: true, cancelable: true, composed: true }, mods || {});
      t.dispatchEvent(new KeyboardEvent('keydown', o));
      t.dispatchEvent(new KeyboardEvent('keyup', o));
      if (key === 'Enter' && t.form && typeof t.form.requestSubmit === 'function') t.form.requestSubmit();
      return describe(t);
    },
  };
})();
