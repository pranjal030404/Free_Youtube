/// In-page YouTube ad removal, injected at document start.
///
/// 1. Strips ad fields from player API responses (fetch / JSON.parse /
///    ytInitialPlayerResponse) so most ads are never scheduled.
/// 2. If an ad still appears, clicks "Skip", mutes and fast-forwards it.
/// 3. Hides banner / feed ad containers with CSS.
const String ytAdSkipperScript = r"""
(function () {
  if (window.__ytmbAds) return;
  window.__ytmbAds = true;
  const AD_KEYS = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams'];
  function strip(o) {
    try {
      if (o && typeof o === 'object') {
        for (const k of AD_KEYS) if (k in o) { try { delete o[k]; } catch (e) { o[k] = undefined; } }
        if (o.playerResponse) strip(o.playerResponse);
        if (o.response) strip(o.response);
      }
    } catch (e) {}
    return o;
  }

  // JSON.parse hook
  const origParse = JSON.parse;
  // The TV interface loads its data with XHR + JSON.parse (not fetch), so
  // sponsored tiles are pruned here too, for YouTube API responses only.
  JSON.parse = function () {
    const o = origParse.apply(this, arguments);
    if (o && typeof o === 'object' && o.responseContext) prune(o, 0);
    return strip(o);
  };

  // Sponsored tiles / promoted items inside feed, search and browse data.
  // Removing them from the response (rather than hiding them with CSS) keeps
  // the TV interface's own focus handling consistent: it never knows they
  // existed.
  var AD_ITEM_KEYS = ['adSlotRenderer', 'promotedSparklesWebRenderer',
    'promotedVideoRenderer', 'compactPromotedVideoRenderer',
    'displayAdRenderer', 'inFeedAdLayoutRenderer', 'bannerPromoRenderer'];
  function isAdItem(x) {
    if (!x || typeof x !== 'object' || Array.isArray(x)) return false;
    for (let i = 0; i < AD_ITEM_KEYS.length; i++) {
      if (AD_ITEM_KEYS[i] in x) return true;
    }
    return false;
  }
  function prune(node, depth) {
    if (!node || typeof node !== 'object' || depth > 40) return 0;
    let n = 0;
    if (Array.isArray(node)) {
      for (let i = node.length - 1; i >= 0; i--) {
        if (isAdItem(node[i])) { node.splice(i, 1); n++; }
        else n += prune(node[i], depth + 1);
      }
    } else {
      for (const k in node) n += prune(node[k], depth + 1);
    }
    return n;
  }

  // fetch hook for the player and the feed endpoints. Responses are only
  // re-serialised when something was actually removed.
  const origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function () {
      const p = origFetch.apply(this, arguments);
      try {
        const u = String(arguments[0] && arguments[0].url || arguments[0]);
        const m = /\/youtubei\/v1\/(player|browse|next|search)\b/.exec(u);
        if (m) {
          return p.then((r) => {
            const c = r.clone();
            return c.text().then((t) => {
              try {
                const j = origParse(t);
                let changed = false;
                if (m[1] === 'player') { strip(j); changed = true; }
                else if (prune(j, 0) > 0) changed = true;
                if (!changed) return r;
                return new Response(JSON.stringify(j), { status: r.status, statusText: r.statusText, headers: r.headers });
              } catch (e) { return r; }
            }).catch(() => r);
          });
        }
      } catch (e) {}
      return p;
    };
  }

  // Initial player response set by the page
  try {
    let _ipr;
    Object.defineProperty(window, 'ytInitialPlayerResponse', {
      configurable: true,
      get: () => _ipr,
      set: (v) => { _ipr = strip(v); },
    });
  } catch (e) {}

  // CSS hiding of ad containers
  const css = [
    'ytd-ad-slot-renderer', 'ytm-promoted-sparkles-web-renderer', 'ytm-promoted-video-renderer',
    'ytm-companion-ad-renderer', 'ytm-ad-slot-renderer', 'ytm-statement-banner-renderer',
    'ytm-in-feed-ad-layout-renderer', 'ytm-display-ad-renderer', 'ytm-brand-video-singleton-renderer',
    '#player-ads', '.ytp-ad-overlay-container', '.ytp-ad-module', '.video-ads',
    'ytmusic-mealbar-promo-renderer', 'ytmusic-statement-banner-renderer',
    'ad-slot-renderer', 'ytd-promoted-sparkles-web-renderer', '.ad-container',
  ].join(',') + '{display:none !important}';
  function addStyle() {
    if (document.getElementById('__ytmb_css')) return;
    const s = document.createElement('style');
    s.id = '__ytmb_css';
    s.textContent = css;
    (document.head || document.documentElement).appendChild(s);
  }
  addStyle();
  document.addEventListener('DOMContentLoaded', addStyle);

  // Runtime skipper
  let savedMuted = null;
  function skip() {
    try {
      const player = document.querySelector('#movie_player, .html5-video-player, ytmusic-player');
      const v = document.querySelector('video');
      const adShowing = !!(player && player.classList && player.classList.contains('ad-showing')) ||
          !!document.querySelector('.ytp-ad-player-overlay, .ytp-ad-text, .ad-showing');
      const btn = document.querySelector(
          '.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, ' +
          '.ytp-ad-skip-button-container button, .ytp-ad-overlay-close-button, .ytp-ad-survey-answer-button');
      if (btn) btn.click();
      if (adShowing && v) {
        if (savedMuted === null) savedMuted = v.muted;
        v.muted = true;
        if (isFinite(v.duration) && v.duration > 0) {
          try { v.currentTime = v.duration; } catch (e) {}
        }
        try { v.playbackRate = 16; } catch (e) {}
        if (v.paused) { try { v.play(); } catch (e) {} }
      } else if (savedMuted !== null) {
        if (v) { v.muted = savedMuted; try { v.playbackRate = 1; } catch (e) {} }
        savedMuted = null;
      }
    } catch (e) {}
  }
  // 1 s is still fast enough for the skip button and avoids running several
  // DOM queries three times per second on low-end phones and TVs.
  setInterval(skip, 1000);
})();
""";
