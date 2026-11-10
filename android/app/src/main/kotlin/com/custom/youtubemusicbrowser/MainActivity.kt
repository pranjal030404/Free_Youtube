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
                    arrayOf(android.provider.MediaStore.MediaColumns._ID, android.provider.MediaStore.MediaColumns.DISPLAY_NAME, android.provider.MediaStore.MediaColumns.SIZE, android.provider.MediaStore.MediaColumns.DATE_ADDED, android.provider.MediaStore.MediaColumns.MIME_TYPE),
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
                    )
                )
                // Give Android key focus back to Flutter so D-pad navigation
                // works in routes drawn on top of the WebView (Settings).
                // Moves a finished download from the app cache into the
                // phone's shared Movies / Music folder.
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

    /**
     * TV remotes cannot always reach the on-screen toolbar while the WebView has
     * focus. The menu/settings keys open the app's Settings route instead.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_MENU,
                KeyEvent.KEYCODE_SETTINGS,
                KeyEvent.KEYCODE_TV_CONTENTS_MENU -> {
                    deviceChannel?.invokeMethod("openSettings", null)
                    return true
                }
            }
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

    override fun onDestroy() {
        PlaybackService.commandSink = null
        stopService(Intent(this, PlaybackService::class.java))
        super.onDestroy()
    }
}
