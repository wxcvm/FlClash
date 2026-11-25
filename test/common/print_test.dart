import 'package:dio/dio.dart';
import 'package:fl_clash/common/print.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compactError compacts DioException to type and status code', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: '/'),
        statusCode: 403,
      ),
    );
    expect(compactError(error), 'DioException(badResponse, HTTP 403)');
  });

  test('compactError omits the status code when the response is missing', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.connectionError,
    );
    expect(compactError(error), 'DioException(connectionError)');
  });

  test('compactError redacts credentials in non-Dio errors', () {
    expect(
      compactError(StateError('subscription token=supersecret')),
      'Bad state: subscription token=[REDACTED]',
    );
  });

  test('redacts URL credentials and sensitive query parameters', () {
    const raw =
        'GET https://alice:secret@example.com/sub?token=abc123&region=us';
    final safe = redactSensitiveLogText(raw);

    expect(safe, contains('https://[REDACTED]@example.com'));
    expect(safe, contains('token=[REDACTED]'));
    expect(safe, contains('region=us'));
    expect(safe, isNot(contains('alice')));
    expect(safe, isNot(contains('secret')));
  });

  test('redacts config secrets, bearer tokens and proxy share links', () {
    const raw =
        'uuid: 550e8400-e29b-41d4-a716-446655440000 '
        'password: "my pass" Authorization: Bearer abcdefghijklmnop '
        'vless://550e8400-e29b-41d4-a716-446655440000@edge.example:443';
    final safe = redactSensitiveLogText(raw);

    expect(safe, contains('uuid: [REDACTED]'));
    expect(safe, contains('password: [REDACTED]'));
    expect(safe, contains('Authorization: [REDACTED]'));
    expect(safe, contains('[REDACTED_PROXY_LINK]'));
    expect(safe, isNot(contains('my pass')));
    expect(safe, isNot(contains('abcdefghijklmnop')));
  });
}
