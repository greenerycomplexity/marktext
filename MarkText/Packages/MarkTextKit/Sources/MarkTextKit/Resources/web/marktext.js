/* MarkText preview bridge. Exposes window.MarkText; talks to Swift through
   window.webkit.messageHandlers.marktext. No dependencies besides DOMPurify and highlight.js
   (loaded by template.html); KaTeX and mermaid are lazy-loaded. */
(function () {
  'use strict';

  // Resolve asset URLs now: document.currentScript is only valid while this script runs,
  // and <base> may change later.
  var SCRIPT_SRC = document.currentScript && document.currentScript.src;
  var ASSET_BASE = new URL('./', SCRIPT_SRC || 'mtres://app/').href;
  var ASSETS = {
    katex: ASSET_BASE + 'vendor/katex/katex.min.js',
    mermaid: ASSET_BASE + 'vendor/mermaid.min.js'
  };

  var root = document.documentElement;
  var content = null;
  var style = { theme: 'auto', font: 'system', size: 16, width: 'narrow' };
  var renderToken = 0;
  var lastActive = undefined;
  var mermaidTheme = null;
  var mermaidSeq = 0;

  var darkQuery = window.matchMedia('(prefers-color-scheme: dark)');
  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  /* ---------- messaging ---------- */
  function post(msg) {
    try {
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.marktext;
      if (h) { h.postMessage(msg); return; }
    } catch (e) { /* fall through */ }
    console.log('[MarkText]', JSON.stringify(msg));
  }

  /* ---------- lazy script loading ---------- */
  var loading = {};
  function loadScript(url) {
    if (!loading[url]) {
      loading[url] = new Promise(function (resolve, reject) {
        var s = document.createElement('script');
        s.src = url;
        s.onload = function () { resolve(); };
        s.onerror = function () { delete loading[url]; reject(new Error('Failed to load ' + url)); };
        document.head.appendChild(s);
      });
    }
    return loading[url];
  }

  /* ---------- sanitizing ---------- */
  var URI_RE = /^(?:(?:https?|mailto|tel|mtdoc):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i;
  var hooked = false;
  function installHooks() {
    if (hooked || !window.DOMPurify) return;
    hooked = true;
    DOMPurify.addHook('afterSanitizeAttributes', function (node) {
      if (node.nodeName === 'INPUT') {
        if ((node.getAttribute('type') || '').toLowerCase() !== 'checkbox') {
          node.parentNode && node.parentNode.removeChild(node);
        } else {
          node.setAttribute('disabled', '');
        }
      }
    });
  }

  // DOMPurify (SAFE_FOR_XML) drops any attribute whose value contains "-->", which is every
  // mermaid arrow. Mermaid sources are therefore lifted out before sanitizing and re-attached
  // as plain attribute values (never parsed as markup) to div.mermaid elements only.
  function liftMermaidSources(html) {
    if (html.indexOf('data-source') < 0) return { html: html, sources: [] };
    var t = document.createElement('template');
    t.innerHTML = html;
    var sources = [];
    t.content.querySelectorAll('div.mermaid[data-source]').forEach(function (el) {
      el.setAttribute('data-mm', String(sources.length));
      sources.push(el.getAttribute('data-source'));
      el.removeAttribute('data-source');
    });
    return { html: sources.length ? t.innerHTML : html, sources: sources };
  }

  function sanitize(html) {
    if (!window.DOMPurify) { return document.createRange().createContextualFragment(''); }
    installHooks();
    var lifted = liftMermaidSources(html);
    var frag = DOMPurify.sanitize(lifted.html, {
      RETURN_DOM_FRAGMENT: true,
      USE_PROFILES: { html: true },
      ADD_TAGS: ['input', 'details', 'summary'],
      ADD_ATTR: ['data-line', 'data-source', 'data-mm', 'checked', 'disabled', 'type', 'align'],
      FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form', 'meta', 'base', 'link', 'frame', 'frameset', 'button', 'select', 'textarea', 'dialog'],
      FORBID_ATTR: ['style', 'name', 'srcset', 'formaction'],
      ALLOW_DATA_ATTR: true,
      ALLOWED_URI_REGEXP: URI_RE,
      // Heading ids such as "title" or "body" would be dropped by DOM-clobbering protection;
      // `name` attributes are forbidden instead, and ids cannot shadow our closure-held state.
      SANITIZE_DOM: false
    });
    frag.querySelectorAll('div.mermaid[data-mm]').forEach(function (el) {
      var i = parseInt(el.getAttribute('data-mm'), 10);
      el.removeAttribute('data-mm');
      if (sources_ok(lifted.sources, i)) el.setAttribute('data-source', lifted.sources[i]);
    });
    return frag;
  }
  function sources_ok(a, i) { return i >= 0 && i < a.length; }

  /* ---------- anchors & scroll ---------- */
  function maxScroll() {
    return Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
  }

  function lineElements() {
    return content ? content.querySelectorAll('[data-line]') : [];
  }

  // Deepest block that straddles the top edge of the viewport, else the first one below it.
  function topAnchor() {
    var els = lineElements(), best = null, below = null;
    for (var i = 0; i < els.length; i++) {
      var r = els[i].getBoundingClientRect();
      if (r.top <= 4 && r.bottom > 4) best = { el: els[i], top: r.top };
      else if (r.top > 4) { below = { el: els[i], top: r.top }; break; }
    }
    var a = best || below;
    if (!a) return null;
    return { line: parseInt(a.el.getAttribute('data-line'), 10), offset: a.top };
  }

  function findByLine(line) {
    var els = lineElements(), pick = null;
    for (var i = 0; i < els.length; i++) {
      var l = parseInt(els[i].getAttribute('data-line'), 10);
      if (l === line) return els[i];
      if (l < line) pick = els[i]; else break;
    }
    return pick;
  }

  function restoreAnchor(a) {
    if (!a) return;
    var el = findByLine(a.line);
    if (!el) return;
    var top = el.getBoundingClientRect().top;
    var delta = top - a.offset;
    if (Math.abs(delta) > 0.5) window.scrollBy(0, delta);
  }

  function smoothBehavior() { return reduceMotion.matches ? 'auto' : 'smooth'; }

  function scrollToId(id, smooth) {
    var el = null;
    try { el = document.getElementById(id) || document.getElementById(decodeURIComponent(id)); } catch (e) { /* bad escape */ }
    if (!el) return false;
    el.scrollIntoView({ block: 'start', behavior: smooth ? smoothBehavior() : 'auto' });
    return true;
  }

  /* ---------- active heading / scroll reporting ---------- */
  function activeHeadingId() {
    var hs = content ? content.querySelectorAll('h1[id],h2[id],h3[id],h4[id],h5[id],h6[id]') : [];
    var id = '';
    for (var i = 0; i < hs.length; i++) {
      if (hs[i].getBoundingClientRect().top < 80) id = hs[i].id; else break;
    }
    return id;
  }

  function reportActive(force) {
    var id = activeHeadingId();
    if (force || id !== lastActive) {
      lastActive = id;
      post({ type: 'activeHeading', id: id });
    }
  }

  var scrollTimer = null, lastScrollPost = 0;
  function onScroll() {
    if (scrollTimer) return;
    var wait = Math.max(0, 80 - (Date.now() - lastScrollPost));
    scrollTimer = setTimeout(function () {
      scrollTimer = null;
      lastScrollPost = Date.now();
      var max = maxScroll();
      var a = topAnchor();
      post({ type: 'scroll', fraction: max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0, line: a ? a.line : null });
      reportActive(false);
    }, wait);
  }

  /* ---------- incremental DOM patching ---------- */
  var stats = { totalRenderMs: 0, lastRenderMs: 0, renders: 0, replaced: 0, kept: 0, katex: 0, katexCached: 0, mermaid: 0, mermaidCached: 0, hljs: 0 };
  var katexCache = Object.create(null), mermaidCache = Object.create(null);
  function cacheSet(cache, k, v) {
    if (Object.keys(cache).length > 300) { for (var old in cache) { delete cache[old]; break; } }
    cache[k] = v;
  }

  // Identity of a top-level block: its sanitized markup without line numbers (which shift when lines are inserted above).
  function keyOf(n) {
    return n.nodeType === 1 ? n.outerHTML.replace(/ data-line="\d+"/g, '') : '#' + n.nodeValue;
  }

  function lineEls(n) {
    if (n.nodeType !== 1) return [];
    var a = Array.prototype.slice.call(n.querySelectorAll('[data-line]'));
    if (n.hasAttribute('data-line')) a.unshift(n);
    return a;
  }

  function freshNodes() {
    return Array.prototype.filter.call(content.childNodes, function (n) { return n.__fresh; });
  }

  // Elements matching `sel` inside the nodes (including the nodes themselves).
  function scoped(nodes, sel) {
    var out = [];
    nodes.forEach(function (n) {
      if (n.nodeType !== 1) return;
      if (n.matches(sel)) out.push(n);
      Array.prototype.forEach.call(n.querySelectorAll(sel), function (e) { out.push(e); });
    });
    return out;
  }

  // Replace only the top-level blocks that differ (common prefix/suffix by content are kept untouched).
  function patch(frag) {
    var oldN = Array.prototype.slice.call(content.childNodes);
    var newN = Array.prototype.slice.call(frag.childNodes);
    var newKeys = newN.map(keyOf);
    var s = 0;
    var full = !!window.__mtFullRender;   // diagnostics: emulate the old replace-everything behaviour
    while (!full && s < oldN.length && s < newN.length && oldN[s].__k === newKeys[s]) s++;
    var eo = oldN.length, en = newN.length;
    while (!full && eo > s && en > s && oldN[eo - 1].__k === newKeys[en - 1]) { eo--; en--; }
    for (var i = s; i < eo; i++) content.removeChild(oldN[i]);
    var ref = eo < oldN.length ? oldN[eo] : null;
    for (i = s; i < en; i++) {
      var n = newN[i];
      n.__k = newKeys[i];
      n.__fresh = true;
      content.insertBefore(n, ref);
    }
    // Kept blocks after the edit may have moved to different source lines.
    for (i = eo; i < oldN.length; i++) {
      var a = lineEls(oldN[i]), b = lineEls(newN[en + (i - eo)]);
      if (a.length && a.length === b.length && a[0].getAttribute('data-line') !== b[0].getAttribute('data-line')) {
        for (var j = 0; j < a.length; j++) a[j].setAttribute('data-line', b[j].getAttribute('data-line'));
      }
    }
    stats.replaced += en - s;
    stats.kept += newN.length - (en - s);
  }

  /* ---------- post-processing ---------- */
  function wrapTables() {
    scoped(freshNodes(), 'table').forEach(function (t) {
      if (t.parentElement && t.parentElement.classList.contains('table-wrap')) return;
      var w = document.createElement('div');
      w.className = 'table-wrap';
      if (t.parentNode === content) { w.__k = t.__k; w.__fresh = true; }
      t.parentNode.insertBefore(w, t);
      w.appendChild(t);
    });
  }

  function copyText(text, btn) {
    function done(ok) {
      btn.textContent = ok ? 'Copied' : 'Failed';
      btn.classList.add('done');
      setTimeout(function () { btn.textContent = 'Copy'; btn.classList.remove('done'); }, 1200);
    }
    function legacy() {
      var ta = document.createElement('textarea');
      ta.value = text; ta.setAttribute('readonly', '');
      ta.style.cssText = 'position:fixed;top:0;left:-9999px;opacity:0';
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      document.body.removeChild(ta);
      done(ok);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { done(true); }, legacy);
    } else legacy();
  }

  function decoratePre() {
    scoped(freshNodes(), 'pre').forEach(function (pre) {
      if (pre.closest('.front-matter') || (pre.parentElement && pre.parentElement.classList.contains('code-block'))) return;
      var code = pre.querySelector('code');
      var lang = '';
      if (code) {
        var m = /(?:^|\s)language-([\w+#.\-]+)/.exec(code.className);
        if (m) lang = m[1];
      }
      // Wrapper (not the scrolling <pre>) carries the label and button so they stay put on h-scroll.
      var wrap = document.createElement('div');
      wrap.className = 'code-block';
      if (pre.parentNode === content) { wrap.__k = pre.__k; wrap.__fresh = true; }
      pre.parentNode.insertBefore(wrap, pre);
      wrap.appendChild(pre);
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'copy-btn';
      btn.textContent = 'Copy';
      btn.setAttribute('aria-label', 'Copy code');
      var chip = document.createElement('div');
      chip.className = 'code-chip';
      if (lang && lang !== 'text' && lang !== 'plaintext' && lang !== 'txt') {
        var l = document.createElement('span');
        l.className = 'lang';
        l.textContent = lang;
        chip.appendChild(l);
      }
      chip.appendChild(btn);
      wrap.appendChild(chip);
    });
  }

  // Hide the language label on blocks that scroll horizontally so it never covers code.
  function markOverflow(all) {
    (all ? Array.prototype.slice.call(content.querySelectorAll('.code-block')) : scoped(freshNodes(), '.code-block')).forEach(function (b) {
      var pre = b.firstElementChild;
      b.classList.toggle('overflowing', !!pre && pre.scrollWidth > pre.clientWidth + 1);
    });
  }

  function highlight(errors) {
    if (!window.hljs) return;
    hljs.configure({ ignoreUnescapedHTML: true });
    scoped(freshNodes(), 'pre > code').forEach(function (code) {
      var m = /(?:^|\s)language-([\w+#.\-]+)/.exec(code.className);
      if (!m || !hljs.getLanguage(m[1])) return;
      try { stats.hljs++; hljs.highlightElement(code); }
      catch (e) { errors.push({ kind: 'highlight', message: String(e && e.message || e), line: lineOf(code) }); }
    });
  }

  function lineOf(el) {
    var p = el.closest && el.closest('[data-line]');
    return p ? parseInt(p.getAttribute('data-line'), 10) : null;
  }

  function renderMath(errors) {
    var nodes = scoped(freshNodes(), '.math-inline, .math-display').filter(function (el) { return !el.__math; });
    if (!nodes.length) return Promise.resolve();
    return loadScript(ASSETS.katex).then(function () {
      nodes.forEach(function (el) {
        var tex = el.textContent;
        el.__math = true;
        var display = el.classList.contains('math-display');
        var opts = { displayMode: display, throwOnError: true, strict: 'ignore', trust: false, output: 'htmlAndMathml', maxExpand: 1000 };
        var ckey = (display ? 'D' : 'I') + tex;
        if (!window.__mtFullRender && katexCache[ckey] !== undefined) { el.innerHTML = katexCache[ckey]; stats.katexCached++; return; }
        try {
          stats.katex++;
          katex.render(tex, el, opts);
          cacheSet(katexCache, ckey, el.innerHTML);
        } catch (e) {
          errors.push({ kind: 'math', message: String(e && e.message || e), line: lineOf(el) });
          opts.throwOnError = false;
          try { katex.render(tex, el, opts); } catch (e2) { el.textContent = tex; }
          el.classList.add('math-error');
        }
      });
    }, function (e) {
      errors.push({ kind: 'math', message: String(e && e.message || e), line: null });
    });
  }

  function effectiveDark() {
    if (style.theme === 'dark') return true;
    if (style.theme === 'auto') return darkQuery.matches;
    return false;
  }

  function renderMermaid(errors, token, all) {
    var nodes = all ? Array.prototype.slice.call(content.querySelectorAll('.mermaid')) : scoped(freshNodes(), '.mermaid');
    if (!nodes.length) return Promise.resolve();
    return loadScript(ASSETS.mermaid).then(function () {
      var theme = effectiveDark() ? 'dark' : 'neutral';
      if (mermaidTheme !== theme) {
        mermaid.initialize({
          startOnLoad: false, securityLevel: 'strict', theme: theme,
          fontFamily: '-apple-system, "SF Pro Text", system-ui, sans-serif',
          flowchart: { htmlLabels: true }, deterministicIds: false
        });
        mermaidTheme = theme;
      }
      var chain = Promise.resolve();
      nodes.forEach(function (el) {
        chain = chain.then(function () {
          if (token !== renderToken) return;
          var src = el.getAttribute('data-source');
          if (src == null) src = el.textContent;
          var mkey = theme + '\u0000' + src;
          if (!window.__mtFullRender && mermaidCache[mkey] !== undefined) {
            if (el.__mk !== mkey) { el.innerHTML = mermaidCache[mkey]; el.__mk = mkey; stats.mermaidCached++; }
            el.classList.remove('mermaid-failed');
            return;
          }
          var id = 'mmd-' + (++mermaidSeq);
          stats.mermaid++;
          return mermaid.render(id, src).then(function (res) {
            if (token !== renderToken) return;
            cacheSet(mermaidCache, mkey, res.svg);
            el.__mk = mkey;
            el.innerHTML = res.svg;
            el.classList.remove('mermaid-failed');
          }, function (e) {
            var stray = document.getElementById('d' + id) || document.getElementById(id);
            if (stray && stray.parentNode) stray.parentNode.removeChild(stray);
            errors.push({ kind: 'mermaid', message: String(e && e.message || e).split('\n')[0], line: lineOf(el) });
            el.classList.add('mermaid-failed');
            el.textContent = src;
          });
        });
      });
      return chain;
    }, function (e) {
      errors.push({ kind: 'mermaid', message: String(e && e.message || e), line: null });
    });
  }

  // A failed image becomes its alt text (quiet, tertiary) instead of a broken-image glyph.
  function markBroken(img) {
    if (!img.parentNode) return;
    var alt = img.getAttribute('alt') || '';
    if (!alt) { img.remove(); return; }
    var span = document.createElement('span');
    span.className = 'img-missing';
    span.textContent = alt;
    img.replaceWith(span);
  }

  function imagesSettled() {
    var imgNodes = scoped(freshNodes(), 'img');
    Array.prototype.forEach.call(imgNodes, function (img) {
      if (img.complete && img.naturalWidth === 0) markBroken(img);
      else img.addEventListener('error', function () { markBroken(img); }, { once: true });
    });
    var imgs = imgNodes.filter(function (i) { return !i.complete; });
    if (!imgs.length) return Promise.resolve();
    var all = Promise.all(imgs.map(function (img) {
      return new Promise(function (res) { img.addEventListener('load', res, { once: true }); img.addEventListener('error', res, { once: true }); });
    }));
    return Promise.race([all, new Promise(function (res) { setTimeout(res, 1500); })]);
  }

  function fontsReady() {
    return (document.fonts && document.fonts.ready) ? document.fonts.ready.catch(function () {}) : Promise.resolve();
  }

  /* ---------- <base> ---------- */
  function setBase(href) {
    var b = document.head.querySelector('base');
    if (!href) return;
    if (!b) { b = document.createElement('base'); document.head.insertBefore(b, document.head.firstChild); }
    if (b.getAttribute('href') !== href) b.setAttribute('href', href);
  }

  /* ---------- public API ---------- */
  function render(html, opts) {
    opts = opts || {};
    var token = ++renderToken;
    var errors = [];
    var anchor = opts.preserveScroll ? topAnchor() : null;
    var fallbackY = window.scrollY;

    if (opts.baseHref) setBase(opts.baseHref);

    stats.renders++;
    var t0 = performance.now();
    var frag = sanitize(String(html == null ? '' : html));
    patch(frag);
    wrapTables();
    decoratePre();
    highlight(errors);

    if (opts.preserveScroll) {
      if (anchor) restoreAnchor(anchor); else window.scrollTo(0, Math.min(fallbackY, maxScroll()));
    } else {
      window.scrollTo(0, 0);
    }

    // Prefetch hint: start loading heavy libs even before we scan (cheap, memoized).
    if (opts.hasMath) loadScript(ASSETS.katex).catch(function () {});
    if (opts.hasMermaid) loadScript(ASSETS.mermaid).catch(function () {});

    return renderMath(errors)
      .then(function () { return renderMermaid(errors, token); })
      .then(function () { return Promise.all([imagesSettled(), fontsReady()]); })
      .then(function () {
        if (token !== renderToken) return { errors: errors, superseded: true };
        markOverflow();
        Array.prototype.forEach.call(content.childNodes, function (n) { n.__fresh = false; });
        if (opts.preserveScroll && anchor) restoreAnchor(anchor);
        reportActive(true);
        stats.lastRenderMs = performance.now() - t0; stats.totalRenderMs += stats.lastRenderMs;
        post({ type: 'rendered', errors: errors });
        return { errors: errors };
      });
  }

  function setStyle(s) {
    s = s || {};
    var prevDark = effectiveDark();
    if (s.theme) style.theme = s.theme;
    if (s.font) style.font = s.font;
    if (s.size) style.size = s.size;
    if (s.width) style.width = s.width;
    root.setAttribute('data-theme', style.theme);
    root.setAttribute('data-font', style.font);
    root.setAttribute('data-width', style.width);
    root.style.setProperty('--size', style.size + 'px');
    if (effectiveDark() !== prevDark) rerenderMermaid();
  }

  var rerenderToken = 0;
  function rerenderMermaid() {
    if (!content || !content.querySelector('.mermaid')) return;
    var t = ++rerenderToken;
    var errors = [];
    var anchor = topAnchor();
    // Keep the renderToken so an in-flight full render still wins.
    renderMermaid(errors, renderToken, true).then(function () {
      if (t === rerenderToken) restoreAnchor(anchor);
    });
  }

  function scrollToHeading(id) { return scrollToId(id, true); }

  function scrollToLine(n) {
    var el = findByLine(Number(n));
    if (!el) return false;
    var top = el.getBoundingClientRect().top + window.scrollY - 72;
    window.scrollTo(0, Math.max(0, Math.min(top, maxScroll())));
    return true;
  }

  function scrollToFraction(f) {
    f = Math.min(1, Math.max(0, Number(f) || 0));
    window.scrollTo(0, f * maxScroll());
  }

  window.MarkText = {
    render: render,
    setStyle: setStyle,
    scrollToHeading: scrollToHeading,
    scrollToLine: scrollToLine,
    scrollToFraction: scrollToFraction,
    stats: function () { return JSON.parse(JSON.stringify(stats)); }
  };

  /* ---------- events ---------- */
  function onClick(ev) {
    var t = ev.target;
    var btn = t.closest && t.closest('.copy-btn');
    if (btn) {
      ev.preventDefault();
      var blk = btn.closest('.code-block');
      var code = blk && (blk.querySelector('code') || blk.querySelector('pre'));
      copyText(code ? code.textContent : '', btn);
      return;
    }
    var a = t.closest && t.closest('a[href]');
    if (!a) return;
    ev.preventDefault();
    var raw = a.getAttribute('href') || '';
    if (raw.charAt(0) === '#') {
      var id = raw.slice(1);
      if (!id) { window.scrollTo({ top: 0, behavior: smoothBehavior() }); return; }
      scrollToId(id, true);
      return;
    }
    post({ type: 'link', href: a.href });
  }

  document.addEventListener('click', onClick, true);
  document.addEventListener('auxclick', function (ev) {
    if (ev.target.closest && ev.target.closest('a[href]')) ev.preventDefault();
  }, true);
  window.addEventListener('resize', function () { if (content) markOverflow(true); });
  window.addEventListener('scroll', onScroll, { passive: true });
  var onSchemeChange = function () { if (style.theme === 'auto') rerenderMermaid(); };
  if (darkQuery.addEventListener) darkQuery.addEventListener('change', onSchemeChange);

  document.addEventListener('DOMContentLoaded', function () {
    content = document.getElementById('mt-root');
    setStyle({});
    setTimeout(function () { post({ type: 'ready' }); }, 0);
  });
})();
