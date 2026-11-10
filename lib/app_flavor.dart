/// Which of the two APKs this build is.
///
/// Set by `flutter build apk --flavor mobile|tv` (Flutter passes the flavor
/// as the `FLUTTER_APP_FLAVOR` compile-time constant).
const String _flavor = String.fromEnvironment('FLUTTER_APP_FLAVOR');

/// The phone APK: YouTube's mobile site, full screen, no browser toolbar.
const bool isMobileBuild = _flavor == 'mobile';

/// The TV APK: YouTube's TV interface, driven by the remote.
const bool isTvBuild = _flavor == 'tv';

const String appTitle = isTvBuild ? 'YT Lite TV' : 'YT Lite';
