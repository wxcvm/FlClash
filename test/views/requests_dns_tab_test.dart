import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/connection/requests.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [profilesProvider.overrideWith(TestProfiles.new)],
    );
    globalState.container = container;
    container
        .read(viewSizeProvider.notifier)
        .update((_) => const Size(1400, 1000));
  });

  tearDown(() => container.dispose());

  void seedDnsQuery({
    String domain = 'example.test',
    String rcode = 'NOERROR',
    List<String> answers = const ['1.1.1.1'],
    String error = '',
  }) {
    container.read(dnsQueriesProvider.notifier).addQuery(
      DnsQuery(
        domain: domain,
        type: 'A',
        initiator: DnsQueryInitiator.app,
        upstream: 'https://dns.example/dns-query',
        cached: false,
        answers: answers,
        rcode: rcode,
        error: error,
        delay: 12,
        time: DateTime.utc(2026, 11, 27, 10),
      ),
    );
  }

  Future<void> pumpRequests(WidgetTester tester) async {
    const size = Size(1400, 1000);
    container.read(viewSizeProvider.notifier).update((_) => size);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          locale: const Locale('en'),
          child: RequestsView(connectionsReader: () async => const []),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> openDns(WidgetTester tester) async {
    final bar = find.byType(AppBar);
    await tester.tap(find.descendant(of: bar, matching: find.text('Running')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DNS queries').last);
    await tester.pumpAndSettle();
  }

  Future<void> teardownView(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('Requests menu opens the DNS query feed', (tester) async {
    seedDnsQuery();
    await pumpRequests(tester);
    await openDns(tester);

    expect(find.text('example.test'), findsOneWidget);
    expect(find.text('1.1.1.1'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await teardownView(tester);
  });

  testWidgets('DNS query row opens response details', (tester) async {
    seedDnsQuery(
      domain: 'missing.example',
      rcode: 'NXDOMAIN',
      answers: const [],
    );
    await pumpRequests(tester);
    await openDns(tester);

    await tester.tap(find.text('missing.example'));
    await tester.pumpAndSettle();

    expect(find.text('Response code'), findsOneWidget);
    expect(find.text('NXDOMAIN'), findsWidgets);
    expect(find.text('Record type'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await teardownView(tester);
  });
}
