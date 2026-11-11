import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/core/desktop/native_handoff.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';

/// Created once for the whole desktop process, not for each settings page.
final nativeCoreHandoff = NativeCoreHandoff(
  runtime: nativeCoreRuntime,
  isMihomoRunning: () => globalState.container.read(isStartProvider),
  setMihomoRunning: (running) => globalState.container
      .read(setupActionProvider.notifier)
      .setRunning(running),
  releaseMihomoProxy: () async {
    // A state watcher can still have a pending OS-proxy write after
    // setRunning(false); queue an explicit release behind it.
    await systemProxyQueue?.apply(
      const ProxyState(
        isStart: false,
        systemProxy: false,
        bassDomain: [],
        port: 0,
      ),
    );
    await systemDnsCoordinator?.sync(false);
  },
);
