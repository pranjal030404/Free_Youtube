/// D-pad (remote control) navigation for YouTube / YouTube Music on TV.
///
/// The WebView keeps Android input focus and this script does what native TV
/// apps do: arrow keys move a visible focus highlight to the nearest
/// interactive element in that direction, OK activates it, and the page
/// scrolls when nothing else is in that direction.
const String tvNavigationScript = r'''
(function () {
  if (window.__ytmbTvNav) return;
  // YouTube's own TV interface handles the remote itself.
  if (location.hostname.indexOf('music.') !== 0 &&
      (location.pathname === '/tv' || location.pathname.indexOf('/tv/') === 0)) return;
  window.__ytmbTvNav = true;

  var SEL = [
    'a[href]', 'button', 'input', 'select', 'textarea', 'summary',
    '[tabindex]:not([tabindex="-1"])', '[role="button"]', '[role="link"]',
    '[role="tab"]', '[role="menuitem"]', '[role="option"]',
    '[role="checkbox"]', '[role="switch"]', '[role="slider"]',
    '[role="search"]', '[aria-label*="Search"]',
    // YouTube/Music draw many buttons and the search entry point with divs,
    // so a class-based catch-all is needed in addition to ARIA roles.
    '[class*="button"]', '[class*="entry-point"]',
    '[class*="search-box"]', '[class*="search-bar"]',
    'ytmusic-search-box', 'yt-searchbox',
    'ytmusic-responsive-list-item-renderer', 'ytmusic-two-row-item-renderer',
    'ytmusic-chip-cloud-chip-renderer', 'yt-chip-cloud-chip-renderer',
    'ytmusic-play-button-renderer', 'ytd-thumbnail', 'yt-lockup-view-model'
  ].join(',');

  var style = document.createElement('style');
  style.textContent =
    '[data-ytmb-focus]{outline:4px solid #fff !important;' +
    'outline-offset:2px !important;border-radius:6px;' +
    'box-shadow:0 0 0 8px rgba(255,0,0,.85) !important;' +
    'position:relative;z-index:2147483000;}';
  (document.head || document.documentElement).appendChild(style);

  var current = null;

  function deepActive() {
    var el = document.activeElement;
    while (el && el.shadowRoot && el.shadowRoot.activeElement) {
      el = el.shadowRoot.activeElement;
    }
    return el;
  }

  function isTextField(el) {
    if (!el) return false;
    if (el.tagName === 'TEXTAREA' || el.isContentEditable) return true;
    if (el.tagName !== 'INPUT') return false;
    var t = (el.type || 'text').toLowerCase();
    return ['button', 'checkbox', 'radio', 'submit', 'reset', 'range',
      'image', 'file', 'color'].indexOf(t) < 0;
  }

  function parentOf(el) {
    if (el.parentElement) return el.parentElement;
    var root = el.getRootNode && el.getRootNode();
    return root && root.host ? root.host : null;
  }

  // Shadow roots rarely change within a second, and walking the whole DOM to
  // find them is expensive. The selector query itself is cheap, so cache the
  // roots and the resulting element list briefly. On a 2 GB TV this keeps
  // repeated D-pad presses smooth.
  var hostCache = null, hostCacheAt = 0;
  function shadowRoots() {
    var now = Date.now();
    if (hostCache && now - hostCacheAt < 1500) {
      hostCache = hostCache.filter(function (r) {
        return r.host && r.host.isConnected;
      });
      return hostCache;
    }
    var roots = [];
    (function walk(root) {
      var all;
      try { all = root.querySelectorAll('*'); } catch (e) { return; }
      for (var i = 0; i < all.length; i++) {
        var sr = all[i].shadowRoot;
        if (sr) { roots.push(sr); walk(sr); }
      }
    })(document);
    hostCache = roots; hostCacheAt = now;
    return roots;
  }

  var elemCache = null, elemCacheAt = 0;
  function allTargets() {
    var now = Date.now();
    if (elemCache && now - elemCacheAt < 800) return elemCache;
    var roots = [document].concat(shadowRoots());
    var seen = typeof Set !== 'undefined' ? new Set() : null;
    var out = [];
    for (var r = 0; r < roots.length; r++) {
      try {
        var found = roots[r].querySelectorAll(SEL);
        for (var j = 0; j < found.length; j++) {
          var el = found[j];
          if (seen) {
            if (seen.has(el)) continue;
            seen.add(el);
          }
          out.push(el);
        }
      } catch (e) {}
    }
    elemCache = out; elemCacheAt = now;
    return out;
  }

  function candidates() {
    var all = allTargets();
    var vh = window.innerHeight, vw = window.innerWidth;
    var res = [];
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (!el.isConnected) continue;
      if (el.disabled || el.getAttribute('aria-hidden') === 'true') continue;
      var r = el.getBoundingClientRect();
      if (r.width < 8 || r.height < 8) continue;
      if (r.bottom < -vh || r.top > vh * 2 || r.right < 0 || r.left > vw) {
        continue;
      }
      var cs = getComputedStyle(el);
      if (cs.visibility === 'hidden' || cs.display === 'none' ||
          cs.pointerEvents === 'none') continue;
      res.push({ el: el, r: r });
    }
    // Prefer leaf targets: drop a container when it holds another target.
    // Marking every candidate ancestor is O(n * depth), unlike the previous
    // O(n^2) contains() scan which made large YouTube pages lag.
    var set = typeof Set !== 'undefined' ? new Set() : null;
    var containers = typeof Set !== 'undefined' ? new Set() : null;
    if (set && containers) {
      for (var k = 0; k < res.length; k++) set.add(res[k].el);
      for (var m = 0; m < res.length; m++) {
        var p = parentOf(res[m].el);
        while (p) {
          if (set.has(p)) containers.add(p);
          p = parentOf(p);
        }
      }
      return res.filter(function (a) { return !containers.has(a.el); });
    }
    return res;
  }

  function setFocus(el) {
    if (current && current !== el) current.removeAttribute('data-ytmb-focus');
    current = el;
    if (!el) return;
    el.setAttribute('data-ytmb-focus', '');
    if (el.tabIndex < 0 && !el.hasAttribute('tabindex')) {
      el.setAttribute('tabindex', '-1');
    }
    try { el.focus({ preventScroll: true }); } catch (e) {}
    try {
      el.scrollIntoView({ block: 'center', inline: 'center' });
    } catch (e) {}
  }

  function currentRect() {
    var el = current && current.isConnected ? current : null;
    if (!el) {
      var a = deepActive();
      if (a && a !== document.body && a.getBoundingClientRect) el = a;
    }
    return el ? el.getBoundingClientRect() : null;
  }

  function pick(dir) {
    var from = currentRect();
    var list = candidates();
    if (!list.length) return null;
    if (!from) {
      // Nothing focused yet: start near the top-left of the viewport.
      var best0 = null, s0 = Infinity;
      list.forEach(function (c) {
        if (c.r.bottom < 0 || c.r.top > window.innerHeight) return;
        var s = c.r.top * 2 + c.r.left;
        if (s < s0) { s0 = s; best0 = c; }
      });
      return best0 ? best0.el : list[0].el;
    }
    var cx = from.left + from.width / 2, cy = from.top + from.height / 2;
    var best = null, bestScore = Infinity;
    list.forEach(function (c) {
      if (c.el === current) return;
      var r = c.r;
      var rx = r.left + r.width / 2, ry = r.top + r.height / 2;
      var primary, ortho, overlap;
      if (dir === 'ArrowRight') {
        if (rx <= cx + 1 && r.left < from.right - 1) return;
        primary = Math.max(0, r.left - from.right);
        ortho = Math.abs(ry - cy);
        overlap = Math.min(r.bottom, from.bottom) - Math.max(r.top, from.top);
      } else if (dir === 'ArrowLeft') {
        if (rx >= cx - 1 && r.right > from.left + 1) return;
        primary = Math.max(0, from.left - r.right);
        ortho = Math.abs(ry - cy);
        overlap = Math.min(r.bottom, from.bottom) - Math.max(r.top, from.top);
      } else if (dir === 'ArrowDown') {
        if (ry <= cy + 1 && r.top < from.bottom - 1) return;
        primary = Math.max(0, r.top - from.bottom);
        ortho = Math.abs(rx - cx);
        overlap = Math.min(r.right, from.right) - Math.max(r.left, from.left);
      } else {
        if (ry >= cy - 1 && r.bottom > from.top + 1) return;
        primary = Math.max(0, from.top - r.bottom);
        ortho = Math.abs(rx - cx);
        overlap = Math.min(r.right, from.right) - Math.max(r.left, from.left);
      }
      // Same row/column neighbours always win over diagonal ones.
      var score = overlap > 0 ? primary : 10000 + primary + ortho * 2;
      if (score < bestScore) { bestScore = score; best = c; }
    });
    return best ? best.el : null;
  }

  function scrollTarget(el) {
    var node = el;
    while (node && node !== document.body && node !== document.documentElement) {
      var cs = getComputedStyle(node);
      var oy = cs.overflowY || cs.overflow;
      if ((oy === 'auto' || oy === 'scroll' || oy === 'overlay') &&
          node.scrollHeight > node.clientHeight + 4) {
        return node;
      }
      node = parentOf(node);
    }
    return document.scrollingElement || document.documentElement;
  }

  function scrollBy(dir) {
    var target = scrollTarget(current || deepActive());
    var amount = (target.clientHeight || window.innerHeight) * 0.6;
    target.scrollTop += dir === 'ArrowDown' ? amount : -amount;
  }

  function centerOf(el) {
    var r = el.getBoundingClientRect();
    var cx = r.left + r.width / 2;
    var cy = r.top + r.height / 2;
    // Use the visual viewport so the native tap stays accurate if the page is
    // pinched/zoomed. getBoundingClientRect is in layout-viewport pixels.
    var vv = window.visualViewport;
    if (vv && vv.width && vv.height) {
      cx = (cx - vv.offsetLeft) / vv.width;
      cy = (cy - vv.offsetTop) / vv.height;
    } else {
      cx = cx / window.innerWidth;
      cy = cy / window.innerHeight;
    }
    return cx + ',' + cy;
  }

  function isStandardTarget(el) {
    var t = el.tagName;
    return t === 'A' || t === 'BUTTON' || t === 'INPUT' || t === 'SELECT' ||
           t === 'TEXTAREA' || t === 'SUMMARY';
  }

  // Returns '' for a normal activation, 'text' when the keyboard should open,
  // or 'tap:x,y' when the native side should send a real touch. YouTube and
  // Music use custom elements/divs for several buttons (notably the home
  // search bar); a synthetic .click() is ignored by those, so a native tap is
  // the reliable path there.
  function activate(el) {
    if (!el) return '';
    if (isTextField(el)) {
      try { el.focus(); } catch (e) {}
      return 'text';
    }
    if (isStandardTarget(el)) {
      try { el.click(); } catch (e) {}
      return '';
    }
    var r = el.getBoundingClientRect();
    if (r.width > 0 && r.height > 0) return 'tap:' + centerOf(el);
    try { el.click(); } catch (e) {}
    return '';
  }

  function submitField(el) {
    var f = el.form;
    if (f && f.requestSubmit) {
      try { f.requestSubmit(); return; } catch (e) {}
    }
    ['keydown', 'keypress', 'keyup'].forEach(function (t) {
      el.dispatchEvent(new KeyboardEvent(t, {
        key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
        bubbles: true, cancelable: true }));
    });
  }

  function video() { return document.querySelector('video'); }
  var lastPlayerOk = 0;
  function isPlayer(el) {
    return !!el && (el.tagName === 'VIDEO' ||
      (el.classList && el.classList.contains('html5-video-player')));
  }

  // Called natively when OK is pressed (see MainActivity). Returns 'text' when
  // a text field has focus so the app can raise the on-screen keyboard.
  function fieldText(el) {
    if (!el) return '';
    if (typeof el.value === 'string') return el.value.trim();
    return (el.textContent || '').trim();
  }

  window.__ytmbOk = function () {
    try {
      var v = video();
      if (document.fullscreenElement && v) {
        v.paused ? v.play() : v.pause();
        return '';
      }
      var active = deepActive();
      if (isTextField(active)) {
        if (fieldText(active)) {
          submitField(active);
          return '';
        }
        return 'text';
      }
      var t = (current && current.isConnected) ? current : null;
      if (!t) return '';
      if (isTextField(t)) { t.focus(); return 'text'; }
      if (isPlayer(t) && v) {
        // OK = play/pause; OK twice quickly = fullscreen.
        var now = Date.now();
        var dbl = now - lastPlayerOk < 500;
        lastPlayerOk = now;
        if (dbl) {
          v.play();
          var b = document.querySelector('.fullscreen-icon, .ytp-fullscreen-button');
          if (b) {
            var r = b.getBoundingClientRect();
            return 'fs:' + centerOf(b);
          }
          return '';
        }
        v.paused ? v.play() : v.pause();
        return '';
      }
      return activate(t);
    } catch (err) { return ''; }
  };

  document.addEventListener('keydown', function (e) {
    var k = e.key;
    var arrow = k === 'ArrowUp' || k === 'ArrowDown' ||
                k === 'ArrowLeft' || k === 'ArrowRight';
    if (!arrow && k !== 'Enter') return;
    if (e.ctrlKey || e.altKey || e.metaKey) return;

    // Fullscreen video: OK = play/pause, left/right = seek 10 s.
    if (document.fullscreenElement && video()) {
      var v = video();
      if (k === 'Enter') { v.paused ? v.play() : v.pause(); }
      else if (k === 'ArrowLeft') v.currentTime = Math.max(0, v.currentTime - 10);
      else if (k === 'ArrowRight') v.currentTime += 10;
      else return;
      e.preventDefault(); e.stopPropagation();
      return;
    }

    if (current && current.isConnected && isPlayer(current) && video() &&
        (k === 'ArrowLeft' || k === 'ArrowRight')) {
      var pv = video();
      pv.currentTime = Math.max(0, pv.currentTime + (k === 'ArrowLeft' ? -10 : 10));
      e.preventDefault(); e.stopPropagation();
      return;
    }

    var active = deepActive();
    if (isTextField(active)) {
      // Let the field handle typing, caret keys and the IME's arrow keys.
      if (k === 'Enter') {
        // OK on an empty box only (re)opens the keyboard; with text it submits.
        if (!fieldText(active)) { e.preventDefault(); e.stopPropagation(); }
        return;
      }
      // Do not steal Up/Down from the on-screen keyboard or caret movement.
      return;
    }

    if (k === 'Enter') {
      var target = (current && current.isConnected) ? current : null;
      if (!target) return;
      if (isTextField(target)) {
        // Focus it, but swallow this OK press so it does not also submit.
        e.preventDefault(); e.stopPropagation();
        try { target.focus(); } catch (x) {}
        return;
      }
      // Native buttons/links get a real click from the browser itself for
      // Enter, but custom elements do not, so click explicitly. (On the mobile
      // site MainActivity handles OK through __ytmbOk, which can use a real
      // native tap for these elements.)
      e.preventDefault(); e.stopPropagation();
      target.click();
      return;
    }

    e.preventDefault(); e.stopPropagation();
    var next = pick(k);
    if (next) setFocus(next);
    else scrollBy(k);
  }, true);

  // Keep the highlight in sync when the user (or the site) moves focus.
  document.addEventListener('focusin', function (e) {
    var t = e.composedPath ? e.composedPath()[0] : e.target;
    if (t && t !== document.body && t.setAttribute && t !== current) {
      if (current) current.removeAttribute('data-ytmb-focus');
      current = t;
      t.setAttribute('data-ytmb-focus', '');
    }
  }, true);
})();
''';
