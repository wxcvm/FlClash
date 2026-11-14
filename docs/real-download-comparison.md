# Real download comparison (Windows and Android)

This is a measurement procedure, not a speed claim. Use the same fixed HTTP(S) file (for example 32 MiB of incompressible data on a server you control), same remote node, same protocol and equivalent core versions/configuration. Use the same physical network when possible. Do not publish credentials or private test URLs. Each three-run 32 MiB case consumes roughly 96 MiB.

Requires Python 3 and curl (Windows: Python and curl.exe on PATH; Android: Python and curl in Termux). No app or DNS configuration is changed.

Windows, explicit local HTTP proxy (substitute the URL, exact byte count, and currently active listener port):

```powershell
python tool/performance/download_benchmark.py --url https://YOUR-TEST-HOST/file.bin --bytes 33554432 --label flclash-mihomo-http --proxy http://127.0.0.1:7890
```

Repeat with v2rayN or Hiddify using the same server/node/protocol and its actual listener. For an OS-route/TUN comparison:

```powershell
python tool/performance/download_benchmark.py --url https://YOUR-TEST-HOST/file.bin --bytes 33554432 --label flclash-tun --os-route
```

Android: copy the script into Termux and run:

```sh
python download_benchmark.py --url https://YOUR-TEST-HOST/file.bin --bytes 33554432 --label flclash-android-vpn --os-route
```

Confirm Termux is included in the active VPN and the file's destination uses the intended proxy rule (inspect the client's connections). OS-route mode disables curl's explicit proxy, not the OS VPN. On Windows, it does not automatically use a system HTTP proxy: use the explicit-proxy case to test that listener. Do not compare an excluded/direct route with a proxied route as if both measured the same node.

Record median and minimum end-to-end bytes/s, per-run total and first-byte time, and failures. Body-only speed is a secondary estimate. Full HTTP 200 and exact file length are required; partial transfers, redirects, and errors are failures. Compare alternating client runs and repeat if network conditions change. A long file measures sustained throughput better than the in-app 2 MiB screening sample. It cannot independently establish protocol or route identity, nor prove the cause of a bottleneck.

For network recovery, repeat with a longer transfer during a controlled Wi-Fi/mobile or sleep/wake transition and record any failure; start a new transfer after the transition. This measures new-transfer recovery, not transparent preservation of the old TCP session. No automatic retry masks failed samples.

Local regression test: `python -m unittest discover -s tool/performance -p 'test_*.py'`.
