// The IPv6 listener table needs winsock2.h, which has to come before the
// windows.h that proxy_plugin.h pulls in.
#include <winsock2.h>
#include <ws2ipdef.h>

#include "proxy_plugin.h"
#include "proxy_snapshot.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <WinInet.h>
#include <Ras.h>
#include <RasError.h>
#include <iphlpapi.h>
#include <stdlib.h>
#include <algorithm>
#include <functional>
#include <map>
#include <string>
#include <vector>

#pragma comment(lib, "wininet")
#pragma comment(lib, "Rasapi32")
#pragma comment(lib, "iphlpapi")

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace
{

constexpr int kMinProxyPort = 1;
constexpr int kMaxProxyPort = 65535;
constexpr wchar_t kProxyServerPrefix[] = L"127.0.0.1:";

std::wstring Utf8ToWide(const std::string& value)
{
  if (value.empty())
  {
    return {};
  }
  const int size = MultiByteToWideChar(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0)
  {
    return std::wstring(value.begin(), value.end());
  }
  std::wstring result(size, L'\0');
  MultiByteToWideChar(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
      result.data(), size);
  return result;
}

std::wstring BuildBypassList(const flutter::EncodableList& bypassDomain)
{
  std::wstring bypassList;
  for (const auto& domain : bypassDomain)
  {
    const auto& value = std::get<std::string>(domain);
    if (!bypassList.empty())
    {
      bypassList += L";";
    }
    bypassList += Utf8ToWide(value);
  }
  return bypassList;
}

bool IsStringList(const flutter::EncodableList& values)
{
  return std::all_of(
      values.begin(), values.end(), [](const auto& value)
      {
        return std::holds_alternative<std::string>(value);
      });
}

bool SetOptionsForConnection(
    INTERNET_PER_CONN_OPTION_LIST& list,
    LPTSTR connection)
{
  list.pszConnection = connection;
  return InternetSetOption(
      nullptr,
      INTERNET_OPTION_PER_CONNECTION_OPTION,
      &list,
      sizeof(list)) != FALSE;
}

bool ForEachConnection(const std::function<bool(LPTSTR)>& visit)
{
  bool success = visit(nullptr);

  DWORD size = 0;
  DWORD count = 0;
  auto ret = RasEnumEntries(nullptr, nullptr, nullptr, &size, &count);
  if (ret == ERROR_BUFFER_TOO_SMALL && count > 0)
  {
    std::vector<RASENTRYNAME> entries(count);
    for (auto& entry : entries)
    {
      entry.dwSize = sizeof(RASENTRYNAME);
    }
    ret = RasEnumEntries(nullptr, nullptr, entries.data(), &size, &count);
    if (ret == ERROR_SUCCESS)
    {
      for (DWORD i = 0; i < count; i++)
      {
        success = visit(entries[i].szEntryName) && success;
      }
    }
    else
    {
      success = false;
    }
  }
  else if (ret != ERROR_SUCCESS)
  {
    success = false;
  }

  return success;
}

bool NotifySettingsChanged()
{
  const bool changed = InternetSetOption(
      nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0) != FALSE;
  const bool refreshed = InternetSetOption(
      nullptr, INTERNET_OPTION_REFRESH, nullptr, 0) != FALSE;
  return changed && refreshed;
}

// One native plugin owns the system proxy for this process. Keep a separate
// snapshot for LAN and each RAS connection rather than resetting all to DIRECT.
std::map<std::wstring, proxy::ProxyOwnership> ownedConnections;

std::optional<proxy::ProxySnapshot> ReadProxySnapshot(LPTSTR connection)
{
  std::vector<INTERNET_PER_CONN_OPTION> options(4);
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  INTERNET_PER_CONN_OPTION_LIST list = {};
  list.dwSize = sizeof(list);
  list.pszConnection = connection;
  list.dwOptionCount = static_cast<DWORD>(options.size());
  list.pOptions = options.data();
  DWORD size = sizeof(list);
  const bool ok = InternetQueryOption(
      nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size) != FALSE;
  proxy::ProxySnapshot snapshot;
  snapshot.flags = options[0].Value.dwValue;
  std::wstring* strings[] = {&snapshot.server, &snapshot.bypass,
                            &snapshot.auto_config};
  for (size_t k = 1; k < options.size(); ++k)
  {
    if (options[k].Value.pszValue != nullptr)
    {
      if (ok) *strings[k - 1] = options[k].Value.pszValue;
      GlobalFree(options[k].Value.pszValue);
    }
  }
  if (!ok) return std::nullopt;
  return snapshot;
}

bool WriteProxySnapshot(LPTSTR connection, proxy::ProxySnapshot snapshot)
{
  std::vector<INTERNET_PER_CONN_OPTION> options(4);
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = snapshot.flags;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = snapshot.server.data();
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue = snapshot.bypass.data();
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[3].Value.pszValue = snapshot.auto_config.data();
  INTERNET_PER_CONN_OPTION_LIST list = {};
  list.dwSize = sizeof(list);
  list.dwOptionCount = static_cast<DWORD>(options.size());
  list.pOptions = options.data();
  return SetOptionsForConnection(list, connection);
}

bool startProxy(const int port, const flutter::EncodableList& bypassDomain)
{
  const auto url = kProxyServerPrefix + std::to_wstring(port);
  const auto bypass = BuildBypassList(bypassDomain);
  const bool optionsApplied = ForEachConnection([&](LPTSTR connection)
  {
    const auto current = ReadProxySnapshot(connection);
    if (!current) return false;  // Never take over without a restorable baseline.
    const std::wstring key = connection == nullptr ? L"" : connection;
    auto it = ownedConnections.try_emplace(
        key, proxy::ProxyOwnership{*current, *current}).first;
    proxy::ProxySnapshot next = *current;
    next.flags = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;
    next.server = url;
    next.bypass = bypass;
    it->second.rememberStart(*current, next);
    const bool ok = WriteProxySnapshot(connection, next);
    // WinINet may normalize its stored values. Only accept a snapshot that
    // still points at the requested proxy, never claim an unrelated server.
    const auto actual = ReadProxySnapshot(connection);
    const bool confirmed = actual &&
        it->second.confirmStart(*actual, PROXY_TYPE_PROXY);
    return ok && confirmed;
  });
  const bool settingsNotified = NotifySettingsChanged();
  return optionsApplied && settingsNotified;
}

bool stopProxy()
{
  const bool restored = ForEachConnection([](LPTSTR connection)
  {
    const std::wstring key = connection == nullptr ? L"" : connection;
    const auto it = ownedConnections.find(key);
    if (it == ownedConnections.end()) return true;
    const auto current = ReadProxySnapshot(connection);
    if (!current) return false;
    if (it->second.stillOwns(*current) &&
        !WriteProxySnapshot(connection, it->second.original))
    {
      return false;
    }
    // If another program changed the settings, leave its configuration alone.
    ownedConnections.erase(it);
    return true;
  });
  const bool settingsNotified = NotifySettingsChanged();
  return restored && settingsNotified;
}

std::optional<int> ProxyPort(const std::wstring& server)
{
  const std::wstring prefix = kProxyServerPrefix;
  if (server.size() <= prefix.size() || server.size() > prefix.size() + 5 ||
      server.compare(0, prefix.size(), prefix) != 0)
  {
    return std::nullopt;
  }
  int port = 0;
  for (size_t i = prefix.size(); i < server.size(); i++)
  {
    if (server[i] < L'0' || server[i] > L'9')
    {
      return std::nullopt;
    }
    port = port * 10 + (server[i] - L'0');
  }
  if (port < kMinProxyPort || port > kMaxProxyPort)
  {
    return std::nullopt;
  }
  return port;
}

template <typename Table>
bool TableHasPort(const std::vector<BYTE>& buffer, int port)
{
  const auto* table = reinterpret_cast<const Table*>(buffer.data());
  for (DWORD i = 0; i < table->dwNumEntries; i++)
  {
    const auto localPort =
        _byteswap_ushort(static_cast<USHORT>(table->table[i].dwLocalPort));
    if (localPort == port)
    {
      return true;
    }
  }
  return false;
}

std::optional<bool> HasTcpListener(ULONG family, int port)
{
  std::vector<BYTE> buffer;
  DWORD size = 0;
  DWORD result = ERROR_INSUFFICIENT_BUFFER;
  for (int attempt = 0; attempt < 3 && result == ERROR_INSUFFICIENT_BUFFER;
       attempt++)
  {
    buffer.resize(size);
    result = GetExtendedTcpTable(
        buffer.empty() ? nullptr : buffer.data(), &size, FALSE, family,
        TCP_TABLE_OWNER_PID_LISTENER, 0);
  }
  if (result != NO_ERROR)
  {
    return std::nullopt;
  }
  return family == AF_INET
             ? TableHasPort<MIB_TCPTABLE_OWNER_PID>(buffer, port)
             : TableHasPort<MIB_TCP6TABLE_OWNER_PID>(buffer, port);
}

// A lookup that fails counts as listening, so a live proxy is never cleared.
bool IsPortListening(int port)
{
  for (const ULONG family : {static_cast<ULONG>(AF_INET),
                             static_cast<ULONG>(AF_INET6)})
  {
    if (HasTcpListener(family, port).value_or(true))
    {
      return true;
    }
  }
  return false;
}

// taskkill /f returns once TerminateProcess has been issued, which is before
// the killed Core has released its listening socket.
bool IsPortReleased(int port)
{
  for (int attempt = 0; attempt < 20; attempt++)
  {
    if (!IsPortListening(port))
    {
      return true;
    }
    Sleep(100);
  }
  return false;
}

bool ClearStaleProxyForConnection(
    LPTSTR connection,
    std::map<int, bool>& releasedPorts)
{
  std::vector<INTERNET_PER_CONN_OPTION> options(2);
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;

  INTERNET_PER_CONN_OPTION_LIST list = {};
  list.dwSize = sizeof(list);
  list.pszConnection = connection;
  list.dwOptionCount = static_cast<DWORD>(options.size());
  list.pOptions = options.data();

  DWORD size = sizeof(list);
  if (InternetQueryOption(
          nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size) ==
      FALSE)
  {
    return false;
  }
  const DWORD flags = options[0].Value.dwValue;
  std::wstring server;
  if (options[1].Value.pszValue != nullptr)
  {
    server = options[1].Value.pszValue;
    GlobalFree(options[1].Value.pszValue);
  }

  const auto port = ProxyPort(server);
  if ((flags & PROXY_TYPE_PROXY) == 0 || !port)
  {
    return true;
  }
  auto [released, unchecked] = releasedPorts.try_emplace(*port, false);
  if (unchecked)
  {
    released->second = IsPortReleased(*port);
  }
  if (!released->second)
  {
    return true;
  }
  INTERNET_PER_CONN_OPTION option = {};
  option.dwOption = INTERNET_PER_CONN_FLAGS;
  option.Value.dwValue = (flags & ~PROXY_TYPE_PROXY) | PROXY_TYPE_DIRECT;
  list.dwOptionCount = 1;
  list.pOptions = &option;
  return SetOptionsForConnection(list, connection);
}

}  // namespace

namespace proxy
{

  bool ClearStaleProxy()
  {
    std::map<int, bool> releasedPorts;
    const bool cleared = ForEachConnection(
        [&releasedPorts](LPTSTR connection)
        {
          return ClearStaleProxyForConnection(connection, releasedPorts);
        });
    const bool settingsNotified = NotifySettingsChanged();
    return cleared && settingsNotified;
  }

  // static
  void ProxyPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarWindows *registrar)
  {
    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "proxy",
            &flutter::StandardMethodCodec::GetInstance());

    auto plugin = std::make_unique<ProxyPlugin>(registrar);

    channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto &call, auto result)
        {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });

    registrar->AddPlugin(std::move(plugin));
  }

  ProxyPlugin::ProxyPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar)
  {
    window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND window, UINT message, WPARAM wparam, LPARAM lparam)
        {
          return HandleWindowProc(window, message, wparam, lparam);
        });
  }

  ProxyPlugin::~ProxyPlugin()
  {
    if (registrar_ != nullptr)
    {
      registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
    }
  }

  bool ProxyPlugin::IsSessionEnding(UINT message, WPARAM wparam)
  {
    return message == WM_ENDSESSION && wparam != FALSE;
  }

  // Shutting Windows down kills the process without running the Dart exit path,
  // so the setting survives into a boot with nothing listening behind it.
  std::optional<LRESULT> ProxyPlugin::HandleWindowProc(
      HWND window, UINT message, WPARAM wparam, LPARAM lparam)
  {
    if (proxy_applied_ && IsSessionEnding(message, wparam))
    {
      proxy_applied_ = !stopProxy();
    }
    return std::nullopt;
  }

  void ProxyPlugin::HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    if (method_call.method_name() == "StopProxy")
    {
      const bool stopped = stopProxy();
      proxy_applied_ = proxy_applied_ && !stopped;
      result->Success(stopped);
    }
    else if (method_call.method_name() == "StartProxy")
    {
      auto *arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
      if (arguments == nullptr)
      {
        result->Error("bad_args", "StartProxy requires argument map");
        return;
      }
      auto portIt = arguments->find(flutter::EncodableValue("port"));
      auto bypassDomainIt = arguments->find(flutter::EncodableValue("bypassDomain"));
      if (portIt == arguments->end() || bypassDomainIt == arguments->end())
      {
        result->Error("bad_args", "StartProxy requires port and bypassDomain");
        return;
      }
      auto *port = std::get_if<int>(&portIt->second);
      auto *bypassDomain = std::get_if<flutter::EncodableList>(&bypassDomainIt->second);
      if (port == nullptr || bypassDomain == nullptr)
      {
        result->Error("bad_args", "StartProxy argument types are invalid");
        return;
      }
      if (*port < kMinProxyPort || *port > kMaxProxyPort)
      {
        result->Error("bad_args", "StartProxy port must be between 1 and 65535");
        return;
      }
      if (!IsStringList(*bypassDomain))
      {
        result->Error(
            "bad_args", "StartProxy bypassDomain must contain only strings");
        return;
      }
      // A start that reports failure can still have written the setting.
      proxy_applied_ = true;
      result->Success(startProxy(*port, *bypassDomain));
    }
    else
    {
      result->NotImplemented();
    }
  }
} // namespace proxy
