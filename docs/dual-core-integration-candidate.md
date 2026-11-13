# Dual-core integration candidate

This branch combines PRs #60–#65 and #67–#70 with actual commit ancestry.
It is not a release and does not change main.

The first joint candidate (30a98608) passed both Android and Windows jobs
in workflow run 43333849583. The combined successor includes:

- #67: Windows DNS / HTTPS path diagnostics with continuous timeline sampling.
- #68: Mihomo recovery extension in regular CI and Windows/Android preview packaging.
- #69: shared pinned sing-box source build for candidate and signed ARM64 preview;
  no dependency on a prior CI artifact.
- #70: native measured node exploration, one-tap apply, and opt-in foreground
  continuous quality selection. No background bandwidth tests; native URLTest
  failure recovery remains independent.

The integrated CI compiles both recovery extensions, runs native ranking and
schedule tests, builds Android debug and isolated instrumentation APKs, and
builds a minified ARM64 release-mode APK using development signing. It checks
that both native libraries and the isolated DEX are packaged. Windows builds
installer and portable packages and parses the PowerShell diagnostic.

Production signing identity, application ID, version code, upstream pins and
default Mihomo process layout are retained. Sing-box is optional and Android
only; Windows does not gain a sing-box runtime. The signed preview workflow
is not executed by candidate CI, and development-signed APKs are not upgrades
to the production app. No real device or remote-node handshake validation has
been performed in this development session.

Device acceptance guide: android-dual-core-device-acceptance.md.
