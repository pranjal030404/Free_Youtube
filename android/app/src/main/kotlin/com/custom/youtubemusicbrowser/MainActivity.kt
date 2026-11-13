package com.custom.youtubemusicbrowser

import android.Manifest
import android.app.UiModeManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /**
     * Applies the in-app theme choice (Settings > Theme) to the whole
     * activity, so the WebView reports the matching prefers-color-scheme and
     * YouTube renders dark or light accordingly.
     */
    override fun attachBaseContext(newBase: android.content.Context) {
        val mode = try {
            newBase.getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                .getString("flutter.theme_mode", null)
        } catch (_: Exception) {
            null
        }
        val night = when (mode) {
            "dark" -> Configuration.UI_MODE_NIGHT_YES
            "light" -> Configuration.UI_MODE_NIGHT_NO
            else -> null
        }
        if (night == null) {
            super.attachBaseContext(newBase)
            return
        }
        val config = Configuration(newBase.resources.configuration)
        config.uiMode = (config.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or night
        super.attachBaseContext(newBase.createConfigurationContext(config))
    }

    private var askedNotificationPermission = false
    private var deviceChannel: MethodChannel? = null

    /** True while the web page (not a Flutter route such as Settings) owns the remote. */
    private var pageOwnsRemote = true

    /** True on youtube.com/tv: the page handles every remote key itself. */
    private var pageHandlesRemote = false

    /**
     * Ask for notification permission only when playback actually starts, not
     * on launch. Showing a system dialog during startup made the app feel slow.
     */
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 && !askedNotificationPermission &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            askedNotificationPermission = true
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    /** Finds the native WebView inside Flutter's platform-view wrapper. */
    /**
     * flutter_inappwebview always wraps the WebView in a SwipeRefreshLayout.
     * On TV that wrapper can steal touch events from the page; we do not use
     * pull-to-refresh, so disable it once the view is available.
     */
    private fun disablePullToRefresh(view: View) {
        var parent = view.parent
        while (parent != null) {
            if (parent.javaClass.simpleName == "PullToRefreshLayout") {
                (parent as? View)?.isEnabled = false
                return
            }
            parent = parent.parent
        }
    }

    private var cachedWebView: java.lang.ref.WeakReference<WebView>? = null

    /** The WebView, cached: walking the view tree on every key press is wasteful. */
    private fun pageWebView(): WebView? {
        cachedWebView?.get()?.let { if (it.isAttachedToWindow) return it }
        val found = findViewById<View>(FLUTTER_VIEW_ID)?.let { findWebView(it) }
        cachedWebView = found?.let { java.lang.ref.WeakReference(it) }
        return found
    }

    private fun findWebView(view: View): WebView? {
        if (view is WebView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findWebView(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    /**
     * The WebView's default user agent (minus the `; wv` marker), built from
     * the installed WebView version instead of asking WebView for it: that
     * call loads the whole Chromium engine and delayed the first frame by
     * seconds on low-end TVs. Null if the version is not available.
     */
    private fun fastUserAgent(): String? {
        if (Build.VERSION.SDK_INT < 26) return null
        val version = try {
            WebView.getCurrentWebViewPackage()?.versionName
        } catch (_: Exception) {
            null
        } ?: return null
        return "Mozilla/5.0 (Linux; Android ${Build.VERSION.RELEASE}; ${Build.MODEL} " +
            "Build/${Build.ID}) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/$version Mobile Safari/537.36"
    }

    /**
     * True when the device has a hardware VP9 decoder that takes at least
     * 1080p in both orientations (portrait Shorts are 1080x1920). The page is
     * only offered VP9 in that case; see codec_filter.dart.
     */
    private fun hasHardwareVp9(): Boolean = try {
        android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS)
            .codecInfos.any { info ->
                if (info.isEncoder) return@any false
                val software = if (Build.VERSION.SDK_INT >= 29) !info.isHardwareAccelerated
                    else info.name.startsWith("OMX.google.") || info.name.startsWith("c2.android.")
                if (software || "video/x-vnd.on2.vp9" !in info.supportedTypes) return@any false
                val video = info.getCapabilitiesForType("video/x-vnd.on2.vp9").videoCapabilities
                video != null && video.isSizeSupported(1920, 1080) &&
                    video.supportedHeights.upper >= 1920
            }
    } catch (_: Exception) {
        false
    }

    /** Copies [src] to shared storage; returns a path to show the user. */
    private fun saveMedia(src: java.io.File, name: String, audio: Boolean, mime: String): String {
        val folder = (if (audio) android.os.Environment.DIRECTORY_MUSIC
            else android.os.Environment.DIRECTORY_MOVIES) + "/YT Lite"
        if (Build.VERSION.SDK_INT >= 29) {
            val collection = if (audio)
                android.provider.MediaStore.Audio.Media.getContentUri(
                    android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else
                android.provider.MediaStore.Video.Media.getContentUri(
                    android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mime)
                put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, folder)
                put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(collection, values)
                ?: throw java.io.IOException("Could not create the file")
            try {
                contentResolver.openOutputStream(uri)!!.use { out ->
                    src.inputStream().use { it.copyTo(out, 1 shl 16) }
                }
                values.clear()
                values.put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
            } catch (e: Exception) {
                contentResolver.delete(uri, null, null)
                throw e
            }
            return "$folder/$name"
        }
        // Android 9 and older: the app's own external folder needs no permission.
        val dir = getExternalFilesDir(
            if (audio) android.os.Environment.DIRECTORY_MUSIC
            else android.os.Environment.DIRECTORY_MOVIES
        ) ?: filesDir
        dir.mkdirs()
        val dest = java.io.File(dir, name)
        src.copyTo(dest, overwrite = true)
        return dest.absolutePath
    }

    /** Joins a video-only and an audio-only file into one file, no re-encoding. */
    private fun muxMedia(video: String, audio: String, out: String, webm: Boolean) {
        val fmt = if (webm) android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM
            else android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
        val muxer = android.media.MediaMuxer(out, fmt)
        val extractors = ArrayList<android.media.MediaExtractor>()
        try {
            val map = ArrayList<Pair<android.media.MediaExtractor, Int>>()
            for ((path, prefix) in listOf(video to "video/", audio to "audio/")) {
                val ex = android.media.MediaExtractor().also { extractors.add(it) }
                ex.setDataSource(path)
                val track = (0 until ex.trackCount).firstOrNull {
                    ex.getTrackFormat(it).getString(android.media.MediaFormat.KEY_MIME)
                        ?.startsWith(prefix) == true
                } ?: throw java.io.IOException("No $prefix track")
                ex.selectTrack(track)
                map.add(ex to muxer.addTrack(ex.getTrackFormat(track)))
            }
            muxer.start()
            val buf = java.nio.ByteBuffer.allocate(4 shl 20)
            val info = android.media.MediaCodec.BufferInfo()
            for ((ex, idx) in map) {
                while (true) {
                    buf.clear()
                    val n = ex.readSampleData(buf, 0)
                    if (n < 0) break
                    info.set(0, n, ex.sampleTime, ex.sampleFlags)
                    muxer.writeSampleData(idx, buf, info)
                    ex.advance()
                }
            }
            muxer.stop()
        } finally {
            extractors.forEach { try { it.release() } catch (_: Exception) {} }
            try { muxer.release() } catch (_: Exception) {}
        }
    }

    /** The videos and songs saved by [saveMedia]. */
    private fun listMedia(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        if (Build.VERSION.SDK_INT >= 29) {
            for (audio in listOf(false, true)) {
                val collection = if (audio)
                    android.provider.MediaStore.Audio.Media.getContentUri(
                        android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
                else
                    android.provider.MediaStore.Video.Media.getContentUri(
                        android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
                val folder = (if (audio) android.os.Environment.DIRECTORY_MUSIC
                    else android.os.Environment.DIRECTORY_MOVIES) + "/YT Lite/"
                contentResolver.query(
                    collection,
                    arrayOf(android.provider.MediaStore.MediaColumns._ID, android.provider.MediaStore.MediaColumns.DISPLAY_NAME, android.provider.MediaStore.MediaColumns.SIZE, android.provider.MediaStore.MediaColumns.DATE_ADDED, android.provider.MediaStore.MediaColumns.MIME_TYPE, android.provider.MediaStore.MediaColumns.DURATION),
                    "${android.provider.MediaStore.MediaColumns.RELATIVE_PATH} = ? AND ${android.provider.MediaStore.MediaColumns.OWNER_PACKAGE_NAME} = ?",
                    arrayOf(folder, packageName), null,
                )?.use { c ->
                    while (c.moveToNext()) {
                        out.add(mapOf(
                            "uri" to android.content.ContentUris
                                .withAppendedId(collection, c.getLong(0)).toString(),
                            "name" to c.getString(1),
                            "size" to c.getLong(2),
                            "date" to c.getLong(3),
                            "mime" to (c.getString(4) ?: if (audio) "audio/*" else "video/*"),
                            "audio" to audio,
                            "duration" to c.getLong(5),
                        ))
                    }
                }
            }
            return out
        }
        for (audio in listOf(false, true)) {
            val dir = getExternalFilesDir(
                if (audio) android.os.Environment.DIRECTORY_MUSIC
                else android.os.Environment.DIRECTORY_MOVIES
            ) ?: continue
            dir.listFiles()?.filter { it.isFile }?.forEach { f ->
                out.add(mapOf(
                    "uri" to android.net.Uri.fromFile(f).toString(),
                    "name" to f.name,
                    "size" to f.length(),
                    "date" to f.lastModified() / 1000,
                    "mime" to if (audio) "audio/*" else "video/mp4",
                    "audio" to audio,
                ))
            }
        }
        return out
    }

    /** True on Android TV / Google TV / Fire TV style devices. */
    private fun isTelevision(): Boolean {
        val pm = packageManager
        if (pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            pm.hasSystemFeature(PackageManager.FEATURE_TELEVISION)
        ) {
            return true
        }
        val uiMode = getSystemService(UI_MODE_SERVICE) as? UiModeManager
        return uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        deviceChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ytmb/device")
        deviceChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "isTv" -> result.success(isTelevision())
                // One combined call keeps startup to a single round-trip.
                "deviceInfo" -> result.success(
                    mapOf(
                        "isTv" to isTelevision(),
                        "sdkInt" to Build.VERSION.SDK_INT,
                        "userAgent" to fastUserAgent(),
                        "hwVp9" to hasHardwareVp9(),
                    )
                )
                // Give Android key focus back to Flutter so D-pad navigation
                // works in routes drawn on top of the WebView (Settings).
                // Moves a finished download from the app cache into the
                // phone's shared Movies / Music folder.
                "muxMedia" -> {
                    val v = call.argument<String>("video")
                    val a = call.argument<String>("audio")
                    val o = call.argument<String>("out")
                    val webm = call.argument<Boolean>("webm") ?: false
                    if (v == null || a == null || o == null) {
                        result.error("args", "path missing", null)
                    } else {
                        Thread {
                            try {
                                muxMedia(v, a, o, webm)
                                runOnUiThread { result.success(null) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("mux", e.message, null) }
                            }
                        }.start()
                    }
                }
                "saveMedia" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name") ?: "download"
                    val audio = call.argument<Boolean>("audio") ?: false
                    val mime = call.argument<String>("mime") ?: "video/mp4"
                    if (path == null) {
                        result.error("args", "path missing", null)
                    } else {
                        Thread {
                            try {
                                val where = saveMedia(java.io.File(path), name, audio, mime)
                                runOnUiThread { result.success(where) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("save", e.message, null) }
                            }
                        }.start()
                    }
                }
                // Theme changed: start again so everything picks it up.
                "restart" -> {
                    result.success(null)
                    runOnUiThread { recreate() }
                }
                "listMedia" -> {
                    Thread {
                        try {
                            val items = listMedia()
                            runOnUiThread { result.success(items) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("list", e.message, null) }
                        }
                    }.start()
                }
                // Opens a download in the phone's video / music player.
                "playMedia" -> {
                    try {
                        val uri = android.net.Uri.parse(call.argument<String>("uri"))
                        if (uri.scheme == "file") {
                            // Android 9 and older only (see saveMedia).
                            android.os.StrictMode.setVmPolicy(
                                android.os.StrictMode.VmPolicy.Builder().build())
                        }
                        val view = Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, call.argument<String>("mime") ?: "video/*")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        startActivity(Intent.createChooser(view, "Play with"))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("play", "No app found to play this file", null)
                    }
                }
                "thumb" -> {
                    val uriStr = call.argument<String>("uri")
                    Thread {
                        try {
                            val bmp = if (Build.VERSION.SDK_INT >= 29)
                                contentResolver.loadThumbnail(
                                    android.net.Uri.parse(uriStr),
                                    android.util.Size(480, 270), null)
                            else null
                            if (bmp == null) {
                                runOnUiThread { result.success(null) }
                            } else {
                                val bos = java.io.ByteArrayOutputStream()
                                bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, bos)
                                val bytes = bos.toByteArray()
                                runOnUiThread { result.success(bytes) }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.success(null) }
                        }
                    }.start()
                }
                "storageInfo" -> {
                    try {
                        val st = android.os.StatFs(android.os.Environment.getExternalStorageDirectory().path)
                        result.success(mapOf("total" to st.totalBytes, "free" to st.availableBytes))
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                "deleteMedia" -> {
                    try {
                        val uri = android.net.Uri.parse(call.argument<String>("uri"))
                        if (uri.scheme == "file") java.io.File(uri.path!!).delete()
                        else contentResolver.delete(uri, null, null)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("delete", e.message, null)
                    }
                }
                // Voice search: the TV's own speech recogniser (its dialog
                // listens through the remote's microphone).
                "recognizeSpeech" -> {
                    if (pendingSpeech != null) {
                        result.error("busy", "Already listening", null)
                    } else {
                        val intent = Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                            .putExtra(
                                android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                                android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                            )
                            .putExtra(android.speech.RecognizerIntent.EXTRA_PROMPT, "Search YouTube")
                            .putExtra(android.speech.RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                        try {
                            pendingSpeech = result
                            startActivityForResult(intent, SPEECH_REQUEST)
                        } catch (_: Exception) {
                            pendingSpeech = null
                            result.error("unavailable", "Voice search is not available on this TV", null)
                        }
                    }
                }
                "setPageHandlesRemote" -> {
                    pageHandlesRemote = call.arguments as? Boolean ?: false
                    result.success(null)
                }
                "requestFlutterFocus" -> {
                    pageOwnsRemote = false
                    runOnUiThread {
                        findViewById<View>(FLUTTER_VIEW_ID)?.requestFocus()
                    }
                    result.success(null)
                }
                // Hand D-pad/OK input back to the page after Settings closes.
                "requestWebViewFocus" -> {
                    pageOwnsRemote = true
                    runOnUiThread {
                        findViewById<View>(FLUTTER_VIEW_ID)
                            ?.let { findWebView(it) }
                            ?.let { webView ->
                                disablePullToRefresh(webView)
                                webView.requestFocus()
                            }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ytmb/playback")
        // Media-session commands (watch / headset / lock screen) -> Dart.
        PlaybackService.commandSink = { cmd, arg ->
            runOnUiThread { channel.invokeMethod("command", mapOf("cmd" to cmd, "arg" to arg)) }
        }
        channel.setMethodCallHandler { call, result ->
            val intent = Intent(this, PlaybackService::class.java)
            when (call.method) {
                // "update" carries {playing, title, artist}; "start" is kept for compatibility.
                "start", "update" -> {
                    val playing = call.argument<Boolean>("playing") ?: true
                    if (playing) ensureNotificationPermission()
                    intent.putExtra("playing", playing)
                    call.argument<String>("title")?.let { intent.putExtra("title", it) }
                    call.argument<String>("artist")?.let { intent.putExtra("artist", it) }
                    try { startForegroundService(intent) } catch (_: Exception) {}
                    result.success(null)
                }
                "stop" -> { stopService(intent); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private var pendingSpeech: MethodChannel.Result? = null

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == SPEECH_REQUEST) {
            val said = if (resultCode == RESULT_OK) {
                data?.getStringArrayListExtra(android.speech.RecognizerIntent.EXTRA_RESULTS)
                    ?.firstOrNull()
            } else {
                null
            }
            pendingSpeech?.success(said)
            pendingSpeech = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    /**
     * TV remotes cannot always reach the on-screen toolbar while the WebView has
     * focus. The menu/settings keys open the app's Settings route instead.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (pageOwnsRemote && event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_MENU,
                KeyEvent.KEYCODE_SETTINGS,
                KeyEvent.KEYCODE_TV_CONTENTS_MENU -> {
                    deviceChannel?.invokeMethod("openSettings", null)
                    return true
                }
                // The remote's search / microphone key, when the system
                // passes it on to the app.
                KeyEvent.KEYCODE_SEARCH,
                KeyEvent.KEYCODE_VOICE_ASSIST -> {
                    deviceChannel?.invokeMethod("voiceKey", null)
                    return true
                }
            }
        }
        // While the on-screen keyboard is open it owns the remote: let the
        // system/IME move between keys and type instead of forwarding D-pad
        // presses to the page.
        if (pageOwnsRemote) {
            val ime = imeVisible()
            if (event.action == KeyEvent.ACTION_DOWN &&
                event.keyCode == KeyEvent.KEYCODE_BACK && ime
            ) {
                // BACK closes the keyboard first, like every other TV app.
                // Blur the field so the D-pad can leave it afterwards.
                pageWebView()?.let { webView ->
                    val imm = getSystemService(INPUT_METHOD_SERVICE)
                        as android.view.inputmethod.InputMethodManager
                    imm.hideSoftInputFromWindow(webView.windowToken, 0)
                    webView.evaluateJavascript(
                        "(function(){try{var e=document.activeElement;" +
                            "while(e&&e.shadowRoot&&e.shadowRoot.activeElement)" +
                            "e=e.shadowRoot.activeElement;" +
                            "if(e&&e.blur)e.blur();}catch(x){}return '';})()",
                        null,
                    )
                }
                return true
            }
            if (ime) return super.dispatchKeyEvent(event)
        }
        // Deliver remote navigation keys straight to the page so it works even
        // when Flutter's view has taken Android focus back.
        if (pageOwnsRemote && isNavigationKey(event.keyCode)) {
            val webView = pageWebView()
            if (webView != null) {
                if (!webView.hasFocus()) webView.requestFocus()
                val isOk = !pageHandlesRemote && (event.keyCode == KeyEvent.KEYCODE_DPAD_CENTER ||
                    event.keyCode == KeyEvent.KEYCODE_ENTER)
                if (isOk) {
                    // OK is performed by the page script: more reliable than a
                    // synthetic key on TV WebViews, and it tells us when to
                    // raise the keyboard.
                    if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                        webView.evaluateJavascript(
                            "(window.__ytmbOk ? window.__ytmbOk() : '')"
                        ) { value ->
                            val action = value?.trim('"') ?: ""
                            // The page script asks for a genuine tap on custom
                            // elements (home search bar, Music buttons) and for
                            // fullscreen; synthetic clicks are ignored there.
                            if (action.startsWith("fs:") || action.startsWith("tap:")) {
                                val xy = action.substringAfter(':').split(",")
                                if (xy.size == 2) {
                                    tapWebView(
                                        webView,
                                        xy[0].toFloatOrNull() ?: 0.5f,
                                        xy[1].toFloatOrNull() ?: 0.5f,
                                    )
                                }
                            } else if (action == "text") {
                                val imm = getSystemService(INPUT_METHOD_SERVICE)
                                    as android.view.inputmethod.InputMethodManager
                                imm.showSoftInput(webView, 0)
                            }
                        }
                    }
                    return true
                }
                val handled = webView.dispatchKeyEvent(event)
                // The page script normally consumes arrows. If it is not
                // ready yet (first load), keep Up/Down useful by scrolling.
                if (!handled && event.action == KeyEvent.ACTION_DOWN) {
                    when (event.keyCode) {
                        KeyEvent.KEYCODE_DPAD_DOWN -> webView.pageDown(false)
                        KeyEvent.KEYCODE_DPAD_UP -> webView.pageUp(false)
                    }
                }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onPostResume() {
        super.onPostResume()
        pageWebView()?.let { disablePullToRefresh(it) }
    }

    /** True while an on-screen keyboard is accepting text for the WebView. */
    private fun imeVisible(): Boolean {
        return try {
            val imm = getSystemService(INPUT_METHOD_SERVICE)
                as android.view.inputmethod.InputMethodManager
            imm.isAcceptingText
        } catch (_: Exception) {
            false
        }
    }

    /** Sends a real touch at a point given as a fraction of the WebView size. */
    private fun tapWebView(webView: WebView, nx: Float, ny: Float) {
        if (!webView.hasFocus()) webView.requestFocus()
        disablePullToRefresh(webView)
        val px = nx.coerceIn(0f, 1f) * webView.width
        val py = ny.coerceIn(0f, 1f) * webView.height
        val downTime = SystemClock.uptimeMillis()
        val down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, px, py, 0)
        down.source = InputDevice.SOURCE_TOUCHSCREEN
        webView.dispatchTouchEvent(down)
        down.recycle()
        // A small dwell makes Chromium treat this as a tap rather than a
        // fling, which matters for YouTube's custom buttons.
        webView.postDelayed({
            val up = MotionEvent.obtain(
                downTime, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, px, py, 0,
            )
            up.source = InputDevice.SOURCE_TOUCHSCREEN
            webView.dispatchTouchEvent(up)
            up.recycle()
        }, 90)
    }

    private fun isNavigationKey(code: Int) = when (code) {
        KeyEvent.KEYCODE_DPAD_UP,
        KeyEvent.KEYCODE_DPAD_DOWN,
        KeyEvent.KEYCODE_DPAD_LEFT,
        KeyEvent.KEYCODE_DPAD_RIGHT,
        KeyEvent.KEYCODE_DPAD_CENTER,
        KeyEvent.KEYCODE_ENTER -> true
        else -> false
    }

    companion object {
        private const val SPEECH_REQUEST = 4711
    }

    override fun onDestroy() {
        PlaybackService.commandSink = null
        stopService(Intent(this, PlaybackService::class.java))
        super.onDestroy()
    }
}
