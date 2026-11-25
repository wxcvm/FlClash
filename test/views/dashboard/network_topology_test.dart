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
    // The CLI future is resolved in runAsync, not the widget's fake clock.
    late Completer<void> entered;
    late Completer<ProcessResult> validation;
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
      entered = Completer<void>();
      validation = Completer<ProcessResult>();
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
      await entered.future.timeout(const Duration(seconds: 5));
    });

    await tester.pump();
    expect(find.text('Switching cores'), findsOneWidget);
    expect(find.byType(TopologyGraphView), findsNothing);
    expect(find.text('Resume'), findsNothing);

    await tester.runAsync(() async {
      validation.complete(ProcessResult(1, 1, '', 'invalid config'));
      await attempt.timeout(const Duration(seconds: 5));
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

  testWidgets(
    'sing-box dashboard explains when its local controller is absent',
    (tester) async {
      late Directory directory;
      late NativeCoreRuntime runtime;
      late NativeCoreHandoff handoff;
      final child = _Child();

      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('native-topology-');
        final config = File('${directory.path}/config.json');
        await config.writeAsString('{"outbounds":[]}');
        runtime = NativeCoreRuntime(
          run: (_, _, {workingDirectory}) async => ProcessResult(1, 0, '', ''),
          start: (_, _, {workingDirectory}) async => child,
        );
        final spec = NativeCoreSpec(
          kind: NativeCoreKind.singBox,
          executable: 'unused',
          configPath: config.path,
        );
        await runtime.start(spec);
        handoff = NativeCoreHandoff(
          runtime: runtime,
          isMihomoRunning: () => false,
          setMihomoRunning: (_) async => true,
          releaseMihomoProxy: () async {},
        );
      });

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
        await directory.delete(recursive: true);
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
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump();

      expect(
        find.textContaining('127.0.0.1 Clash API'),
        findsOneWidget,
      );
      expect(find.byType(TopologyGraphView), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );
}

class _Child implements Process {
  final Completer<int> _exit = Completer<int>();

  @override
  int get pid => 321;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) _exit.complete(0);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
