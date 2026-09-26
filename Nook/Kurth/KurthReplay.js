// Licensed under GPL-3.0. See LICENSE.
//
// KurthReplay.js — Nook (rama kurth)
//
// El localizador del replay exacto de workflows (KurthWorkflowsReplay.swift). Kurth, 26 sep: "los
// programados replican lo que el usuario hizo, pero debe ser exacto o casi exacto por si cambia
// ligeramente el diseño". Corre en el mismo mundo aislado que el copiloto ("KurthCopilot") y se
// instala después de KurthCopilot.js: lo que encuentra lo devuelve como referencia @eN del copiloto
// (window.__kurth.refDe), y las acciones (click, type_text, fill_form…) las hace el copiloto, con sus
// guardias. Aquí no se toca la página: solo se busca.
//
// Cómo busca un paso grabado ({tipo, rol, nombre, selector, href, pos, orden}), en este orden, y
// dice con qué nivel lo encontró:
//   1 exacto      — mismo rol y el mismo nombre, carácter por carácter.
//   2 normalizado — el nombre sin acentos, mayúsculas, espacios ni puntuación; rol del mismo grupo
//                   (un <a> que ahora es <button> sigue siendo "algo que se toca").
//   3 etiqueta    — el nombre coincide con aria-label, <label>, placeholder, title, alt o name.
//   4 selector    — el selector de respaldo de la grabación. Un selector de estructura (nth-of-type)
//                   solo vale si el nombre se parece algo: con el orden movido apuntaría a otro.
//   5 difuso      — el nombre más parecido (bigramas + palabras) si pasa el umbral y le saca ventaja
//                   al segundo; si dos se parecen igual, no se adivina.
//   6 posición    — solo si el paso no tenía nombre (íconos): el del mismo rol más cerca de donde estaba.
// Varios empatados en un nivel: el que también cumple el selector, luego el mismo número de orden
// entre iguales que en la grabación, luego el más cercano a la posición grabada.
//
// Los nombres se calculan con las mismas funciones que KurthGrabadora.js (copiadas tal cual,
// incluido el recorte a 80 caracteres): si no, "exacto" nunca coincidiría.
//
(() => {
  'use strict';
  if (window.__kurthReplay) return;

  // ── Lo mismo que KurthGrabadora.js ──────────────────────────────────────────────────────
  const limpio = (s, max = 80) => {
    const t = String(s || '').replace(/\s+/g, ' ').trim();
    return t.length > max ? t.slice(0, max - 1) + '…' : t;
  };

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

  const textoDeIds = (el, ids) => ids.split(/\s+/).map((id) => el.ownerDocument.getElementById(id)).filter(Boolean)
    .map((n) => n.innerText || n.textContent || '').join(' ');

  const etiquetaDe = (el) => {
    const aria = el.getAttribute('aria-label');
    if (aria && aria.trim()) return limpio(aria);
    const por = el.getAttribute('aria-labelledby');
    if (por) { const t = limpio(textoDeIds(el, por)); if (t) return t; }
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

  const nombreDe = (el) => {
    const aria = el.getAttribute('aria-label');
    if (aria && aria.trim()) return limpio(aria);
    const por = el.getAttribute('aria-labelledby');
    if (por) { const t = limpio(textoDeIds(el, por)); if (t) return t; }
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

  const escapar = (s) => (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/[^\w-]/g, '\\$&');
  const comillas = (s) => '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
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

  const INTERACTIVO = 'a[href],button,input,select,textarea,summary,label,[role=button],[role=link],[role=tab],' +
    '[role=menuitem],[role=menuitemcheckbox],[role=menuitemradio],[role=option],[role=checkbox],[role=radio],' +
    '[role=switch],[role=treeitem],[role=gridcell],[role=row],[onclick],[contenteditable=""],[contenteditable=true]';

  // ── Comparar nombres ─────────────────────────────────────────────────────────────────────

  /** Sin acentos, mayúsculas, puntuación ni espacios de más: "Descargar  Informe…" → "descargar informe". */
  const plano = (s) => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^\p{L}\p{N}]+/gu, ' ').trim();

  const bigramas = (s) => {
    const t = ' ' + s + ' ';
    const m = new Map();
    for (let i = 0; i < t.length - 1; i++) { const b = t.slice(i, i + 2); m.set(b, (m.get(b) || 0) + 1); }
    return m;
  };

  /** 0…1. Bigramas de letras (aguanta cambios de una letra) y palabras compartidas (aguanta el orden). */
  const similitud = (a, b) => {
    if (!a || !b) return 0;
    if (a === b) return 1;
    const A = bigramas(a), B = bigramas(b);
    let comun = 0, na = 0, nb = 0;
    for (const v of A.values()) na += v;
    for (const v of B.values()) nb += v;
    for (const [k, v] of A) comun += Math.min(v, B.get(k) || 0);
    const dice = (2 * comun) / (na + nb);
    const pa = new Set(a.split(' ')), pb = new Set(b.split(' '));
    let iguales = 0;
    for (const w of pa) if (pb.has(w)) iguales++;
    const palabras = (2 * iguales) / (pa.size + pb.size);
    let s = 0.6 * dice + 0.4 * palabras;
    // "Guardar" dentro de "Guardar cambios": parecido, pero no tanto como para ganarle a uno igual.
    if (a.includes(b) || b.includes(a)) s = Math.max(s, 0.6);
    return s;
  };

  const UMBRAL = 0.5;
  /** Lo que el mejor difuso le tiene que sacar al segundo; si no, es una moneda al aire. */
  const VENTAJA = 0.08;

  // Grupos de rol: dentro de un grupo, el cambio de etiqueta HTML no importa.
  const GRUPO = {
    button: 'tocar', link: 'tocar', generic: 'tocar', menuitem: 'tocar', menuitemcheckbox: 'tocar',
    menuitemradio: 'tocar', tab: 'tocar', option: 'tocar', treeitem: 'tocar', row: 'tocar', gridcell: 'tocar',
    img: 'tocar', heading: 'tocar', label: 'tocar',
    textbox: 'campo', searchbox: 'campo', spinbutton: 'campo',
    combobox: 'lista', listbox: 'lista',
    checkbox: 'casilla', radio: 'casilla', switch: 'casilla',
    file: 'archivo', form: 'form', slider: 'campo',
  };
  const grupoDe = (rol) => GRUPO[rol] || 'tocar';

  // ── Dónde buscar ────────────────────────────────────────────────────────────────────────

  const estiloDe = (el) => ((el.ownerDocument && el.ownerDocument.defaultView) || window).getComputedStyle(el);

  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    const cs = estiloDe(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) > 0.01;
  };

  /** Una casilla o un campo de archivo escondidos tras su etiqueta cuentan si la etiqueta se ve. */
  const alcanzable = (el) => {
    if (visible(el)) return true;
    if (el.tagName === 'INPUT' && /^(checkbox|radio|file)$/i.test(el.type)) {
      return !!(el.labels && Array.from(el.labels).some(visible)) || el.type === 'file';
    }
    return false;
  };

  function documentoDe(iframe) {
    try { const d = iframe.contentDocument; return d && d.body ? d : null; } catch (e) { return null; }
  }

  /** El documento, sus shadow roots abiertos y los iframes del mismo origen. */
  function raices() {
    const salida = [];
    const pendientes = [document];
    while (pendientes.length && salida.length < 200) {
      const r = pendientes.shift();
      salida.push(r);
      for (const h of r.querySelectorAll('*')) {
        if (h.shadowRoot) pendientes.push(h.shadowRoot);
        if (h.tagName === 'IFRAME' || h.tagName === 'FRAME') { const d = documentoDe(h); if (d) pendientes.push(d); }
      }
    }
    return salida;
  }

  /** Elementos que podrían ser el del paso. Los que solo delatan su clic por el cursor de mano se
   *  buscan si la grabación era de uno de esos (rol genérico, encabezado o imagen): recorrer el
   *  estilo de toda la página cuesta. */
  function candidatos(d, roots) {
    const vistos = new Set();
    const lista = [];
    const agregar = (el) => { if (!vistos.has(el)) { vistos.add(el); lista.push(el); } };
    const deForm = d.tipo === 'enviar';
    for (const r of roots) {
      if (deForm) { for (const f of r.querySelectorAll('form')) agregar(f); continue; }
      for (const el of r.querySelectorAll(INTERACTIVO)) agregar(el);
    }
    if (!deForm && ['generic', 'heading', 'img'].includes(d.rol)) {
      let revisados = 0;
      for (const r of roots) {
        for (const el of r.querySelectorAll('div,span,li,p,td,img,svg,h1,h2,h3,h4,h5,h6,section,article,figure')) {
          if (++revisados > 6000) break;
          if (vistos.has(el) || (el.closest && el.closest(INTERACTIVO))) continue;
          if (estiloDe(el).cursor === 'pointer') agregar(el);
        }
      }
    }
    return lista.filter(alcanzable);
  }

  /** El nombre como lo habría grabado la grabadora para este tipo de paso. */
  const nombreSegun = (d, el) => {
    if (d.tipo === 'clic') return nombreDe(el);
    if (d.tipo === 'enviar') return limpio(el.getAttribute('aria-label') || el.getAttribute('name') || '');
    if (d.tipo === 'marcar') return etiquetaDe(el) || limpio(el.value);
    return etiquetaDe(el);
  };

  /** Otros textos con que la página nombra un elemento, para el nivel "etiqueta". */
  const otrasEtiquetas = (el) => {
    const v = [];
    for (const a of ['aria-label', 'placeholder', 'title', 'alt', 'name', 'value', 'data-testid']) {
      const x = el.getAttribute(a);
      if (x && x.trim()) v.push(x);
    }
    if (el.labels) for (const l of el.labels) v.push(l.innerText || l.textContent || '');
    const por = el.getAttribute('aria-labelledby');
    if (por) v.push(textoDeIds(el, por));
    return v.map(plano).filter(Boolean);
  };

  /** Centro del elemento como fracción del documento (así lo guarda la grabadora). */
  const posicionDe = (el) => {
    const r = el.getBoundingClientRect();
    const doc = el.ownerDocument.documentElement;
    const w = Math.max(doc.scrollWidth, 1), h = Math.max(doc.scrollHeight, 1);
    const win = el.ownerDocument.defaultView || window;
    return [(r.left + r.width / 2 + win.scrollX) / w, (r.top + r.height / 2 + win.scrollY) / h];
  };

  const distancia = (el, pos) => {
    if (!pos || pos.length !== 2) return 0;
    const p = posicionDe(el);
    return Math.hypot(p[0] - pos[0], p[1] - pos[1]);
  };

  /** Un selector que dice qué es el elemento (id, data-testid, name…) y no solo dónde estaba. */
  const selectorEstable = (s) => !!s && !/nth-of-type|>/.test(s);

  /** Lo que cumple el selector de la grabación, en cualquiera de las raíces. */
  function porSelector(sel, roots) {
    if (!sel) return null;
    const hallados = [];
    for (const r of roots) {
      try { for (const e of r.querySelectorAll(sel)) hallados.push(e); } catch (_) { return null; }
      if (hallados.length > 1) return null;
    }
    return hallados.length === 1 ? hallados[0] : null;
  }

  // ── Localizar ─────────────────────────────────────────────────────────────────────────────

  function localizar(d) {
    const roots = raices();
    const lista = candidatos(d, roots);
    const grupo = grupoDe(d.rol);
    const buscado = d.nombre || '';
    const buscadoPlano = plano(buscado);
    const delSelector = porSelector(d.selector, roots);

    const info = lista.map((el) => {
      const rol = rolDe(el);
      const nombre = nombreSegun(d, el);
      return { el, rol, nombre, plano: plano(nombre), compatible: grupoDe(rol) === grupo };
    });

    // Empate: el que también cumple el selector; si no, el mismo número de orden entre iguales (la
    // grabadora lo cuenta igual: mismo rol y mismo nombre, en orden del documento); si no, el más
    // cercano a donde estaba; si no hay más datos, el primero.
    const elegir = (grupoIguales, usarOrden) => {
      if (grupoIguales.length === 1) return grupoIguales[0];
      const conSelector = grupoIguales.find((c) => c.el === delSelector);
      if (conSelector) return conSelector;
      if (usarOrden && Number.isInteger(d.orden) && d.orden >= 0 && d.orden < grupoIguales.length) return grupoIguales[d.orden];
      if (d.pos) return grupoIguales.slice().sort((a, b) => distancia(a.el, d.pos) - distancia(b.el, d.pos))[0];
      return grupoIguales[0];
    };

    const resultado = (c, nivel, sim) => ({
      ref: window.__kurth.refDe(c.el),
      nivel,
      nombre: c.nombre,
      rol: c.rol,
      similitud: Math.round((sim === undefined ? 1 : sim) * 100) / 100,
      selector: selectorDe(c.el),
      candidatos: info.length,
      etiqueta: c.el.tagName.toLowerCase(),
    });

    if (buscado) {
      const exactos = info.filter((c) => c.rol === d.rol && c.nombre === buscado);
      if (exactos.length) return resultado(elegir(exactos, true), 'exacto');

      const normales = info.filter((c) => c.compatible && c.plano && c.plano === buscadoPlano);
      if (normales.length) return resultado(elegir(normales, true), 'normalizado');

      const etiquetados = info.filter((c) => c.compatible && otrasEtiquetas(c.el).includes(buscadoPlano));
      if (etiquetados.length) return resultado(elegir(etiquetados, false), 'etiqueta');
    }

    if (delSelector) {
      const c = info.find((x) => x.el === delSelector) ||
        { el: delSelector, rol: rolDe(delSelector), nombre: nombreSegun(d, delSelector), plano: plano(nombreSegun(d, delSelector)) };
      const compatible = grupoDe(c.rol) === grupo;
      const sim = buscadoPlano && c.plano ? similitud(c.plano, buscadoPlano) : (buscadoPlano ? 0 : 1);
      // Un selector de estructura con el orden movido apunta a otro elemento: tiene que parecerse.
      if (compatible && (selectorEstable(d.selector) || sim >= 0.35)) return resultado(c, 'selector', sim);
    }

    if (buscado) {
      const puntuados = info.filter((c) => c.compatible && c.plano)
        .map((c) => ({ c, s: Math.max(similitud(c.plano, buscadoPlano), ...otrasEtiquetas(c.el).map((x) => similitud(x, buscadoPlano)), 0) }))
        .sort((a, b) => b.s - a.s);
      const mejor = puntuados[0];
      if (mejor && mejor.s >= UMBRAL) {
        const segundo = puntuados.find((p) => p.c.plano !== mejor.c.plano);
        if (!segundo || mejor.s - segundo.s >= VENTAJA) return resultado(mejor.c, 'difuso', mejor.s);
        const r = { ambiguo: true, opciones: [mejor, segundo].map((p) => ({ nombre: p.c.nombre, similitud: Math.round(p.s * 100) / 100 })) };
        return Object.assign({ ref: null, nivel: null, candidatos: info.length }, r);
      }
    } else if (d.pos) {
      // Un ícono sin nombre: el del mismo rol más cerca de donde estaba, si está cerca de verdad.
      const mismos = info.filter((c) => c.rol === d.rol && !c.nombre);
      const cerca = mismos.map((c) => ({ c, dist: distancia(c.el, d.pos) })).sort((a, b) => a.dist - b.dist)[0];
      if (cerca && cerca.dist < 0.05) return resultado(cerca.c, 'posicion', 1 - cerca.dist);
    }
    return { ref: null, nivel: null, candidatos: info.length };
  }

  // ── Página quieta ─────────────────────────────────────────────────────────────────────────

  let mutaciones = 0;
  try {
    new MutationObserver((l) => { mutaciones += l.length; })
      .observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
  } catch (_) { /* sin documento todavía: quieto() solo contará recursos */ }

  window.__kurthReplay = Object.freeze({
    localizar,

    /** Para esperar a que la página deje de moverse: Swift compara dos lecturas seguidas. */
    quieto() {
      return {
        mutaciones,
        recursos: performance.getEntriesByType ? performance.getEntriesByType('resource').length : 0,
        listo: document.readyState,
        url: location.href,
      };
    },

    /** El foco en un campo antes de una tecla (Enter en un buscador). */
    enfocar(ref) {
      const el = window.__kurth.elemento(ref);
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      if (typeof el.focus === 'function') el.focus();
      return true;
    },

    /** Un formulario enviado sin clic ni Enter. requestSubmit dispara la validación y el submit. */
    enviar(ref) {
      const f = window.__kurth.elemento(ref);
      const form = f.tagName === 'FORM' ? f : f.form;
      if (!form) throw new Error('no es un formulario');
      if (typeof form.requestSubmit === 'function') form.requestSubmit(); else form.submit();
      return true;
    },

    /** Pantallas completas hacia abajo (positivo) o arriba, para lo que carga al llegar al final. */
    desplazar(pantallas) {
      window.scrollBy({ top: pantallas * innerHeight, behavior: 'instant' });
      return Math.round(scrollY);
    },

    // Para la prueba (kurth/checks/replay.sh).
    pruebas: Object.freeze({ similitud: (a, b) => similitud(plano(a), plano(b)), plano }),
  });
})();
