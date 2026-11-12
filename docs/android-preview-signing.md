# Android release and preview signing

Android release and preview APKs use the same application ID: `com.follow.clash`. All published fork builds must use the same long-lived signing key. Never publish an APK signed with a temporary debug key.

## Configure the shared key once

If a release key already exists, reuse it. Do not generate a new one for an existing installation. Configure the four repository Actions secrets used by the release build:

- `KEYSTORE`: base64-encoded keystore
- `KEY_ALIAS`
- `STORE_PASSWORD`
- `KEY_PASSWORD`

If no release key exists, generate one on a trusted computer with a JDK and store it securely:

```bash
keytool -genkeypair -keystore flclash-release.jks -storetype PKCS12 -alias flclash-release -keyalg RSA -keysize 3072 -validity 10000
base64 -w0 flclash-release.jks | gh secret set KEYSTORE --repo wxcvm/FlClash
gh secret set KEY_ALIAS --repo wxcvm/FlClash --body flclash-release
gh secret set STORE_PASSWORD --repo wxcvm/FlClash
gh secret set KEY_PASSWORD --repo wxcvm/FlClash
```

For PKCS12, use the same store and key password. On Windows PowerShell, replace the base64 command with `[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path 'flclash-release.jks'))) | gh secret set KEYSTORE --repo wxcvm/FlClash`.

If a dedicated preview key was previously configured, reuse it as the shared release key only if it is the intended long-term signing identity. Do not rotate the key between releases. Keep a secure backup; do not commit the keystore or passwords.

## Updating without migration

- An existing official upstream installation can be updated in place only if its signing certificate matches the fork APK. The upstream signing key is not assumed to be available.
- Export profiles and settings from an old `com.follow.clash.dev` preview, install the new `com.follow.clash` build, and restore once. If an existing `com.follow.clash` installation has a different certificate, back up before replacing it.
- Future fork preview and stable APKs with the same package and certificate can update in place when their Android version code is not lower than the installed code. Preview codes are derived from the pubspec build number and the release run/attempt. A future stable release must use a build number greater than the highest published preview code; do not reset the build number when switching channels.

The preview workflow fails if the shared signing secrets are absent, verifies the APK signature, application ID and version, and records the certificate fingerprint in the release notes. Historical separate-package builds must not be overwritten with a new application identity.

## Published upgrade identity

Each new dual-platform release publishes `android-build.json` with the actual verified certificate SHA-256, Android versionCode, application ID, source commit and release tag. Its hash is included in SHA256SUMS. The publisher rejects a different certificate or a versionCode that does not exceed every previous published unified APK. Only the two historical .dev releases are excluded. A future stable publisher must reuse this gate and the same signing identity; the current workflow still creates previews only.

Android builds are now artifact-only reusable jobs. Do not backfill or replace an existing release APK: publish a new tag with a higher versionCode instead. The original official app requires one backup/reinstall/restore if its certificate differs. A rollback must be rebuilt under a new higher versionCode; an older APK is not an in-place rollback.
