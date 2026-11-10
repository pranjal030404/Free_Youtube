/// Makes YouTube pick H.264 on TVs.
///
/// The WebView reports AV1 and VP9 as "supported, smooth", but low-end TV
/// chips only have hardware H.264 decoders, so AV1/VP9 end up decoded in
/// software: slow video start, dropped frames, 70%+ CPU and memory swapping.
/// Hiding them from the page makes YouTube serve H.264 (up to 1080p), which
/// the TV decodes in hardware. Injected at document start.
const String codecFilterScript = r'''
(function () {
  if (window.__ytmbCodecs) return;
  window.__ytmbCodecs = true;
  var BAD = /(av01|av1|vp9|vp09|vp8)/i;

  var ms = window.MediaSource || window.WebKitMediaSource;
  if (ms && ms.isTypeSupported) {
    var orig = ms.isTypeSupported.bind(ms);
    ms.isTypeSupported = function (t) {
      return BAD.test(String(t)) ? false : orig(t);
    };
  }

  var vp = window.HTMLMediaElement && HTMLMediaElement.prototype;
  if (vp && vp.canPlayType) {
    var origCan = vp.canPlayType;
    vp.canPlayType = function (t) {
      return BAD.test(String(t)) ? '' : origCan.call(this, t);
    };
  }

  var mc = navigator.mediaCapabilities;
  if (mc && mc.decodingInfo) {
    var origInfo = mc.decodingInfo.bind(mc);
    mc.decodingInfo = function (cfg) {
      try {
        var ct = cfg && cfg.video && cfg.video.contentType;
        if (ct && BAD.test(ct)) {
          return Promise.resolve({
            supported: false, smooth: false, powerEfficient: false });
        }
      } catch (e) {}
      return origInfo(cfg);
    };
  }
})();
''';
