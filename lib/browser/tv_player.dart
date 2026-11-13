/// Remote-control extras for YouTube's TV interface (youtube.com/tv).
///
/// 1. Instant seek. YouTube's own Left/Right handling pauses the video,
///    enters a "scrub" mode and waits for OK before it jumps, which takes
///    three or four presses. Here Left/Right (and the remote's rewind /
///    fast-forward keys) jump 10 s at once and playback continues. Holding
///    the key speeds up to 30 s and then 60 s steps.
///
/// 2. Voice search. The TV interface shows no microphone in a WebView, so a
///    mic button is drawn next to the search box, on the home screen as well
///    as on the search page (like the official YouTube TV app). From the home
///    screen press Right on the search pill; on the search page press Up from
///    the top row of the on-screen keyboard. OK speaks. The app runs the
///    TV's own speech recogniser and the recognised words are typed into
///    YouTube's search box, exactly as a hardware keyboard would.
///
/// Injected at document start, TV interface only.
const String tvPlayerScript = r'''
(function () {
  if (window.__ytmbPlayer) return;
  if (location.hostname.indexOf('music.') === 0 ||
      !/(^|\.)youtube\.com$/.test(location.hostname) ||
      !(location.pathname === '/tv' || location.pathname.indexOf('/tv/') === 0)) {
    return;
  }
  window.__ytmbPlayer = true;

  // ---- small on-screen message ------------------------------------------
  var toastEl = null, toastTimer = null;
  function toast(text, ms) {
    if (!document.body) return;
    if (!toastEl) {
      toastEl = document.createElement('div');
      toastEl.style.cssText =
        'position:fixed;left:50%;bottom:14%;transform:translateX(-50%);' +
        'z-index:2147483647;padding:14px 34px;border-radius:40px;' +
        'background:rgba(15,15,15,.88);color:#fff;font:500 38px Roboto,' +
        'Arial,sans-serif;pointer-events:none;display:none;white-space:nowrap';
      document.body.appendChild(toastEl);
    }
    toastEl.textContent = text;
    toastEl.style.display = 'block';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () {
      toastEl.style.display = 'none';
    }, ms || 900);
  }

  function activeTag() {
    var a = document.activeElement;
    return a ? a.tagName : '';
  }

  // ---- instant seek -----------------------------------------------------
  function video() {
    var all = document.querySelectorAll('video');
    for (var i = 0; i < all.length; i++) {
      if (all[i].currentSrc || all[i].videoWidth) return all[i];
    }
    return null;
  }

  function seekable() {
    if (location.hash.indexOf('#/watch') !== 0) return false;
    // Only while the remote is "on the video": controls hidden, or the
    // progress bar focused. In the button rows Left/Right move the focus.
    var tag = activeTag();
    return tag === 'YTLR-WATCH-DEFAULT' || tag === 'YTLR-PROGRESS-BAR' ||
        tag === 'BODY' || tag === 'YTLR-PLAYER';
  }

  var pending = 0, shown = 0, cooling = null, streak = 0;
  function clock(s) {
    s = Math.round(s);
    var m = Math.floor(s / 60), r = s % 60;
    return m ? m + ':' + (r < 10 ? '0' : '') + r : s + ' s';
  }
  function flush() {
    var d = pending;
    pending = 0;
    var v = video();
    if (!v || !d) return;
    var end = isFinite(v.duration) && v.duration > 0 ? v.duration - 1 : 1e9;
    var t = Math.max(0, Math.min(end, v.currentTime + d));
    var wasPaused = v.paused;
    var p = document.querySelector('.html5-video-player');
    try {
      if (p && typeof p.seekTo === 'function') p.seekTo(t, true);
      else v.currentTime = t;
    } catch (e) {
      try { v.currentTime = t; } catch (x) {}
    }
    if (!wasPaused && v.paused) { try { v.play(); } catch (e) {} }
  }
  function seek(dir, repeat) {
    streak = repeat ? streak + 1 : 0;
    var step = streak > 20 ? 60 : streak > 8 ? 30 : 10;
    pending += dir * step;
    shown = cooling ? shown + dir * step : dir * step;
    toast((shown < 0 ? '− ' : '+ ') + clock(Math.abs(shown)));
    // The first press seeks at once; presses during the next 250 ms are
    // added up into a single seek so holding the key does not flood the
    // player.
    if (cooling) return;
    flush();
    cooling = setTimeout(function tick() {
      if (pending) { flush(); cooling = setTimeout(tick, 250); }
      else cooling = null;
    }, 250);
  }

  // ---- voice search -----------------------------------------------------
  var micEl = null, micFocus = false;

  // While the mic is selected the page's own highlight (on the search pill or
  // the keyboard key it still has focus on) is toned down, so only one thing
  // looks selected. The page keeps its focus and gets the remote back after.
  var micStyle = document.createElement('style');
  micStyle.textContent =
    'html[data-ytmb-mic] ytlr-search-bar ytlr-text-box,' +
    'html[data-ytmb-mic] ytlr-search-text-box ytlr-text-box{' +
    'background-color:rgba(255,255,255,.12) !important}' +
    'html[data-ytmb-mic] ytlr-search-bar ytlr-text-box *{' +
    'color:rgba(255,255,255,.75) !important}' +
    'html[data-ytmb-mic] yt-keyboard-key{' +
    'background-color:transparent !important;color:#f1f1f1 !important}';
  (document.head || document.documentElement).appendChild(micStyle);

  function onSearch() { return location.hash.indexOf('#/search') === 0; }

  function setMicFocus(on) {
    if (on === micFocus) return;
    micFocus = on;
    if (on) document.documentElement.setAttribute('data-ytmb-mic', '');
    else document.documentElement.removeAttribute('data-ytmb-mic');
    paintMic();
  }

  function paintMic() {
    if (!micEl) return;
    micEl.style.background = micFocus ? '#f1f1f1' : 'rgba(255,255,255,.14)';
    micEl.style.transform = micFocus ? 'scale(1.12)' : 'none';
    if (micEl.firstChild) {
      micEl.firstChild.setAttribute('fill', micFocus ? '#0f0f0f' : '#f1f1f1');
    }
  }
  // The search pill: ytlr-search-text-box on the search page, ytlr-search-bar
  // (which contains it) on the home and browse pages.
  function searchAnchor() {
    if (location.hash.indexOf('#/watch') === 0) return null;
    var el = document.querySelector('ytlr-search-text-box, ytlr-search-bar');
    if (!el) return null;
    var r = el.getBoundingClientRect();
    if (r.width < 50 || r.bottom < 0 || r.top > window.innerHeight) return null;
    return r;
  }
  // The page marks its focused element with a "zylon-focus" class, which is
  // not always document.activeElement.
  function inSearchBar() {
    var a = document.activeElement;
    if (a && a.closest && a.closest('ytlr-search-bar, ytlr-search-text-box')) {
      return true;
    }
    return !!document.querySelector(
        'ytlr-search-bar.zylon-focus, ytlr-search-bar .zylon-focus, ' +
        'ytlr-search-text-box.zylon-focus, ytlr-search-text-box .zylon-focus');
  }
  function placeMic() {
    var r = searchAnchor();
    if (!r) {
      if (micEl) micEl.style.display = 'none';
      if (micFocus) setMicFocus(false);
      return;
    }
    if (!micEl) {
      micEl = document.createElement('div');
      // Built node by node: the page's Trusted Types policy forbids innerHTML.
      var NS = 'http://www.w3.org/2000/svg';
      var svg = document.createElementNS(NS, 'svg');
      svg.setAttribute('viewBox', '0 0 24 24');
      svg.setAttribute('width', '58%');
      svg.setAttribute('height', '58%');
      var path = document.createElementNS(NS, 'path');
      path.setAttribute('d', 'M12 14a3 3 0 0 0 3-3V5a3 3 0 0 0-6 0v6a3 3 0 0 0' +
        ' 3 3zm5-3a5 5 0 0 1-10 0H5a7 7 0 0 0 6 6.92V21h2v-3.08A7 7 0 0 0 19' +
        ' 11h-2z');
      svg.appendChild(path);
      micEl.appendChild(svg);
      micEl.style.cssText =
        'position:fixed;z-index:2147483646;border-radius:50%;display:flex;' +
        'align-items:center;justify-content:center;transition:transform .1s';
      document.body.appendChild(micEl);
    }
    micEl.style.display = 'flex';
    micEl.style.left = Math.round(r.right + r.height * 0.35) + 'px';
    micEl.style.top = Math.round(r.top) + 'px';
    micEl.style.width = micEl.style.height = Math.round(r.height) + 'px';
    paintMic();
  }
  setInterval(placeMic, 500);

  function inTopKeyRow() {
    var a = document.activeElement;
    if (!a || a.tagName !== 'YT-KEYBOARD-KEY') return false;
    var keys = document.querySelectorAll('yt-keyboard-key');
    var top = Infinity;
    for (var i = 0; i < keys.length; i++) {
      top = Math.min(top, keys[i].getBoundingClientRect().top);
    }
    return a.getBoundingClientRect().top - top < 6;
  }

  function startVoice() {
    try {
      window.flutter_inappwebview.callHandler('voiceSearch');
    } catch (e) { toast('Voice search is not available', 2200); }
  }
  // Remote search / microphone key (see MainActivity).
  window.__ytmbVoiceStart = startVoice;

  function press(code, key) {
    var t = document.activeElement || document.body;
    ['keydown', 'keyup'].forEach(function (type) {
      var e = new KeyboardEvent(type, {
        key: key, keyCode: code, which: code, bubbles: true, cancelable: true });
      e.__ytmb = true;
      t.dispatchEvent(e);
    });
  }
  // The text typed so far (not the grey suggestion or the placeholder).
  function typedLength() {
    var box = document.querySelector('ytlr-search-text-box');
    var spans = box ? box.querySelectorAll('span[idomkey]') : [];
    for (var i = 0; i < spans.length; i++) {
      if (spans[i].getAttribute('idomkey') !== 'TyqIye') {
        return spans[i].textContent.length;
      }
    }
    return 0;
  }
  function typeText(text) {
    for (var i = 0; i < text.length; i++) {
      var ch = text[i];
      press(ch === ' ' ? 32 : ch.toUpperCase().charCodeAt(0), ch);
    }
  }
  // Opens the search page (as pressing OK on the search pill does) and calls
  // [then] once its on-screen keyboard is ready.
  function openSearch(then) {
    if (onSearch() && document.querySelector('yt-keyboard-key')) { then(); return; }
    function waitForKeyboard() {
      var tries = 0;
      var wait = setInterval(function () {
        if ((onSearch() && document.querySelector('yt-keyboard-key')) || ++tries > 40) {
          clearInterval(wait);
          if (onSearch()) setTimeout(then, 250);
        }
      }, 100);
    }
    if (onSearch()) { waitForKeyboard(); return; }
    // Started from somewhere else (for example the remote's mic key): walk up
    // to the search pill like a person would, then press OK on it.
    var ups = 0;
    (function toPill() {
      if (!inSearchBar() && ups++ < 8) {
        press(38, 'ArrowUp');
        setTimeout(toPill, 170);
        return;
      }
      if (!inSearchBar()) {
        toast('Select the search bar, then press the mic', 2800);
        return;
      }
      press(13, 'Enter');
      waitForKeyboard();
    })();
  }

  // Called by the app with the recognised words ('' when cancelled).
  window.__ytmbVoiceResult = function (said) {
    setMicFocus(false);
    if (!said) return;
    // The on-screen keyboard only takes these characters from key presses.
    var text = String(said).toLowerCase().replace(/[^a-z0-9 ]+/g, ' ')
        .replace(/\s+/g, ' ').trim();
    if (!text) { toast('Could not use: ' + said, 2500); return; }
    openSearch(function () {
      // Remove what is in the box one character at a time (Backspace on an
      // empty box would leave the search page), then type the new words.
      var guard = 0;
      (function clear() {
        if (typedLength() > 0 && guard++ < 120) {
          press(8, 'Backspace');
          setTimeout(clear, 40);
        } else {
          typeText(text);
          toast('\u201c' + text + '\u201d', 1800);
        }
      })();
    });
  };

  // ---- page ready (hides the app's splash) ------------------------------
  // Ready = a real screen is drawn, not YouTube's own loading logo. After 12 s
  // the splash goes away regardless, so a failed load is never hidden.
  var readyAt = Date.now();
  var readyTimer = setInterval(function () {
    var drawn = document.querySelector('ytlr-tile-renderer, ytlr-search-text-box, ' +
        'ytlr-watch-default, ytlr-sign-in-page, ytlr-welcome-page, ' +
        'ytlr-account-selector-page, ytlr-account-selector');
    if (drawn || Date.now() - readyAt > 12000) {
      clearInterval(readyTimer);
      // One more beat so the first frame is painted before the fade starts.
      setTimeout(function () {
        try { window.flutter_inappwebview.callHandler('pageReady'); } catch (e) {}
      }, 150);
    }
  }, 100);

  // ---- keys -------------------------------------------------------------
  var swallowUp = {};
  window.addEventListener('keydown', function (e) {
    if (e.__ytmb) return;
    var k = e.key, c = e.keyCode;
    var left = k === 'ArrowLeft' || c === 37 || k === 'MediaRewind' || c === 412;
    var right = k === 'ArrowRight' || c === 39 || k === 'MediaFastForward' ||
        c === 417;
    var media = c === 412 || c === 417 || k === 'MediaRewind' ||
        k === 'MediaFastForward';

    if (micFocus) {
      // The mic button holds the remote: OK speaks; Left / Down hand the
      // remote back to the search pill or keyboard; other keys pass through.
      if (k === 'Enter' || c === 13) {
        if (!e.repeat) startVoice();
      } else if (k === 'ArrowLeft' || c === 37 || k === 'ArrowDown' || c === 40) {
        setMicFocus(false);
      } else {
        setMicFocus(false);
        return;
      }
      swallowUp[c] = true;
      e.preventDefault(); e.stopImmediatePropagation();
      return;
    }
    if (micEl && micEl.style.display !== 'none' &&
        (((k === 'ArrowUp' || c === 38) && onSearch() && inTopKeyRow()) ||
         ((k === 'ArrowRight' || c === 39) && !onSearch() && inSearchBar()))) {
      setMicFocus(true);
      swallowUp[c] = true;
      e.preventDefault(); e.stopImmediatePropagation();
      return;
    }
    if ((left || right) && video() &&
        (media ? location.hash.indexOf('#/watch') === 0 : seekable())) {
      seek(left ? -1 : 1, e.repeat);
      swallowUp[c] = true;
      e.preventDefault(); e.stopImmediatePropagation();
    }
  }, true);
  window.addEventListener('keyup', function (e) {
    if (e.__ytmb) return;
    if (swallowUp[e.keyCode]) {
      delete swallowUp[e.keyCode];
      e.preventDefault(); e.stopImmediatePropagation();
    }
  }, true);
})();
''';
