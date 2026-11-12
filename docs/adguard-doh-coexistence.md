# AdGuard and private DoH coexistence (Windows)

If AdGuard Automatic proxy works until its DNS protection is enabled, isolate DNS from routing before changing proxy settings. Keep your existing subscription and make a backup. The cause depends on the actual AdGuard DNS endpoint, profile, and Windows network.

1. Keep AdGuard DNS enabled and keep the current FlClash TUN/system-proxy settings unchanged. In FlClash DNS queries, inspect the hostname of the private DoH server and any failures. The viewer shows encrypted resolver scheme/host/port, not account paths or query credentials.
2. If FlClash uses Fake-IP in blacklist mode, add only the DoH endpoint's exact hostname to the existing Fake-IP filter (keep all previous entries). You may paste its URL into that filter; the app normalizes it to the hostname. Do not add the entire DNS provider's domain suffix unless necessary. In rule/whitelist mode keep the existing policy and use its appropriate syntax rather than converting it blindly.
3. If the hostname still fails, check whether FlClash's DNS upstream is `system://` and AdGuard is intercepting system DNS. Temporarily disable only the optional Append system DNS setting, not AdGuard DNS protection, and retest. Do not remove an explicitly required system resolver without checking the profile.
4. Check the actual route of the DoH server. A Fake-IP exclusion returns a real address but does not force direct routing. If a policy or an application proxy loop is confirmed, choose the appropriate explicit routing rule for that endpoint in your environment; don't broadly bypass the DNS provider or force all DNS to DIRECT.
5. Clear FlClash's DNS cache after changing the filter and repeat the same test with the same network. Check Wi-Fi reconnection, browser DNS and proxy-node hostname resolution separately.

An exact endpoint hostname does not expose a private account path. Never paste the private DoH URL or an unredacted configuration in a public issue. These controls are not proof of compatibility with a particular AdGuard installation; verify on the actual Windows machine.
