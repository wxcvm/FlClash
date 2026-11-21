import 'dart:async';

import 'package:karing/app/modules/server_manager.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/utils/proxy_conf_utils.dart';

class KaringModule {
  KaringModule._();

  static final instance = KaringModule._();

  Future<void>? _initialization;
  bool _settingsReady = false;

  Future<void> init() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      if (!_settingsReady) {
        await SettingManager.init();
        _settingsReady = true;
      }
      await ServerManager.init();
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  Stream<List<ServerConfigGroupItem>> watchServers() {
    return Stream.multi((controller) {
      final listener = identityHashCode(controller);

      void emit() {
        controller.add(List.unmodifiable(ServerManager.getConfig().items));
      }

      ServerManager.onEventAddConfig(listener, (_) => emit());
      ServerManager.onEventUpdateConfig(listener, (_) async => emit());
      ServerManager.onEventLatencyUpdateConfig(listener, (_) => emit());
      ServerManager.onEventRemoveConfig(listener, (_, _, _) => emit());
      ServerManager.onEventEnableConfig(listener, (_, _) async => emit());
      ServerManager.onEventRemoteTrafficReload(listener, (_) {}, (_) => emit());
      ServerManager.onReloadFromZipConfigs(listener, () async => emit());
      controller.onCancel = () => ServerManager.removeListener(listener);
      emit();
    });
  }
}
