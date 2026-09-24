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

  window.__kurth = {
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
