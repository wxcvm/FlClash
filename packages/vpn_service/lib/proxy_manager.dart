class ProxyOption {
  const ProxyOption(this.host, this.port);

  final String host;
  final int port;
}

class ProxyManager {
  // 桥接 FlClash 核心 TODO：通过宿主的系统代理所有者处理接口排除。
  void setExcludeDevices(Set<String> devices) {}
}
