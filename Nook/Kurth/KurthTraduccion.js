// Licensed under GPL-3.0. See LICENSE.
//
// KurthTraduccion.js — Nook (rama kurth)
//
// Traducción de la página en el dispositivo: este lado encuentra el texto, lo entrega en lotes a
// KurthTraduccion.swift (que traduce con el framework Translation de Apple) y pone el resultado
// en su lugar sin tocar la estructura. Corre en el mundo aislado "KurthCopilot": comparte el DOM
// con la página pero la página no ve estas variables ni puede llamar estas funciones.
//
// Unidad = un tramo de texto corrido dentro de un mismo bloque. "Lee nuestra <a>política</a> de
// privacidad" es UNA unidad con tres nodos de texto: se traduce como una frase (con contexto) y
// cada pedazo regresa a su nodo, así el link sigue siendo link. Un bloque (p, li, div, un elemento
// en línea que el CSS vuelve bloque, un <br>) corta la unidad.
//
// Solo se traduce lo que está cerca de la pantalla (IntersectionObserver con una pantalla de
// margen): una página de 5,000 párrafos no manda 5,000 párrafos al modelo si solo se leen tres.
// Lo que la página agregue después (scroll infinito, SPA) lo encuentra un MutationObserver con
// debounce, mientras la traducción siga activa.
//
// "Ver original" regresa cada nodo a su texto, pero solo si sigue diciendo lo que le pusimos: si
// la página lo cambió después (un contador, un re-render), lo de la página manda.

(() => {
  if (window.__kurthTrad) return;

  // Elementos cuyo texto no se traduce: código, campos, lo que no es texto de lectura, y lo que la
  // página marcó como no traducible (translate="no", .notranslate, el estándar de Google/Chrome).
  const SALTAR = new Set(['script', 'style', 'noscript', 'template', 'textarea', 'input', 'select',
    'code', 'pre', 'kbd', 'samp', 'var', 'svg', 'math', 'iframe', 'object', 'embed', 'canvas',
    'video', 'audio', 'head', 'title', 'meta', 'link']);
  // Etiquetas que normalmente van en línea. Solo cuentan como en línea si el CSS las deja así: una
  // <a> con display:block (tarjetas, menús) es un bloque y corta la unidad; si no, "Inicio" y
  // "Acerca" de un menú se pegarían en "InicioAcerca".
  const EN_LINEA = new Set(['a', 'abbr', 'b', 'bdi', 'bdo', 'big', 'cite', 'data', 'del', 'dfn', 'em',
    'font', 'i', 'ins', 'label', 'mark', 'q', 's', 'small', 'span', 'strike', 'strong', 'sub', 'sup',
    'time', 'tt', 'u', 'nobr']);
  const LETRA = /\p{L}/u;
  // Más de esto en una sola unidad y se traduce nodo por nodo: un div con todo el artículo en
  // línea no debe ser una sola petición.
  const MAX_PARTES = 24;
  const MAX_CHARS = 2400;
  const MARGEN = '60% 0px 100% 0px';

  let activa = false;
  let siguiente = 1;
  const unidades = new Map();      // id → unidad
  let deNodo = new WeakMap();      // Text o elemento con placeholder → unidad
  let deObjetivo = new WeakMap();  // elemento observado → Set(unidad)
  const pendientes = [];           // unidades que ya se ven y esperan traducción
  let io = null;
  let mo = null;
  const raicesObservadas = new Set();
  let porRevisar = new Set();
  let reloj = null;
  let aviso = null;

  const limpio = (s) => s.replace(/\s+/g, ' ');
  // Separa el texto en espacio inicial, núcleo y espacio final: se traduce el núcleo y el espacio
  // se respeta tal cual (en HTML el espacio entre un texto y un link es parte del diseño).
  function partir(s) {
    const m = /^(\s*)([\s\S]*?)(\s*)$/.exec(s);
    return { lead: m[1], core: m[2], trail: m[3] };
  }

  function saltar(el) {
    if (SALTAR.has(el.localName)) return true;
    if (el.getAttribute && el.getAttribute('translate') === 'no') return true;
    if (el.classList && el.classList.contains('notranslate')) return true;
    if (el.isContentEditable) return true;
    return false;
  }

  function enLinea(el) {
    if (!EN_LINEA.has(el.localName)) return false;
    const d = getComputedStyle(el).display;
    return d === 'inline' || d === 'contents';
  }

  // ¿Algún ancestro impide traducir? Para lo que llega suelto por el MutationObserver.
  function dentroDeSaltar(nodo) {
    for (let el = nodo.nodeType === 1 ? nodo : nodo.parentElement; el; ) {
      if (saltar(el)) return true;
      if (el.parentElement) { el = el.parentElement; continue; }
      const raiz = el.getRootNode && el.getRootNode();
      el = raiz && raiz.host ? raiz.host : null;
    }
    return false;
  }

  function crear(nodos, seps) {
    const u = { id: siguiente++, nodos, seps, orig: nodos.map((n) => n.data), puestos: null, estado: 'nueva' };
    unidades.set(u.id, u);
    for (const n of nodos) deNodo.set(n, u);
    // Un texto directo en un shadow root no tiene parentElement: se mira a su anfitrión.
    const p = nodos[0].parentNode;
    observar(u, nodos[0].parentElement || (p && p.host) || null);
    return u;
  }

  function crearPlaceholder(el) {
    const u = { id: siguiente++, el, orig: [el.getAttribute('placeholder')], puestos: null, estado: 'nueva' };
    unidades.set(u.id, u);
    deNodo.set(el, u);
    observar(u, el);
    return u;
  }

  function observar(u, objetivo) {
    if (!objetivo) return;
    u.objetivo = objetivo;
    let set = deObjetivo.get(objetivo);
    if (!set) { set = new Set(); deObjetivo.set(objetivo, set); io && io.observe(objetivo); }
    set.add(u);
  }

  // Recorre un subárbol y arma unidades. Entra a los shadow roots abiertos (componentes web).
  function recorrer(raiz) {
    let nodos = null, seps = null, espacio = false;
    let n = 0;
    const cerrar = () => {
      if (nodos && nodos.some((t) => LETRA.test(t.data))) { crear(nodos, seps); n++; }
      nodos = null; seps = null; espacio = false;
    };
    const visitar = (padre) => {
      for (let c = padre.firstChild; c; c = c.nextSibling) {
        if (c.nodeType === 3) {
          if (deNodo.has(c)) { cerrar(); continue; }
          if (!c.data.trim()) { if (c.data.length) espacio = true; continue; }
          if (!nodos) { nodos = []; seps = []; espacio = false; }
          seps.push(nodos.length > 0 && espacio);
          nodos.push(c);
          espacio = false;
        } else if (c.nodeType === 1) {
          if (c.localName === 'input' && !deNodo.has(c)) {
            const ph = c.getAttribute('placeholder');
            if (ph && LETRA.test(ph) && !c.isContentEditable) { crearPlaceholder(c); n++; }
          }
          if (c.localName === 'br') { cerrar(); continue; }
          if (saltar(c)) { cerrar(); continue; }
          if (c.shadowRoot) { cerrar(); visitarRaiz(c.shadowRoot); }
          if (enLinea(c)) { visitar(c); continue; }
          cerrar(); visitar(c); cerrar();
        }
      }
    };
    const visitarRaiz = (r) => {
      if (mo && !raicesObservadas.has(r)) { raicesObservadas.add(r); mo.observe(r, CONFIG_MO); }
      visitar(r); cerrar();
    };
    if (raiz.nodeType === 3) {
      if (!deNodo.has(raiz) && LETRA.test(raiz.data)) { crear([raiz], [false]); n++; }
      return n;
    }
    if (raiz.shadowRoot) visitarRaiz(raiz.shadowRoot);
    visitar(raiz); cerrar();
    return n;
  }

  // ── Cola hacia Swift ─────────────────────────────────────────────────────────────────────

  function encolar(u) {
    if (u.estado === 'cola' || u.estado === 'enviada') return;
    u.estado = 'cola';
    pendientes.push(u);
    avisar();
  }

  // Un aviso por ráfaga: Swift jala con tomar() hasta vaciar la cola.
  function avisar() {
    if (aviso) return;
    aviso = setTimeout(() => {
      aviso = null;
      if (!activa || !pendientes.length) return;
      try { window.webkit.messageHandlers.kurthTraduccion.postMessage({ tipo: 'pendientes', n: pendientes.length }); } catch (e) {}
    }, 60);
  }

  function alVer(entradas) {
    for (const e of entradas) {
      if (!e.isIntersecting) continue;
      const set = deObjetivo.get(e.target);
      if (!set) continue;
      for (const u of set) if (u.estado === 'nueva') encolar(u);
      // Ya encolado todo lo de este elemento: deja de mirarlo. Si la página cambia su texto, el
      // MutationObserver lo vuelve a encolar directo.
      io.unobserve(e.target);
      deObjetivo.delete(e.target);
    }
  }

  const CONFIG_MO = { childList: true, subtree: true, characterData: true };

  function alCambiar(registros) {
    for (const r of registros) {
      if (r.type === 'characterData') {
        const u = deNodo.get(r.target);
        if (!u) { porRevisar.add(r.target); continue; }
        const i = u.nodos.indexOf(r.target);
        // Nuestro propio cambio: se ignora.
        if (u.puestos && u.puestos[i] === r.target.data) continue;
        if (r.target.data === u.orig[i] && !u.puestos) continue;
        // La página lo cambió: ese es el nuevo original y se vuelve a traducir.
        u.orig[i] = r.target.data;
        if (u.puestos) u.puestos[i] = null;
        u.estado = 'nueva';
        encolar(u);
      } else {
        for (const n of r.addedNodes) if (n.nodeType === 1 || n.nodeType === 3) porRevisar.add(n);
      }
    }
    if (porRevisar.size && !reloj) reloj = setTimeout(revisar, 150);
  }

  function revisar() {
    reloj = null;
    if (!activa) { porRevisar.clear(); return; }
    const lista = porRevisar; porRevisar = new Set();
    // Una SPA reemplaza nodos todo el tiempo: las unidades cuyos nodos ya no están se sueltan.
    if (unidades.size > 1000) {
      for (const [id, u] of unidades) {
        const viva = u.el ? u.el.isConnected : u.nodos.some((t) => t.isConnected);
        if (!viva) unidades.delete(id);
      }
    }
    for (const n of lista) {
      if (!n.isConnected) continue;
      // Si un ancestro también llegó en este lote, se recorre desde él.
      let cubierto = false;
      for (let p = n.parentNode; p; p = p.parentNode) if (lista.has(p)) { cubierto = true; break; }
      if (cubierto || dentroDeSaltar(n)) continue;
      recorrer(n);
    }
  }

  // ── API para Swift ───────────────────────────────────────────────────────────────────────

  window.__kurthTrad = {
    // Muestra para detectar el idioma: el lang que declara la página y ~max caracteres de texto
    // de lectura (el <main> o <article> si hay, porque el menú suele venir en otro idioma).
    muestra(max) {
      const raiz = document.querySelector('main, article, [role=main]') || document.body;
      let texto = '';
      const visitar = (padre) => {
        for (let c = padre && padre.firstChild; c && texto.length < max; c = c.nextSibling) {
          if (c.nodeType === 3) { if (LETRA.test(c.data)) texto += limpio(c.data) + ' '; }
          else if (c.nodeType === 1 && !saltar(c)) visitar(c);
        }
      };
      visitar(raiz);
      if (texto.length < max / 4 && raiz !== document.body) visitar(document.body);
      return { lang: document.documentElement.lang || '', texto: texto.slice(0, max), titulo: document.title || '' };
    },

    activar() {
      if (activa) return this.estado();
      activa = true;
      io = new IntersectionObserver(alVer, { rootMargin: MARGEN });
      mo = new MutationObserver(alCambiar);
      raicesObservadas.add(document);
      mo.observe(document, CONFIG_MO);
      recorrer(document.body || document.documentElement);
      return this.estado();
    },

    // Hasta `max` unidades listas para traducir. partes[i] es el núcleo de cada nodo (null si no
    // tiene letras: "·", "|", números); segs es la frase completa con el índice de cada pedazo,
    // para mandarla como AttributedString.
    tomar(max) {
      const lote = [];
      while (lote.length < max && pendientes.length) {
        const u = pendientes.shift();
        if (u.estado !== 'cola') continue;
        if (u.el) {
          if (!u.el.isConnected) { u.estado = 'muerta'; continue; }
          u.estado = 'enviada';
          lote.push({ id: u.id, partes: [limpio(u.orig[0]).trim()] });
          continue;
        }
        if (!u.nodos.some((t) => t.isConnected)) { u.estado = 'muerta'; continue; }
        u.estado = 'enviada';
        const partes = u.orig.map((s) => { const c = limpio(s).trim(); return LETRA.test(c) ? c : null; });
        const item = { id: u.id, partes };
        const utiles = partes.filter((p) => p !== null).length;
        const largo = u.orig.reduce((a, s) => a + s.length, 0);
        if (partes.length > 1 && utiles > 1 && partes.length <= MAX_PARTES && largo <= MAX_CHARS) {
          const segs = [];
          u.orig.forEach((s, i) => {
            const t = limpio(s);
            const conEspacio = i > 0 && u.seps[i] && !/^\s/.test(t) && !(segs.length && /\s$/.test(segs[segs.length - 1][0]));
            if (conEspacio) segs.push([' ', -1]);
            segs.push([i === 0 ? t.trimStart() : t, i]);
          });
          if (segs.length) segs[segs.length - 1][0] = segs[segs.length - 1][0].trimEnd();
          item.segs = segs;
        }
        lote.push(item);
      }
      return lote;
    },

    // resultados: [{id, partes: [texto|null]}]. null deja ese nodo como está.
    aplicar(resultados) {
      if (!activa) return 0;
      let n = 0;
      for (const r of resultados) {
        const u = unidades.get(r.id);
        if (!u || u.estado !== 'enviada') continue;
        if (u.el) {
          const t = r.partes && r.partes[0];
          if (t && u.el.isConnected && u.el.getAttribute('placeholder') === u.orig[0]) {
            u.el.setAttribute('placeholder', t);
            u.puestos = [t];
            n++;
          }
          u.estado = 'lista';
          continue;
        }
        u.puestos = u.puestos || u.orig.map(() => null);
        u.nodos.forEach((nodo, i) => {
          const t = r.partes ? r.partes[i] : null;
          if (t == null || !nodo.isConnected || nodo.data !== u.orig[i]) return;
          const { lead, trail } = partir(u.orig[i]);
          const nuevo = lead + t + trail;
          nodo.data = nuevo;
          u.puestos[i] = nuevo;
          n++;
        });
        u.estado = 'lista';
      }
      return n;
    },

    // Lo que Swift no pudo traducir: no se reintenta en esta página.
    fallo(ids) {
      for (const id of ids) { const u = unidades.get(id); if (u && u.estado === 'enviada') u.estado = 'fallo'; }
    },

    original() {
      activa = false;
      if (io) io.disconnect();
      if (mo) mo.disconnect();
      io = null; mo = null;
      raicesObservadas.clear();
      clearTimeout(reloj); reloj = null;
      clearTimeout(aviso); aviso = null;
      porRevisar.clear();
      pendientes.length = 0;
      let n = 0;
      for (const u of unidades.values()) {
        if (!u.puestos) continue;
        if (u.el) {
          if (u.el.getAttribute('placeholder') === u.puestos[0]) { u.el.setAttribute('placeholder', u.orig[0]); n++; }
          continue;
        }
        u.nodos.forEach((nodo, i) => {
          if (u.puestos[i] != null && nodo.data === u.puestos[i]) { nodo.data = u.orig[i]; n++; }
        });
      }
      unidades.clear();
      deNodo = new WeakMap();
      deObjetivo = new WeakMap();
      return n;
    },

    estado() {
      const c = { total: 0, nueva: 0, cola: 0, enviada: 0, lista: 0, fallo: 0, muerta: 0 };
      for (const u of unidades.values()) { c.total++; c[u.estado] = (c[u.estado] || 0) + 1; }
      return { activa, unidades: c };
    },
  };
})();
