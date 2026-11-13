/// Mobile site tweaks that make m.youtube.com behave like the YouTube app.
///
/// 1. The video's "•••" sheet gets a "Download" row between Save and Report,
///    exactly where the official app puts it.
/// 2. The page's light/dark state is reported so the app chrome matches it.
const String mobilePageScript = r"""
(function () {
  if (window.__ytlMobile) return;
  window.__ytlMobile = true;
  var ARROW = 'M17 18v1H6v-1h11zm-.5-6.6-.7-.7-3.8 3.8V4h-1v10.5l-3.8-3.8-.7.7 5 5 5-5z';
  function call(name, arg) {
    try { window.flutter_inappwebview.callHandler(name, arg); } catch (e) {}
  }
  function isDark() {
    var h = document.documentElement;
    if (h.hasAttribute('dark')) return true;
    var bg = getComputedStyle(document.body || h).backgroundColor.match(/\d+/g);
    return !!bg && (+bg[0] + +bg[1] + +bg[2]) < 300;
  }
  var lastDark = null;
  function reportTheme() {
    var d = isDark();
    if (d !== lastDark) { lastDark = d; call('ytlTheme', d); }
  }
  function isWatch() {
    return location.pathname === '/watch' || location.pathname.indexOf('/shorts/') === 0;
  }
  // The video a "•••" button belongs to (feed, search, channel lists).
  var lastId = null;
  function idFrom(el) {
    for (var n = el; n && n !== document.body; n = n.parentElement) {
      var a = n.querySelector && n.querySelector('a[href*="/watch?v="], a[href*="/shorts/"]');
      if (a) {
        var m = (a.getAttribute('href') || '').match(/(?:[?&]v=|\/shorts\/)([\w-]{11})/);
        if (m) return m[1];
      }
    }
    return null;
  }
  document.addEventListener('click', function (e) {
    var t = e.target;
    if (t && t.closest && t.closest('bottom-sheet-container')) return;
    lastId = idFrom(t);
  }, true);
  function addDownload() {
    var sheets = document.querySelectorAll('bottom-sheet-container:not([hidden])');
    for (var s = 0; s < sheets.length; s++) {
      var items = sheets[s].querySelectorAll('yt-list-item-view-model');
      if (!items.length || sheets[s].querySelector('[data-ytl-dl]')) continue;
      var save = null, anchor = null, report0 = null;
      items.forEach(function (it) {
        var t = (it.textContent || '').trim();
        if (/^Save/i.test(t)) save = it;
        if (/^Share/i.test(t)) anchor = it;
        else if (/^Report/i.test(t) && !anchor) report0 = it;
      });
      // A video's own menu: feed (Save + Share) or watch page (Save + Report).
      anchor = anchor || report0;
      if (!save || !anchor) continue;
      var report = anchor;
      var row = report.cloneNode(true);
      row.setAttribute('data-ytl-dl', '1');
      var title = row.querySelector('.ytListItemViewModelTitle');
      if (title) title.textContent = 'Download';
      var path = row.querySelector('svg path');
      if (path) path.setAttribute('d', ARROW);
      row.addEventListener('click', function (e) {
        e.stopPropagation(); e.preventDefault();
        call('ytlDownload', { dark: isDark(), id: isWatch() ? null : lastId });
        // Close the sheet the way the page itself does.
        if (location.hash === '#bottom-sheet') history.back();
      }, true);
      var h = report.getBoundingClientRect().height || 48;
      report.parentNode.insertBefore(row, report);
      // The page fixes the sheet's height for its own two rows; grow it.
      var wrap = sheets[s].querySelector('.ytSpecBottomSheetLayoutContentWrapper');
      if (wrap && wrap.style.maxHeight) {
        wrap.style.maxHeight = (parseFloat(wrap.style.maxHeight) + h) + 'px';
      }
    }
  }
  // "You" tab: a Downloads row above "Your videos", like the YouTube app.
  function addLibraryRow() {
    if (location.pathname !== '/feed/library' && location.pathname !== '/feed/you') return;
    var rows = document.querySelectorAll('ytm-compact-link-renderer');
    if (!rows.length || document.querySelector('[data-ytl-dlrow]')) return;
    var first = rows[0];
    for (var i = 0; i < rows.length; i++) {
      if (/^Your videos/i.test((rows[i].textContent || '').trim())) { first = rows[i]; break; }
    }
    var row = first.cloneNode(true);
    row.setAttribute('data-ytl-dlrow', '1');
    var a = row.querySelector('a');
    if (a) a.removeAttribute('href');
    var t = row.querySelector('.ytAttributedStringHost');
    if (t) t.textContent = 'Downloads';
    var path = row.querySelector('svg path');
    if (path) path.setAttribute('d', ARROW);
    row.addEventListener('click', function (e) {
      e.stopPropagation(); e.preventDefault();
      call('ytlOpenDownloads', true);
    }, true);
    first.parentNode.insertBefore(row, first);
  }
  var pending = false;
  new MutationObserver(function () {
    if (pending) return;
    pending = true;
    requestAnimationFrame(function () { pending = false; addDownload(); addLibraryRow(); reportTheme(); });
  }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['hidden', 'dark'] });
  reportTheme();
})();
""";
