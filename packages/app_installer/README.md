# Local app_installer compatibility patch

Source: https://github.com/BytesZero/app_installer (version 1.3.1, Apache-2.0).
Android Gradle build drops obsolete jcenter() and old AGP classpath, retains the
original namespace, and removes the deprecated Android manifest package field.
The Dart, Java, iOS and macOS implementations are retained from upstream.

Temporary root pubspec override for Karing integration; return to upstream
when a compatible release passes CI and signed preview packaging.
