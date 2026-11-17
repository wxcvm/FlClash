# Compare download and upload throughput on Windows and Android

FlClash's small in-app speed probes rank nodes; they do **not** measure
sustained transfer performance or upload capacity. This read-only diagnostic
measures real HTTP transfers through an explicitly chosen route.

## Compare the same path and server

Use the **same remote server**, file size, and time window for every client.
The server should be one you trust and that has enough bandwidth to avoid
becoming the bottleneck. Upload requires an HTTP endpoint that accepts the
full synthetic binary request body via POST (or `--method PUT`) and returns
HTTP 200, 201 or 204. The tool creates random test bytes locally, not your
photos, subscription files, keys, or personal data.

Windows PowerShell examples (replace the example endpoints with your own):

```powershell
# FlClash explicit mixed proxy (one selected proxy node)
py -3 tool/performance/download_benchmark.py --mode download --url "https://test.example.net/32MiB.bin" --bytes 33554432 --proxy "http://127.0.0.1:7890" --label "FlClash-proxy-DL"
py -3 tool/performance/download_benchmark.py --mode upload --url "https://test.example.net/upload" --bytes 16777216 --proxy "http://127.0.0.1:7890" --label "FlClash-proxy-UL"

# No application-level proxy. Windows TUN and AdGuard may still intercept.
py -3 tool/performance/download_benchmark.py --mode download --url "https://test.example.net/32MiB.bin" --bytes 33554432 --os-route --label "Windows-route-DL"
py -3 tool/performance/download_benchmark.py --mode upload --url "https://test.example.net/upload" --bytes 16777216 --os-route --label "Windows-route-UL"
```

Repeat for Karing's actual explicit proxy port when its desktop proxy listener
is active, and for the other client only after avoiding conflicting system
proxies or VPN owners. The `--proxy` option bypasses environmental proxy
defaults but **does not** bypass a Windows TUN. `--os-route` removes the
application-level proxy, not any active system VPN.

On Android you may run the same Python command in a compatible shell
(e.g. Termux) if Python and curl are available; no automated app switching
or Android VPN installation is performed.

## Interpret the JSON

- `bytes_per_second`: full request/response time including connection,
  upload/download and server response. Divide by 1,000,000 for MB/s.
- `body_bytes_per_second`: download transfer excluding time-to-first-byte,
  or curl's reported upload transmission speed. This is **not** an independent
  verified receiver-side speed.
- `successes` / `failures`: incomplete responses, HTTP errors and curl
  timeouts are **not** treated as valid speed samples.
- Compare median and failures. A fast but frequently failing connection is
  not better than a steady one.

Use download and upload separately, preferably alternating the order of
the clients to minimize bias from server congestion and peering changes.
With the **same selected node**, compare explicit proxy versus OS/TUN route.
If only TUN is slower, investigate TUN processing, virtual NIC, DNS and
interacting filters. If both are slow but direct/Karing is fast, compare
protocol config, transport (TCP vs QUIC), congestion and DNS/route selection.
If all paths are slow, check the local radio/Wi-Fi, server capacity and
remote bottlenecks first.

Do not upload traffic captures or private proxy credentials. Avoid sharing
raw reports when the test host or proxy port identifies a private network.
The script performs no configuration edits, route changes or speed-limit
tuning. Generating the synthetic upload payload happens before timed samples.
Uploads consume real traffic and should be run with the user's chosen
sample size.
