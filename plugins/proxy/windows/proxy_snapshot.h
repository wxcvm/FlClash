#ifndef FLUTTER_PLUGIN_PROXY_SNAPSHOT_H_
#define FLUTTER_PLUGIN_PROXY_SNAPSHOT_H_

#include <string>

namespace proxy {

// Only restore a connection if its current settings are still ours.
// Another proxy manager may have taken ownership since our last start.
struct ProxySnapshot {
  unsigned long flags = 0;
  std::wstring server;
  std::wstring bypass;
  std::wstring auto_config;

  bool operator==(const ProxySnapshot& other) const {
    return flags == other.flags && server == other.server &&
           bypass == other.bypass && auto_config == other.auto_config;
  }
};

struct ProxyOwnership {
  ProxySnapshot original;
  ProxySnapshot applied;

  bool stillOwns(const ProxySnapshot& current) const {
    return current == applied;
  }

  void rememberStart(const ProxySnapshot& current,
                     const ProxySnapshot& next) {
    if (!stillOwns(current)) original = current;
    applied = next;
  }
};

}  // namespace proxy

#endif
