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
    // Un campo de archivo oculto tras un botón "Subir" también se lista: upload_file lo usa directo.
    const archivoOculto = el.tagName === 'INPUT' && el.type === 'file';
    if ((interactive || role === 'heading') && (visible(el) || archivoOculto)) {
      out.lines.push(line(el, role || 'elemento', interactive ? refFor(el) : null) + (archivoOculto && !visible(el) ? ' (oculto)' : ''));
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
  // shadow root cerrado dentro de <kurth-capa>, fija al viewport, y la página no lo puede
  // estilizar ni leer. Cada marca guarda su fuente viva (el elemento, el Range del texto o el
  // contenedor de la caja con su posición relativa) y en cada scroll, cambio de tamaño o reflujo
  // se vuelve a colocar desde ahí: una marca sobre una barra fija se queda con la barra, y una
  // sobre un menú que se cierra se esconde hasta que vuelva (Kurth, 24 sep; antes eran
  // coordenadas del documento pintadas una sola vez). El texto se resalta con la API de resaltado
  // de CSS (CSS.highlights), que no toca el HTML. Diseño: kurth/diseño-señalar.md.
  const COLOR = { tu: '#0A84FF', agente: '#FF9F0A' };
  // id → { autor, tipo, claseCaja, cajas: [nodos], pin?, notaNodo?, nota,
  //        elemento? | rango? | (contenedor + relativa, documento) }
  const registro = new Map();
  let capa = null, sombra = null, escuchando = false, pendiente = false;

  function asegurarCapa() {
    if (capa && capa.isConnected) return sombra;
    capa = document.createElement('kurth-capa');
    capa.style.cssText = 'position:fixed;top:0;left:0;width:0;height:0;z-index:2147483647;pointer-events:none;';
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
    if (!escuchando) {
      escuchando = true;
      // Scroll de cualquier contenedor (captura), tamaño de la ventana y reflujo del documento.
      addEventListener('scroll', programarReposicion, { capture: true, passive: true });
      addEventListener('resize', programarReposicion, { passive: true });
      if (typeof ResizeObserver === 'function') new ResizeObserver(programarReposicion).observe(document.documentElement);
    }
    // ::highlight tiene que vivir en el documento: el shadow root no pinta texto de afuera.
    if (!document.getElementById('kurth-resaltados')) {
      const h = document.createElement('style');
      h.id = 'kurth-resaltados';
      h.textContent = '::highlight(kurth-tu){background-color:rgba(10,132,255,.28)} ::highlight(kurth-agente){background-color:rgba(255,159,10,.38)}';
      (document.head || document.documentElement).appendChild(h);
    }
    return sombra;
  }

  const enVista = (r) => ({ x: r.left, y: r.top, w: r.width, h: r.height });
  const inflar = (r, p) => ({ x: r.x - p, y: r.y - p, w: r.w + p * 2, h: r.h + p * 2 });

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

  // Los rectángulos de un Range en el viewport, uno por renglón. getClientRects devuelve uno por
  // cada inline anidado (enlace, negrita) y por cada nodo de texto, así que se funden los que
  // comparten renglón (misma altura, a 2 px) en uno solo.
  function renglonesDe(rango) {
    const salida = [];
    for (const r of rango.getClientRects()) {
      if (r.width < 1 || r.height < 1) continue;
      const d = enVista(r);
      const igual = salida.find((s) => Math.abs(s.y - d.y) <= 2 && Math.abs(s.h - d.h) <= 2);
      if (igual) {
        const x2 = Math.max(igual.x + igual.w, d.x + d.w);
        igual.x = Math.min(igual.x, d.x); igual.w = x2 - igual.x;
      } else salida.push(d);
    }
    return salida;
  }

  // El elemento más chico que contiene una caja del viewport (para que la caja lo siga).
  function contenedorDe(o) {
    let c = document.elementFromPoint(o.x + o.w / 2, o.y + o.h / 2);
    if (c && c.closest('kurth-capa')) c = null;
    while (c && c !== document.body) {
      const r = c.getBoundingClientRect();
      if (r.left <= o.x && r.top <= o.y && r.right >= o.x + o.w && r.bottom >= o.y + o.h) break;
      c = c.parentElement;
    }
    return c || document.body || document.documentElement;
  }

  function base(o, tipo, claseCaja) {
    return { autor: o.autor, tipo, claseCaja, cajas: [], pin: null, notaNodo: null, nota: o.nota || '' };
  }

  const nodosDe = (m) => [...m.cajas, m.pin, m.notaNodo].filter(Boolean);

  // Dónde está hoy la marca, en el viewport: por renglón si es texto, un rectángulo si no. Vacío
  // si su objetivo se fue del DOM o está oculto (display:none da 0×0).
  function geometria(m) {
    if (m.elemento) return m.elemento.isConnected ? [inflar(enVista(m.elemento.getBoundingClientRect()), 4)] : [];
    if (m.rango) return renglonesDe(m.rango).map((r) => inflar(r, 3));
    if (m.contenedor && m.contenedor.isConnected) {
      const rc = m.contenedor.getBoundingClientRect();
      return [{ x: rc.left + m.relativa.x, y: rc.top + m.relativa.y, w: m.relativa.w, h: m.relativa.h }];
    }
    if (m.documento) return [{ x: m.documento.x - scrollX, y: m.documento.y - scrollY, w: m.documento.w, h: m.documento.h }];
    return [];
  }

  // Crea el pin numerado y la nota; dónde van lo decide colocarMarca.
  function adornos(m, id, numero, nota) {
    if (numero) {
      m.pin = nodo('pin', m.autor, '');
      m.pin.textContent = String(numero);
      m.pin.addEventListener('click', () => destellar(id));
    }
    if (nota) {
      m.notaNodo = nodo('nota', m.autor, '');
      m.notaNodo.textContent = nota;
    }
  }

  // Pone cada nodo de la marca donde está hoy su objetivo. Un recuadro por rectángulo (varios
  // renglones en texto), creados o quitados según haga falta. Sin geometría, la marca se esconde
  // sin borrarse: puede volver (un menú que se abre otra vez).
  function colocarMarca(m) {
    const rects = geometria(m).filter((r) => r.w > 0 && r.h > 0);
    while (m.cajas.length < rects.length) m.cajas.push(nodo(m.claseCaja, m.autor, ''));
    while (m.cajas.length > rects.length) m.cajas.pop().remove();
    rects.forEach((r, i) => colocar(m.cajas[i], r.x, r.y, r.w, r.h));
    const primero = rects[0];
    for (const n of [m.pin, m.notaNodo]) if (n) n.style.display = primero ? '' : 'none';
    if (!primero) return;
    if (m.pin) colocar(m.pin, primero.x - 10, primero.y - 10);
    if (m.notaNodo) colocar(m.notaNodo, primero.x, primero.y + primero.h + 6);
  }

  function programarReposicion() {
    if (pendiente || !registro.size) return;
    pendiente = true;
    requestAnimationFrame(() => { pendiente = false; for (const m of registro.values()) colocarMarca(m); });
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
    else {
      const r = geometria(m)[0];
      if (r) scrollBy({ top: r.y + r.h / 2 - innerHeight / 2, behavior: 'smooth' });
    }
    colocarMarca(m);
    for (const n of nodosDe(m)) { n.classList.remove('destello'); void n.offsetWidth; n.classList.add('destello'); }
    return true;
  }

  const marcas = {
    // Caja libre: x, y, w, h en coordenadas del viewport (px CSS).
    // Caja libre: x, y, w, h en el viewport. Sigue al elemento más chico que la contiene
    // (o al que venga en o.contenedor, al restaurar), con su posición relativa a él.
    caja(o) {
      const vista = { x: o.x, y: o.y, w: o.w, h: o.h };
      const contenedor = o.contenedor || contenedorDe(vista);
      const rc = contenedor.getBoundingClientRect();
      const m = base(o, 'caja', 'caja');
      m.contenedor = contenedor;
      m.relativa = { x: vista.x - rc.left, y: vista.y - rc.top, w: vista.w, h: vista.h };
      m.documento = { x: o.x + scrollX, y: o.y + scrollY, w: o.w, h: o.h };
      registro.set(o.id, m);
      adornos(m, o.id, o.numero, o.nota);
      colocarMarca(m);
      return o.id;
    },
    elemento(o) {
      const e = element(o.ref);
      const m = base(o, o.pulso ? 'pulso' : 'elemento', o.pulso ? 'pulso' : 'caja');
      m.elemento = e;
      registro.set(o.id, m);
      adornos(m, o.id, o.numero, o.nota);
      colocarMarca(m);
      return describe(e);
    },
    // Texto: resaltado con CSS.highlights y además un recuadro por renglón, como las cajas de Kurth
    // (24 sep: "que sus marcas igual sean recuadros, no solo globos"); el resaltado solo tiñe el
    // fondo de las letras y en una página clara casi no se nota.
    texto(o) {
      const rango = buscarTexto(o.texto, o.prefijo, o.sufijo);
      if (!rango) throw new Error('No encontré ese texto en la página: ' + q(cut(o.texto, 60)));
      const m = base(o, 'texto', 'caja');
      m.rango = rango;
      registro.set(o.id, m);
      repintarResaltados();
      adornos(m, o.id, o.numero, o.nota);
      colocarMarca(m);
      return clean(rango.toString());
    },
    destellar,
    quitar(id) {
      const m = registro.get(id);
      if (!m) return false;
      nodosDe(m).forEach((n) => n.remove());
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
      const contenedor = contenedorDe(o);
      const rc = contenedor.getBoundingClientRect();
      const texto = cut(textos.join(' '), 2000);
      return {
        texto, elementos, imagenes,
        ancla: { selector: selectorDe(contenedor),
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
          marcas.caja({ id: m.id, autor: m.autor, x, y, w, h, nota: m.nota, numero: m.numero, contenedor: cont || undefined });
          n++;
        } catch (e) { /* la página cambió: esa marca ya no se ancla */ }
      }
      return n;
    },
  };

  // Pide a Nook las marcas guardadas de esta dirección en cuanto carga la página.
  try {
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kurthSenalar;
    // El script entra al inicio de la carga (antes del DOM): las marcas se piden ya con la página armada.
    const pedir = () => setTimeout(() => h.postMessage({ tipo: 'pedirMarcas', url: location.href }), 600);
    if (h && window.top === window) {
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', pedir, { once: true });
      else pedir();
    }
  } catch (e) { /* sin canal: marcas solo en vivo */ }

  // Encabezado fijo pegado arriba de lo visible (Robb Report al bajar): su color va a Nook para
  // pintar la franja detrás de la barra (KurthPageState.scriptHeaderColor). WebKit solo rellena
  // los encabezados que van de orilla a orilla; este deja márgenes y la página se asomaba encima.
  // Solo mientras hay scroll, como mucho cada 100 ms, sin frenarlo (passive), y solo avisa si cambia.
  try {
    const canal = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kurthSenalar;
    if (canal && window.top === window) {
      // Página nueva: el color de la anterior ya no vale (si no, se arrastra un instante).
      canal.postMessage({ tipo: 'encabezado', rgba: null });
      const lienzo = document.createElement('canvas');
      lienzo.width = lienzo.height = 1;
      const ctx = lienzo.getContext('2d', { willReadFrequently: true });
      const cache = new Map();
      // Cualquier color de CSS (rgb, oklch, color(display-p3…)) a [r, g, b, a] de 0 a 255.
      const aRGBA = (css) => {
        if (cache.has(css)) return cache.get(css);
        ctx.clearRect(0, 0, 1, 1);
        ctx.fillStyle = '#000';
        ctx.fillStyle = css;
        ctx.fillRect(0, 0, 1, 1);
        const d = Array.from(ctx.getImageData(0, 0, 1, 1).data);
        cache.set(css, d);
        return d;
      };
      const transparente = (css) => !css || css === 'transparent' || /^rgba\(.*,\s*0\)$/.test(css) || /\/\s*0\)$/.test(css);
      const buscar = () => {
        const w = innerWidth;
        for (const f of [0.5, 0.25, 0.75]) {
          let e = document.elementFromPoint(w * f, 1), color = null;
          while (e && e !== document.documentElement && e !== document.body) {
            const s = getComputedStyle(e);
            if (!color && !transparente(s.backgroundColor)) color = s.backgroundColor;
            if (s.position === 'fixed' || s.position === 'sticky') {
              const r = e.getBoundingClientRect();
              // Su propio fondo manda (es lo que se ve en sus orillas); si no tiene, el de adentro.
              const propio = transparente(s.backgroundColor) ? color : s.backgroundColor;
              if (r.top <= 1 && r.height >= 20 && r.width >= w * 0.5 && propio) return aRGBA(propio);
              break;
            }
            e = e.parentElement;
          }
        }
        return null;
      };
      // Menús fijos escondidos justo arriba de lo visible (ultrajewels: top -60, bottom 0) dejan
      // caer su sombra bajo la barra: una franja gris de corte duro de lado a lado (Kurth, 25 sep).
      // Mientras están enteros arriba se les quita la sombra; al empezar a entrar, se les regresa.
      // La lista de fijos se arma al cargar y se refresca como mucho cada 5 s: recorrer todo el DOM
      // en cada scroll sí costaría.
      let fijos = [], ultimoBarrido = 0;
      const apagadas = new Map();
      const barrer = () => {
        ultimoBarrido = performance.now();
        fijos = [];
        for (const el of document.body ? document.body.getElementsByTagName('*') : []) {
          const p = getComputedStyle(el).position;
          if (p === 'fixed' || p === 'sticky') fijos.push(el);
        }
      };
      const sombras = () => {
        if (!ultimoBarrido || performance.now() - ultimoBarrido > 5000) barrer();
        for (const el of fijos) {
          const r = el.getBoundingClientRect();
          const escondido = r.height > 0 && r.bottom <= 1;
          if (escondido && !apagadas.has(el) && getComputedStyle(el).boxShadow !== 'none') {
            apagadas.set(el, [el.style.getPropertyValue('box-shadow'), el.style.getPropertyPriority('box-shadow')]);
            el.style.setProperty('box-shadow', 'none', 'important');
          } else if (!escondido && apagadas.has(el)) {
            const [valor, prioridad] = apagadas.get(el);
            if (valor) el.style.setProperty('box-shadow', valor, prioridad); else el.style.removeProperty('box-shadow');
            apagadas.delete(el);
          }
        }
      };
      let ultimo = '', agendado = false, ultimaVez = 0;
      const revisar = () => {
        agendado = false;
        ultimaVez = performance.now();
        try { sombras(); } catch (e) { /* una página rara no debe tumbar lo del color */ }
        const c = buscar();
        const clave = c ? c.join(',') : '';
        if (clave === ultimo) return;
        ultimo = clave;
        canal.postMessage({ tipo: 'encabezado', rgba: c });
      };
      const alMover = () => {
        if (agendado) return;
        agendado = true;
        setTimeout(() => requestAnimationFrame(revisar), Math.max(0, 100 - (performance.now() - ultimaVez)));
      };
      addEventListener('scroll', alMover, { passive: true, capture: true });
      addEventListener('resize', alMover, { passive: true });
      // Un menú que se esconde con animación termina de salir después del último scroll: se revisa
      // otra vez cuando acaba su transición.
      addEventListener('transitionend', alMover, { passive: true, capture: true });
      addEventListener('animationend', alMover, { passive: true, capture: true });
      // El script entra al inicio de la carga (Kurth, 25 sep: "que se sume a la carga de la web"): se
      // revisa en cada cuadro desde ya hasta 1.5 s después de que el DOM está listo, así el color y
      // la sombra quedan antes de que la página se vea, no un instante después. Cada revisión cuesta
      // unos microsegundos. Muchas páginas arman su menú después: otro barrido completo a los 1.2 s.
      let hasta = Infinity;
      const cuadro = () => { revisar(); if (performance.now() < hasta) requestAnimationFrame(cuadro); };
      requestAnimationFrame(cuadro);
      const listo = () => {
        barrer();
        revisar();
        hasta = performance.now() + 1500;
        setTimeout(() => { barrer(); revisar(); }, 1200);
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', listo, { once: true });
      else listo();
      addEventListener('load', () => { barrer(); revisar(); }, { once: true });
    }
  } catch (e) { /* sin canal o sin canvas: la barra se queda como WebKit la deje */ }

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

    describir(ref) { return describe(element(ref)); },

    // Para wait_for: ¿se ven el texto y/o la referencia? El texto se busca en lo que la página
    // pinta (innerText respeta display:none y visibility), sin mayúsculas ni espacios de más.
    seVe(texto, ref) {
      if (ref) {
        const clave = String(ref).replace(/^@/, '');
        const e = refs.get(clave) && refs.get(clave).deref();
        if (!e || !e.isConnected || !visible(e)) return false;
      }
      if (texto) {
        const cuerpo = clean((document.body && document.body.innerText) || '').toLowerCase();
        if (!cuerpo.includes(clean(texto).toLowerCase())) return false;
      }
      return true;
    },

    esCampoDeArchivo(ref) { const e = element(ref); return e.tagName === 'INPUT' && e.type === 'file'; },

    // Mete archivos en un <input type=file> sin selector: bytes → File → DataTransfer, y los
    // eventos input/change que escuchan React y compañía.
    ponerArchivos(ref, archivos) {
      const e = element(ref);
      const dt = new DataTransfer();
      for (const a of archivos) {
        const bin = atob(a.b64);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        dt.items.add(new File([bytes], a.nombre, { type: a.tipo }));
      }
      e.files = dt.files;
      e.dispatchEvent(new Event('input', { bubbles: true }));
      e.dispatchEvent(new Event('change', { bubbles: true }));
      return describe(e) + ' (' + e.files.length + ' archivo(s))';
    },

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
