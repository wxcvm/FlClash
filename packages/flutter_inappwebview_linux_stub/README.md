# Linux WebView stub

This no-op `flutter_inappwebview_linux` plugin follows the Linux fallback in
[KaringX/karing](https://github.com/KaringX/karing/tree/main/third_party/flutter_inappwebview_linux_stub).
The original upstream source is part of the GPL-3.0-or-later Karing project.

Karing does **not** provide an embedded in-app browser on Linux. Registering a
native no-op plugin avoids compiling a WPE WebKit implementation against
incompatible distribution headers without changing Android, Windows, or macOS.
Do not use this stub if embedded Linux WebView support is later implemented;
replace it with a supported, tested native backend instead.
