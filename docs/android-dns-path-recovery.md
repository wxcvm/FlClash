# Android DNS path recovery

The Android platform monitor includes Private DNS active state, server hostname
and search domains in its path identity. DNS server order remains meaningful;
address and route list order is canonicalized. A suspended or unavailable
underlying NIC invalidates the current DNS epoch without discarding its
candidate Network handle. Recovery on that same handle republishes the path.
Fresh Android callbacks reset the bounded NIC retry budget. In-flight raw DNS
queries on the old epoch are canceled as before.

The pinned sing-box DNS client already keys environment-aware transports by
network environment and transport environment; its HTTPS transport resets its
connection pool on network reset. FakeIP transport maps synthetic addresses
independently of regular response caching. This change intentionally does not
purge FakeIP mappings, disable global DNS cache, override private DoH endpoints,
or change split-DNS policy. Android's raw DNS transport is not a guarantee that
queries use a user-selected remote DoH resolver. The actual VPN DNS/HTTPS
handover test remains required, including private DNS changes on a real device.
