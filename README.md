# YouTube Music Browser

A lightweight Flutter/Android shell around `music.youtube.com` and
`www.youtube.com`, built on `flutter_inappwebview`.

## Features

- Two separate apps built from this one project (Android product flavors):
  - **YT Lite** (`--flavor mobile`, id `com.custom.youtubemusicbrowser.mobile`):
    YouTube's mobile site full screen, with no browser toolbar. BACK at the
    first page shows "Press back again to exit" with a **MENU** button
    (ad blocking, Google sign-in, YouTube Music, clear data).
  - **YT Lite TV** (`--flavor tv`, id `com.custom.youtubemusicbrowser`):
    YouTube's TV interface for the remote; see "Android TV" below.
- Google sign-in supported from every entry point, including YouTube Music's
  popup-based sign-in. The popup is loaded in the main WebView so the session
  cookies are shared.
- Downloads (phone app): on a watch or Shorts page a round download button
  appears at the bottom right. "Download video" saves a 360p MP4 to
  `Movies/YT Lite`; "Download song" saves the audio (M4A) to `Music/YT Lite`.
  360p is the only quality YouTube serves as one file with sound.
  **Downloads** (BACK at the first page → MENU, or "My downloads" in the
  download sheet) lists saved videos and songs; tap one to play it in the
  phone's player, or delete it. Uses the
  `youtube_explode_dart` package; keep the app open while a download runs.
- Dark mode (phone app): **MENU → Theme** = System / Dark / Light. The app
  restarts its screen to apply it; YouTube's own dark switch is set too.
- In-page ad skipping (video ads, feed/banner ad slots) and background audio.
- The TV app has a leanback launcher entry, D-pad focus handling and
  automatic focus of the Google sign-in fields.

## Android TV

On a TV the app opens YouTube's own TV interface (`youtube.com/tv`, served via
a TV user agent), so the remote, player controls, search and sign-in
(QR / `yt.be/activate`) behave like the official TV app. YouTube Music and
Google sign-in keep the regular user agent. BACK is sent to the page as Escape
(press it twice at the home screen to exit); MENU opens Settings. The ad
skipper is injected on every page, including the TV interface.

TV performance: AV1/VP9 are hidden from the page on TVs so YouTube serves
H.264, which low-end TV chips decode in hardware (AV1 was decoded in software:
slow starts, dropped frames, memory swapping). Sponsored tiles are removed from
feed/search data before the page sees them (the TV interface loads data with
XHR + JSON.parse, so the pruning runs in the JSON.parse hook; it costs ~3-13 ms
per response on the TV).

Startup: the user agent is built natively from the installed WebView version
instead of `getDefaultUserAgent()`, which loaded Chromium before the first
frame (first frame 1.2-2.1 s -> 0.6-1.2 s on a TCL Android 11 TV).

For a 32-bit ARM TV build a small APK with:
`flutter build apk --release --flavor tv --target-platform android-arm`
(about 15 MB).

## Performance

- Startup work (settings, device info, WebView user agent) runs in parallel
  instead of one await after another.
- Loading progress updates only repaint the thin progress bar; they no longer
  rebuild the toolbar or WebView widget.
- History events only trigger a rebuild when the Back/Forward state changes.
- Native WebView content blockers are disabled on purpose: the Android plugin
  sends an extra HEAD request for every sub-resource to guess its MIME type,
  which roughly doubles page-load traffic. Ads are removed in-page instead.
- The in-page ad skipper checks once per second, and only rewrites player API
  responses (large browse/search responses are left untouched).
- Notification permission is requested when playback starts, not during app
  launch.

## Build

The Flutter SDK is expected at `/home/pranjal/development/flutter`.

```sh
export PATH="$PATH:/home/pranjal/development/flutter/bin"
flutter pub get
flutter analyze
flutter test
flutter build apk --release --flavor mobile --target-platform android-arm,android-arm64
flutter build apk --release --flavor tv --target-platform android-arm
```

The outputs are `build/app/outputs/flutter-apk/app-mobile-release.apk` and
`app-tv-release.apk`. Copies are kept in the project root as
`YTLite-mobile.apk` and `YTLite-tv.apk`. A flavor is always required.

## Signing in

Open **Settings → Google sign-in** (MENU on a TV remote; BACK then MENU
on a phone), or use
the normal sign-in button on the YouTube/YouTube Music page. If Google rejects
the embedded browser, the app retries the page once with a desktop user agent.
# Free_Youtube
