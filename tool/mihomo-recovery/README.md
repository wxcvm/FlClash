# Mihomo failure recovery experiment

Pinned FlClash Mihomo submodule 024245dc72bc92f48237f865119afe0cd53ac9e6. The source extension fixes
the existing group failure-health-check path instead of adding another poller.
It preserves configured max-failed-times and timeout window (default 5 and
5000ms), the immediate connection-refused path, provider test URLs, tolerance
and selections. TCP and UDP use separate same-node streaks. Successful
non-handshake TCP, initial write handshake success and UDP setup reset the
corresponding streak; cancellation and unsupported operations are ignored.
A single admitted health check per group with a five-second minimum interval
prevents bursts of duplicate checks. Fallback and LoadBalance UDP failures
now feed the same existing provider check. No traffic replay or direct fallback.

The experimental branch applies the pinned patch before building the actual
Mihomo wrapper for Windows and Android, runs the gate race tests and real
outboundgroup package tests. It does not change the production submodule pin
or normal local build. To reproduce locally, run
python tool/mihomo-recovery/apply.py core/Clash.Meta in a clean checkout
then build normally. The Windows artifact is a core executable, not a full
installer. Real traffic, protocol handshakes and failure/recovery under load
still require device testing. Provider health checks can be shared across
groups and use their own scheduling; no instantaneous switch guarantee.
