# Android preview signing

The Windows and Android preview workflow publishes the Android ARM64 APK as a separate app (`com.follow.clash.dev`) so it does not replace the official app. The first preview used a temporary CI debug key. To enable reliable in-place upgrades, configure a dedicated long-lived signing key once. Do not commit the private key or its passwords.

## Create and configure the key

On a trusted computer with a JDK and authenticated GitHub CLI:

```bash
keytool -genkeypair -keystore flclash-preview.jks -storetype PKCS12 -alias flclash-preview -keyalg RSA -keysize 3072 -validity 10000
base64 -w0 flclash-preview.jks | gh secret set PREVIEW_KEYSTORE --repo wxcvm/FlClash
gh secret set PREVIEW_KEY_ALIAS --repo wxcvm/FlClash --body flclash-preview
gh secret set PREVIEW_STORE_PASSWORD --repo wxcvm/FlClash
gh secret set PREVIEW_KEY_PASSWORD --repo wxcvm/FlClash
````

For PKCS12, use the same store and key password. On Windows PowerShell, replace the base64 command with `[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path 'flclash-preview.jks'))) | gh secret set PREVIEW_KEYSTORE --repo wxcvm/FlClash`.

Back up the keystore and password separately in a safe place. Never paste either into an issue, pull request, or public chat. The four Actions secrets may also be entered through repository Settings → Secrets and variables → Actions.

After the signing key is first used, export profiles/settings from any earlier debug-signed preview before uninstalling it once, then install the new signed APK and restore them. Future APKs signed with the same key and increasing preview version codes can update it in place. The official app remains separate.

If the secrets are absent, the workflow still publishes an explicitly marked debug-signed preview, which is suitable for temporary testing only. Do not assume it can update a previous installation.
