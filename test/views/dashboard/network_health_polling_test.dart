import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/dashboard/widgets/network_health.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/test_app.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

void main() {
  testWidgets('network diagnostics stop reading in the background', (
    tester,
  ) async {
    final core = _MockCore();
    var reads = 0;
    when(core.getNetworkHealth).thenAnswer((_) async {
      reads++;
      return <String, dynamic>{};
    });

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      TestApp(
        overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.connected),
        ],
        child: const NetworkHealthSheet(),
      ),
    );
    await tester.pump();
    expect(reads, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 10));
    expect(reads, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(reads, 2);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
