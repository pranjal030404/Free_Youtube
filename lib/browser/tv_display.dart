/// Makes YouTube's TV interface render at the TV's real resolution.
///
/// youtube.com/tv has no viewport tag, so the WebView lays it out on its
/// 980-px "desktop" fallback and stretches the result over the 1920-px panel:
/// YouTube believes it runs on a 980x551 screen and everything it draws
/// (text, icons, thumbnails) is rendered at half resolution and scaled up.
///
/// Declaring a 1920-px-wide viewport makes one CSS pixel one screen pixel. The
/// interface looks the same size because YouTube scales it with the viewport.
///
/// Thumbnails need one more step: whatever the screen size, YouTube's server
/// only offers this client 320x180 thumbnails, which are soft on a tile that
/// is 720 px wide. Each landscape tile is therefore switched to the video's
/// 1280x720 thumbnail once that image has loaded (so there is no flash), and
/// keeps the small one when the video has no HD thumbnail.
/// Injected at document start, TV interface only.
const String tvDisplayScript = r'''
(function () {
  if (window.__ytmbDisplay) return;
  if (location.hostname.indexOf('music.') === 0 ||
      !/(^|\.)youtube\.com$/.test(location.hostname) ||
      !(location.pathname === '/tv' || location.pathname.indexOf('/tv/') === 0)) {
    return;
  }
  window.__ytmbDisplay = true;
  var W = 1920;
  var H = Math.round(W * screen.height / screen.width) || 1080;

  // The page also reads the screen object when it picks stream quality.
  function fixed(obj, name, value) {
    try {
      Object.defineProperty(obj, name, {
        configurable: true, get: function () { return value; } });
    } catch (e) {}
  }
  fixed(screen, 'width', W); fixed(screen, 'height', H);
  fixed(screen, 'availWidth', W); fixed(screen, 'availHeight', H);
  fixed(window, 'devicePixelRatio', 1);
  fixed(window, 'outerWidth', W); fixed(window, 'outerHeight', H);

  function apply() {
    var parent = document.head || document.documentElement;
    if (!parent) return false;
    var m = document.getElementById('__ytmb_viewport');
    if (!m) {
      m = document.createElement('meta');
      m.id = '__ytmb_viewport';
      m.name = 'viewport';
    }
    m.content = 'width=' + W + ', user-scalable=no';
    // Appending (again) makes it the last viewport tag, which is the one the
    // browser obeys.
    parent.appendChild(m);
    return true;
  }
  if (!apply()) {
    var mo = new MutationObserver(function () {
      if (apply()) mo.disconnect();
    });
    mo.observe(document, { childList: true, subtree: true });
  }
  document.addEventListener('DOMContentLoaded', apply);

  // ---- HD thumbnails -----------------------------------------------------
  var LOW = /i\.ytimg\.com\/vi\/([\w-]{11})\/(?:hq|mq|sd)?default\.jpg/;
  var hd = {};        // video id -> HD url, or 0 when there is none
  var hdCount = 0;
  var loading = {};
  function probe(id) {
    loading[id] = true;
    var url = 'https://i.ytimg.com/vi/' + id + '/hq720.jpg';
    var img = new Image();
    var done = function (ok) {
      delete loading[id];
      if (++hdCount > 600) { hd = {}; hdCount = 0; }
      hd[id] = ok ? url : 0;
      if (ok) upgrade();
    };
    // A missing thumbnail is answered with a 120x90 placeholder.
    img.onload = function () { done(img.naturalWidth >= 640); };
    img.onerror = function () { done(false); };
    img.src = url;
  }
  function upgrade() {
    var els = document.getElementsByTagName('ytlr-thumbnail-details');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      var bg = el.style.backgroundImage;
      if (!bg) continue;
      var m = LOW.exec(bg);
      if (!m) continue;
      var id = m[1], known = hd[id];
      if (known === 0 || loading[id]) continue;
      // Portrait (Shorts) tiles use a cropped image; leave those alone.
      if (el.offsetWidth <= el.offsetHeight) continue;
      if (known) el.style.backgroundImage = 'url("' + known + '")';
      else probe(id);
    }
  }
  setInterval(upgrade, 400);
})();
''';
