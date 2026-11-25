import 'package:dio/dio.dart';
import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/common/exception.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MessageException renders as the bare message', () {
    expect(
      const MessageException('profile is invalid').toString(),
      'profile is invalid',
    );
  });

  test('MessageException is catchable as an Exception', () {
    Object? caught;
    try {
      throw const MessageException('core rejected the config');
    } on Exception catch (error) {
      caught = error;
    }

    expect(caught, isA<MessageException>());
  });

  test('MessageException carries a stack trace to its catcher', () {
    StackTrace? stackTrace;
    try {
      throw const MessageException('boom');
    } catch (_, trace) {
      stackTrace = trace;
    }

    expect(stackTrace, isNotNull);
    expect(stackTrace.toString(), isNotEmpty);
  });
  test('release failures include their stage and the network cause', () async {
    final localizations = await AppLocalizations.load(const Locale('en'));
    final error = ReleaseUpdateStageException(
      ReleaseUpdateStage.package,
      DioException(
        requestOptions: RequestOptions(path: '/release.apk'),
        type: DioExceptionType.badCertificate,
      ),
    );

    expect(
      userFacingErrorMessage(error, localizations),
      localizations.updateDownloadFailed + '\n' + localizations.networkTlsError,
    );
  });

