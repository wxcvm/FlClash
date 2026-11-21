import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karing/app/utils/proxy_conf_utils.dart';

import 'karing_module.dart';

final karingModuleProvider = FutureProvider<KaringModule>((ref) async {
  final module = KaringModule.instance;
  await module.init();
  return module;
});

final karingServersProvider =
    StreamProvider.autoDispose<List<ServerConfigGroupItem>>((ref) async* {
      final module = await ref.watch(karingModuleProvider.future);
      yield* module.watchServers();
    });
