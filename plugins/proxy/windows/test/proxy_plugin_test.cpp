#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>

#include <memory>
#include <string>
#include <variant>

#include "proxy_plugin.h"
#include "proxy_snapshot.h"

namespace proxy {
namespace test {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

}  // namespace

TEST(ProxyOwnership, RepeatedStartPreservesOriginalProxyAndPac) {
  const ProxySnapshot original{5, L"127.0.0.1:3128", L"localhost",
                               L"https://example.test/proxy.pac"};
  const ProxySnapshot first{3, L"127.0.0.1:7890", L"<local>", original.auto_config};
  const ProxySnapshot second{3, L"127.0.0.1:8090", L"<local>", original.auto_config};
  ProxyOwnership owner{original, original};
  owner.rememberStart(original, first);
  owner.rememberStart(first, second);
  EXPECT_TRUE(owner.original == original);
  EXPECT_TRUE(owner.stillOwns(second));
}

TEST(ProxyOwnership, DoesNotRestoreOverExternalChanges) {
  const ProxySnapshot original{1, L"", L"", L""};
  const ProxySnapshot ours{3, L"127.0.0.1:7890", L"<local>", L""};
  const ProxySnapshot external{3, L"127.0.0.1:3128", L"localhost", L""};
  ProxyOwnership owner{original, ours};
  EXPECT_FALSE(owner.stillOwns(external));
  owner.rememberStart(external, ours);
  EXPECT_TRUE(owner.original == external);
  EXPECT_TRUE(owner.stillOwns(ours));
}

TEST(ProxyOwnership, SameServerWithChangedPacOrBypassIsNotOwned) {
  const ProxySnapshot ours{3, L"127.0.0.1:7890", L"<local>", L""};
  ProxyOwnership owner{ProxySnapshot{}, ours};
  auto current = ours;
  current.bypass = L"example.test";
  EXPECT_FALSE(owner.stillOwns(current));
  current = ours;
  current.auto_config = L"https://example.test/proxy.pac";
  EXPECT_FALSE(owner.stillOwns(current));
}

TEST(ProxyOwnership, StartRequiresEnabledRequestedProxy) {
  const ProxySnapshot original{1, L"", L"", L""};
  const ProxySnapshot requested{3, L"127.0.0.1:7890", L"<local>", L""};
  ProxyOwnership owner{original, requested};
  auto actual = requested;
  actual.flags = 1;
  EXPECT_FALSE(owner.confirmStart(actual, 2));
  actual = requested;
  actual.server = L"127.0.0.1:3128";
  EXPECT_FALSE(owner.confirmStart(actual, 2));
  EXPECT_TRUE(owner.applied == requested);
  actual = requested;
  actual.bypass = L"<local>;localhost";
  EXPECT_TRUE(owner.confirmStart(actual, 2));
  EXPECT_TRUE(owner.stillOwns(actual));
  EXPECT_TRUE(owner.original == original);
}

TEST(ProxyPlugin, UnknownMethodIsNotImplemented) {
  ProxyPlugin plugin;
  bool not_implemented = false;
  plugin.HandleMethodCall(
      MethodCall("unknown", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          nullptr, nullptr,
          [&not_implemented]() { not_implemented = true; }));

  EXPECT_TRUE(not_implemented);
}

TEST(ProxyPlugin, StartProxyRejectsMissingArguments) {
  ProxyPlugin plugin;
  std::string error_code;
  plugin.HandleMethodCall(
      MethodCall("StartProxy", std::make_unique<EncodableValue>(EncodableMap())),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](
              const std::string& code,
              const std::string& message,
              const EncodableValue* details) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "bad_args");
}

TEST(ProxyPlugin, StartProxyRejectsInvalidPort) {
  ProxyPlugin plugin;
  std::string error_code;
  EncodableMap arguments = {
      {EncodableValue("port"), EncodableValue(70000)},
      {EncodableValue("bypassDomain"), EncodableValue(EncodableList())}};

  plugin.HandleMethodCall(
      MethodCall(
          "StartProxy",
          std::make_unique<EncodableValue>(std::move(arguments))),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](
              const std::string& code,
              const std::string& message,
              const EncodableValue* details) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "bad_args");
}

TEST(ProxyPlugin, StartProxyRejectsNonStringBypassDomain) {
  ProxyPlugin plugin;
  std::string error_code;
  EncodableList bypass_domain = {
      EncodableValue("localhost"),
      EncodableValue(1)};
  EncodableMap arguments = {
      {EncodableValue("port"), EncodableValue(7890)},
      {EncodableValue("bypassDomain"),
       EncodableValue(std::move(bypass_domain))}};

  plugin.HandleMethodCall(
      MethodCall(
          "StartProxy",
          std::make_unique<EncodableValue>(std::move(arguments))),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](
              const std::string& code,
              const std::string& message,
              const EncodableValue* details) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "bad_args");
}

TEST(ProxyPlugin, RestoresTheSystemProxyOnlyWhenTheSessionReallyEnds) {
  EXPECT_TRUE(ProxyPlugin::IsSessionEnding(WM_ENDSESSION, TRUE));
  // A cancelled shutdown reports itself through the same message, and acting on
  // it would strip the proxy from a session that goes on running.
  EXPECT_FALSE(ProxyPlugin::IsSessionEnding(WM_ENDSESSION, FALSE));
  EXPECT_FALSE(ProxyPlugin::IsSessionEnding(WM_QUERYENDSESSION, TRUE));
  EXPECT_FALSE(ProxyPlugin::IsSessionEnding(WM_CLOSE, TRUE));
}

}  // namespace test
}  // namespace proxy
