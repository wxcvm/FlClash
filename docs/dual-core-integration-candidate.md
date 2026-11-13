# Dual-core integration candidate

This branch combines PRs #60–#65, with actual merge ancestry. It is not a
release and does not change main. Both core source extensions are built in
the candidate CI; the normal production pins and process layout are retained.
Android produces an ARM64 debug APK and the isolated debug APK + instrumentation
pair. Windows builds the installer and portable package with the Mihomo patch,
using the existing setup workflow; sing-box Android libbox is not a Windows
runtime. The Android workflow no longer depends on the expiring official
libbox artifact for this candidate.

Prior complete CI: #60, #61, #63. #64's network and Flutter tests passed before
integration. #62 had a duplicated workflow tail after a successful source
build; removed. #65 failed due to a Go 1.21 clear builtin in a Go 1.20 module;
replaced with a nil map under the lock. Candidate CI must validate both patches,
the Android package, and Windows packages together. No physical device or
real remote node handshake has been executed in this development session.

Candidate build runs from the source pins; for normal builds and release
enablement, evaluate permanent patch delivery separately after validation.
Android isolation remains opt-in and Windows does not gain a sing-box engine
from this integration. Device acceptance guide: android-dual-core-device-acceptance.md.
