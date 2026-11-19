import 'package:fl_clash/common/preferences.dart';
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
}
