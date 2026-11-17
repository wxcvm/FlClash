# Android sing-box version-compatibility experiment

This workflow tests source compatibility **without changing the normal FlClash
APK, built-in Mihomo, or the pinned recovery-enabled sing-box 1.14.4 build**.

| Candidate | Immutable commit | What is checked |
| --- | --- | --- |
| Official stable 1.14.4 | `c005f35300ce76427dc285481ec5695f5b179cd2` | Base config validation |
| KaringX/sing-box `dev-next` | `73603b201141ee9bab41af76995808ccfc45209f` | Base config validation (does **not** establish which libbox Karing's current APK uses) |
| Official 1.15.0-alpha.13 | `824dbcfb4dd0a95921840b1737b950cde590241e` | Base and 1.15 certificate-pin config validation, clean upstream libbox build, compilation into FlClash's optional Android service/APK |

The source-only checks use fictional TEST-NET IPs and synthetic credentials.
They check JSON schema and outbound construction **not remote handshake or
actual traffic**. The 1.15 fixture uses a synthetic 32-byte certificate
SHA-256 encoded in base64. Mihomo's certificate `fingerprint` uses hex
SHA-256 over the DER certificate, so a production converter must decode hex
and re-encode to base64 **without dropping or changing certificate pinning**.

The official 1.14.4 recovery extension in `recovery/apply.py` only accepts
its exact pinned commit. We do not attempt to apply that patch to 1.15 or
claim the alpha APK has FlClash's custom recovery implementation.

A successful Android build is only a debug candidate. It is **not a release**
and must pass real Android VPN start/stop, TUN routing, TCP/UDP forwarding,
DNS, Hysteria2 certificate verification, WebSocket/Reality and handover checks
before being offered as a core choice. No live subscription credentials are
placed in the repository or CI artifacts.

Karing's repository is GPL-3.0-or-later with additional naming conditions.
Do not copy Karing code/assets into FlClash just because the fork compiles;
review the exact change and its license first.
