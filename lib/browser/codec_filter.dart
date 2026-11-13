/// Tells YouTube's TV player what this TV can really decode, so its own
/// Quality menu (Auto, 2160p60, 1440p60, 1080p60 ... 240p) offers the right
/// choices and Auto picks something that plays well.
///
/// The WebView reports every codec as "supported, smooth", but a TV chip only
/// decodes some of them in hardware; the rest fall back to software: slow
/// start, dropped frames, 70%+ CPU and memory swapping.
///
/// * AV1 is hidden (it was measured decoding in software in the WebView).
/// * VP9 is offered when the TV has a hardware VP9 decoder ([hwVp9]): sharper
///   than H.264 at the same size, and it is the only way to 1440p / 2160p.
/// * H.264 above 1920x1088 is hidden when VP9 is available (TV H.264 decoders
///   stop there).
/// * HDR transfer functions and absurd probes (framerate=9999) are declined.
/// * Everything up to [maxLongSide] px and [maxFps] fps is listed. Sizes above
///   1080p, which this TV's WebView can only show with many dropped frames,
///   are reported as "not smooth": YouTube's Auto mode then stays at 1080p or
///   below, while choosing 1440p / 2160p by hand in the Quality menu plays them.
///
/// Injected at document start.
String codecFilterScript({
  required bool hwVp9,
  int maxFps = 60,
  int maxLongSide = 3840,
}) =>
    'window.__ytmbHwVp9 = ${hwVp9 ? 'true' : 'false'};\n'
    'window.__ytmbMaxFps = $maxFps;\n'
    'window.__ytmbMaxDim = $maxLongSide;\n'
    '$_codecFilterBody';

const String _codecFilterBody = r'''
(function () {
  if (window.__ytmbCodecs) return;
  window.__ytmbCodecs = true;
  var VP9 = /(vp9|vp09)/i;
  var AVC = /avc[13]/i;
  var hwVp9 = window.__ytmbHwVp9 === true;
  var MAXFPS = window.__ytmbMaxFps || 30;
  var MAXDIM = window.__ytmbMaxDim || 1920;
  var BAD = hwVp9 ? /(av01|av1|vp8)/i : /(av01|av1|vp9|vp09|vp8)/i;

  function num(type, name) {
    var m = new RegExp('[;\\s]' + name + '=(\\d+)', 'i').exec(type);
    return m ? parseInt(m[1], 10) : 0;
  }

  // type: a MIME string, optionally with "; width=..; height=.." hints.
  function blocked(type, w, h, fps) {
    type = String(type);
    if (BAD.test(type)) return true;
    w = w || num(type, 'width'); h = h || num(type, 'height');
    if (Math.max(w, h) > MAXDIM) return true;
    // Frame rate and bitrate limits. Also answers YouTube's "framerate=9999"
    // honesty probe correctly.
    fps = fps || num(type, 'framerate');
    if (fps > MAXFPS || num(type, 'bitrate') > 80000000) return true;
    var eotf = /[;\s]eotf=([\w-]+)/i.exec(type);
    if (eotf && eotf[1].toLowerCase() !== 'bt709') return true;
    if (hwVp9 && AVC.test(type) && (w > 1920 || h > 1088)) return true;
    return false;
  }

  var ms = window.MediaSource || window.WebKitMediaSource;
  if (ms && ms.isTypeSupported) {
    var orig = ms.isTypeSupported.bind(ms);
    ms.isTypeSupported = function (t) {
      return blocked(t) ? false : orig(t);
    };
  }

  var vp = window.HTMLMediaElement && HTMLMediaElement.prototype;
  if (vp && vp.canPlayType) {
    var origCan = vp.canPlayType;
    vp.canPlayType = function (t) {
      return blocked(t) ? '' : origCan.call(this, t);
    };
  }

  var mc = navigator.mediaCapabilities;
  if (mc && mc.decodingInfo) {
    var origInfo = mc.decodingInfo.bind(mc);
    mc.decodingInfo = function (cfg) {
      var v = cfg && cfg.video;
      try {
        if (v && v.contentType && blocked(v.contentType, v.width, v.height, v.framerate)) {
          return Promise.resolve({
            supported: false, smooth: false, powerEfficient: false });
        }
      } catch (e) {}
      var p = origInfo(cfg);
      try {
        var heavy = v && Math.max(v.width || 0, v.height || 0) > 1920;
        if (heavy) {
          return p.then(function (r) {
            return { supported: r.supported, smooth: false,
                     powerEfficient: false, keySystemAccess: r.keySystemAccess,
                     configuration: r.configuration };
          });
        }
      } catch (e) {}
      return p;
    };
  }
})();
''';
