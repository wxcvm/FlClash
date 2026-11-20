import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/common/windows_adguard_dns.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Windows system DNS mode starts disabled and persists independently',
    () async {
      await mockPreferences();
      expect(await preferences.getFollowWindowsSystemDns(), isFalse);

      expect(await preferences.setFollowWindowsSystemDns(true), isTrue);
      await preferences.rebind();
      expect(await preferences.getFollowWindowsSystemDns(), isTrue);

      expect(await preferences.setFollowWindowsSystemDns(false), isTrue);
      expect(await preferences.getFollowWindowsSystemDns(), isFalse);
    },
  );

  test('a stopped core saves the mode without a forced reload', () async {
    final selected = <bool>[];
    var applyCount = 0;

    await updateWindowsDnsPreference(
      previous: false,
      coreRunning: false,
      save: (value) async {
        selected.add(value);
        return true;
      },
      apply: () async {
        applyCount++;
        return true;
      },
    );

    expect(selected, [true]);
    expect(applyCount, 0);
  });

  test('a successful reload keeps the new DNS preference', () async {
    final selected = <bool>[];
    var applyCount = 0;
    await updateWindowsDnsPreference(
      previous: false,
      coreRunning: true,
      save: (value) async {
        selected.add(value);
        return true;
      },
      apply: () async {
        applyCount++;
        return true;
      },
    );
    expect(selected, [true]);
    expect(applyCount, 1);
  });

  test(
    'a failed reload restores the old preference and core profile',
    () async {
      var selected = false;
      final appliedModes = <bool>[];
      await expectLater(
        updateWindowsDnsPreference(
          previous: false,
          coreRunning: true,
          save: (value) async {
            selected = value;
            return true;
          },
          apply: () async {
            appliedModes.add(selected);
            return appliedModes.length == 2;
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(selected, isFalse);
      expect(appliedModes, [true, false]);
    },
  );

  test(
    'a failed rollback does not claim the active profile was restored',
    () async {
      var selected = false;
      final appliedModes = <bool>[];
      await expectLater(
        updateWindowsDnsPreference(
          previous: false,
          coreRunning: true,
          save: (value) async {
            selected = value;
            return true;
          },
          apply: () async {
            appliedModes.add(selected);
            return false;
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message.toString(),
            'message',
            contains('运行中的配置未能重新加载'),
          ),
        ),
      );
      expect(selected, isFalse);
      expect(appliedModes, [true, false]);
    },
  );

  test('refused persistence does not try to reload the core', () async {
    var applyCount = 0;
    await expectLater(
      updateWindowsDnsPreference(
        previous: false,
        coreRunning: true,
        save: (_) async => false,
        apply: () async {
          applyCount++;
          return true;
        },
      ),
      throwsA(isA<StateError>()),
    );
    expect(applyCount, 0);
  });
}
