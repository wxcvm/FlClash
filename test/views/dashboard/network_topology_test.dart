import 'dart:async';
import 'dart:io';

import 'package:fl_clash/core/desktop/native_core.dart';
import 'package:fl_clash/core/desktop/native_handoff.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/connection/topology_graph.dart';
import 'package:fl_clash/views/dashboard/layout.dart';
import 'package:fl_clash/views/dashboard/widgets/network_topology.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/host_scaffold.dart';
import '../../helpers/test_app.dart';

void main() {
  testWidgets('a core handoff clears the frozen Mihomo topology', (
    tester,
  ) async {
    final entered = Completer<void>();
    final validation = Completer<ProcessResult>();
    final runtime = NativeCoreRuntime(
      run: (_, _, {workingDirectory}) {
        entered.complete();
        return validation.future;
      },
    );
    final handoff = NativeCoreHandoff(
      runtime: runtime,
      isMihomoRunning: () => true,
      setMihomoRunning: (_) async => true,
      releaseMihomoProxy: () async {},
    );
    final container = ProviderContainer(
      overrides: [
        coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.disconnected),
      ],
    );
    globalState.container = container;
    addTearDown(container.dispose);
    addTearDown(() async {
      await handoff.close();
      await runtime.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: HostScaffold(
            body: DashboardDensityScope(
              density: DashboardDensity.standard,
              scale: 1,
              child: NetworkTopologyCard(handoff: handoff),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(TopologyGraphView), findsOneWidget);
    await tester.tap(find.text('Freeze'));
    await tester.pump();
    expect(find.text('Resume'), findsOneWidget);

    late Future<void> attempt;
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('topology-test-');
      final config = File('${directory.path}/config.json');
      await config.writeAsString('{}');
      attempt = handoff
          .activate(
            NativeCoreSpec(
              kind: NativeCoreKind.singBox,
              executable: 'unused',
              configPath: config.path,
            ),
          )
          .then<void>(
            (_) => fail('Invalid configuration must not start'),
            onError: (Object error, StackTrace _) {
              expect(error, isA<StateError>());
            },
          );
      await entered.future;
    });

    await tester.pump();
    expect(find.text('Switching cores'), findsOneWidget);
    expect(find.byType(TopologyGraphView), findsNothing);
    expect(find.text('Resume'), findsNothing);

    await tester.runAsync(() async {
      validation.complete(ProcessResult(1, 1, '', 'invalid config'));
      await attempt;
      await directory.delete(recursive: true);
    });
    await tester.pump();
    expect(find.byType(TopologyGraphView), findsOneWidget);
    expect(find.text('Freeze'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });
}
