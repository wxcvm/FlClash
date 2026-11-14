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
