# Windows AdGuard / FlClash DNS coexistence

This addresses one narrow bootstrap case, not every possible third-party DNS
interception conflict. In generated Mihomo Fake-IP blacklist configurations,
encrypted DNS resolver hostnames explicitly present in the active DNS section
are added as exact real-IP exclusions. When the blacklist is omitted, the
pinned Mihomo default Windows connectivity-check exclusions are retained.
An explicit empty or custom blacklist stays the user's baseline. An omitted
nameserver also accounts for the core's implicit DoH hostname.
Existing rules, upstream URLs, private
paths, nameserver ordering and policy are retained. IP literals are ignored;
whitelist and rule modes are not changed. No subscription file is rewritten.
If AdGuard uses a private DoH endpoint which does not appear in FlClash, its
hostname is not discovered automatically.

## Follow AdGuard's configured DNS from FlClash (opt-in)

On Windows, open **Advanced → Network → Follow Windows / AdGuard DNS**
(高级设置 → 网络 → 跟随 Windows / AdGuard DNS). The switch is off
by default. It stores a separate preference; the original FlClash DNS fields,
subscriptions and AdGuard private DoH URLs are **not overwritten or read**.
Turning it off rebuilds the original effective DNS configuration. When Mihomo
is running, switching the option reapplies its profile; this can briefly
interrupt active connections. If the reload fails, FlClash restores the
previous preference and retries the previous effective profile. If even the
recovery fails, the interface reports that the running configuration could
not be restored rather than claiming the toggle took effect.

With the switch on, the effective Mihomo DNS uses `system://` for general,
proxy-node and direct-traffic resolution. Any existing
`nameserver-policy` and `proxy-server-nameserver-policy` selectors remain
intact but their upstream values use `system://`, and the previous
`fallback` upstream pool is suppressed. Fake-IP mode, exclusions, and routing
rules remain configured as before; the subscription files are not rewritten.
When Mihomo TUN is enabled, this mode also writes `tun.dns-mode: disabled`
and `tun.dns-hijack: []` **only into the generated configuration**. This
prevents the TUN from replacing Windows' DNS server or redirecting the
AdGuard-bound port 53 requests straight back into Mihomo.
The DNS bootstrap `default-nameserver` is also set to `system://`, and
`dns.respect-rules` is set to `false` in the generated config while the
option is enabled. This prevents stale public UDP resolvers and DNS-to-proxy
bootstrap loops: the proxy hostname must resolve before the proxy can carry
traffic. The original bootstrap and routing settings remain in the saved
profile and return when this option is disabled. The system resolver can still
fail if AdGuard filters or upstream DNS settings reject the queried hostname;
a successful system lookup alone does not prove private DoH interception.

`system://` means **Mihomo uses Windows system DNS servers**; it does not
read AdGuard's private encrypted DNS URL. AdGuard for Windows DNS protection
must be enabled and must actually intercept that process's DNS traffic for
its selected resolver to be used. This cannot be inferred from the Windows
adapter nameserver alone, nor verified by a successful `nslookup` alone.
FlClash's Windows **one-click network diagnostics** additionally queries a
fresh `flclash-check-<timestamp>.example.com` hostname when this mode is
enabled and Mihomo is running. The domain usually has no DNS records:
an NXDOMAIN response is expected, not a failure. Find the **exact hostname**
printed in the diagnostic report in AdGuard's DNS query log; repeating the
diagnostic uses a new name to avoid a cached result. A successful ordinary
`example.com` lookup by itself still cannot prove AdGuard ownership.
No AdGuard credentials or private DNS URLs are read.

Confirm the query appears in AdGuard's DNS query log, especially with
FlClash TUN/Fake-IP enabled. Disabling TUN DNS hijacking means that applications
using Windows DNS may receive real addresses rather than Mihomo synthetic
Fake-IPs; TUN IP connections without a sniffable domain may match IP rules
instead of DNS-derived domain rules. Existing rule lists are unchanged.
Use the prior DNS mode if those routing semantics are required. Do not claim AdGuard ownership merely because
the system resolver succeeds. Avoid pointing Windows DNS back to a listener
that loops through Mihomo's own `dns-hijack`; if queries stall or cycle,
turn this switch off and use the original DNS configuration.

This option affects the generated **Mihomo** config. Independent sing-box,
Xray and Hysteria native configurations still own their own DNS and are not
silently modified.

## Diagnose without changing system settings

Run `tool/windows/check-dns-path.ps1` from PowerShell while the issue is
reproducible. Supply only the DoH **hostname**, never the full private URL.
Example (replace the example hostname with your actual DNS host):

    powershell -NoProfile -ExecutionPolicy Bypass -File tool/windows/check-dns-path.ps1 -ResolverHost private.example -MixedPort 7890

The script shows Windows system DNS answers for that hostname, classifies the
configured Fake-IP IPv4 range (default 198.18.0.0/15), and compares a direct
curl HTTPS request (no application proxy) with an explicit FlClash HTTP-proxy
request to the same public test destination. "Direct" still traverses TUN or
AdGuard if enabled; it does not bypass them. The report does not expose the
private DoH URL or credentials. It is read-only except for normal DNS/HTTPS
traffic. It does not change DNS, routes, certificates, AdGuard or proxy settings.

A synthetic DNS answer alone is not proof of failure: Fake-IP is expected for
ordinary routed domains. If the resolver hostname itself is synthetic and
only the explicitly proxied request succeeds, investigate resolver bootstrap
and DNS ownership. If the hostname is real but both requests fail, inspect
the configured route, DNS transport and proxy endpoint. Use the same test
before/after switching only AdGuard DNS, with FlClash VPN retained, to isolate
the conflict. Do not disable AdGuard overall protection as a permanent fix.

For an external resolver not in the profile, add its exact hostname to the
existing Fake-IP blacklist if diagnosis confirms the need. Do not paste the
secret path/query, add broad wildcard exclusions, or route it DIRECT without
checking the intended privacy policy. FlClash cannot control AdGuard's own
DNS cache or guarantee that its DNS interception will coexist with TUN.

## Record recovery across a network change

Use timeline mode to collect before/after samples while manually reproducing
the problem, with FlClash retained and one network variable changed at a time:

    powershell -NoProfile -ExecutionPolicy Bypass -File tool/windows/check-dns-path.ps1 -ResolverHost private.example -MixedPort 7890 -Samples 12 -IntervalSeconds 2 > recovery.json

Start with a working baseline, switch Wi-Fi / Ethernet or toggle only AdGuard
DNS, then leave the new state in place while sampling continues. Repeat with
sleep/resume if needed. The script never changes network settings itself.
Each sample records UTC start/end times, DNS completion time, and separate
start/end times, curl exit code, HTTP status and duration for both paths.
A successful public HTTPS probe needs curl exit 0 and the expected status
(204 for the default URL); a listener alone does not prove connectivity.

The two HTTPS probes run sequentially, with a 12-second timeout each, and
the interval is a pause after the sample, not a fixed sampling period.
Use the observed timestamps to bound recovery rather than treating sample
count as seconds. This is a diagnostic comparison, not proof of proxy exit
IP, remote protocol handshakes, or exact recovery latency. Keep the report
local if the resolver hostname or DNS answers are private.

## Inspect the actual Windows route

Add `-RouteDetails` to either invocation above when TUN appears enabled
but applications cannot connect. For each HTTPS request the report includes
curl's actual connected peer IP (if available), the best Windows route to
that IP at observation time, interface index/alias, destination prefix,
next hop and route metric. If no connection succeeds, the report also lists
current DNS destination candidates and their routes; these are not observed
connections. The explicit proxy's peer is the loopback proxy, not its remote
exit. Compare the no-application-proxy result against the intended TUN
interface and the explicit proxy result against loopback. Route details are
snapshots after the request, not a packet capture, and can change during
handover. The diagnostic does not repair or modify the route table.

    powershell -NoProfile -ExecutionPolicy Bypass -File tool/windows/check-dns-path.ps1 -ResolverHost private.example -MixedPort 7890 -RouteDetails -Samples 5

Keep this report local if interface names or addresses are sensitive.
No extra software or administrator permissions are requested by the script.

## Distinguish a lost TUN route from a live listener

The Windows one-click diagnosis now inspects the effective IPv4 route for
`198.18.0.8` (outside the standard `198.18.0.1/30` TUN interface subnet),
compared with that standard TUN interface address. It uses a **read-only**
`route print -4` snapshot, selects the longest matching route and then the
lowest route metric. If the TUN interface's own link route still exists but
`198.18.0.8` chooses another interface, it flags **possible TUN route
coverage loss**, even if the application and listener still report running.

This is only a standard Fake-IP sample. A healthy match cannot verify all
aggregate prefixes, and a customized Fake-IP range or missing reference route
is explicitly reported as inconclusive. It does not reinstall routes or
restart TUN, because a transient `default interface lost by monitor` log
by itself is not proof of an absent Windows route. Rerun diagnostics a few
minutes after a network handover to identify delayed disappearance.

Upstream discussion: https://github.com/MetaCubeX/mihomo/issues/3411 .
Its route-loss scenario is relevant for investigation, not proof that an
individual FlClash device has the same fault.

## Mihomo reconnect fix

The pinned core's ClearAll already synchronously resets resolver clients, including
policy-only and bootstrap DNS transports. FlClash no longer follows that operation
with a second asynchronous resolver reset on a network-change notification. This
prevents the delayed reset from closing newly opened resolver connections after
handover. Any previous network-health result is invalidated on passive desktop
network changes as well as explicit recovery. Fake-IP mappings remain untouched.
This does not change the current route or restart the VPN on a passive event.

## Sleep / same-transport reconnect

The system wake callback waits two seconds, then asks the existing core health
probe to verify the configured test URL on the actual route. A same-transport
Windows connectivity event also verifies after the passive resolver reset.
A reachable endpoint or any HTTP response preserves established connections;
only a fresh final DNS/route failure after the core's two attempts requests
one connection and outbound recovery. A stopped/suspended run, newer network
event or changed host epoch invalidates the pending decision. An overlapping
handover verification cannot authorize a second teardown. This does not
change Windows DNS settings, AdGuard settings or the selected route. An
endpoint-specific failure is not proof that the whole internet is offline.
