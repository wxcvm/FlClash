class AppUrlUtilsPrivate {
  static String signQueryParams(
    String version,
    int bodyLen,
    Map<String, dynamic> params,
  ) {
    final buffer = StringBuffer('v=${Uri.encodeQueryComponent(version)}');
    buffer.write('&bl=');
    buffer.write(bodyLen);
    for (final entry in params.entries) {
      buffer.write('&');
      buffer.write(Uri.encodeQueryComponent(entry.key));
      buffer.write('=');
      buffer.write(Uri.encodeQueryComponent(entry.value.toString()));
    }
    return buffer.toString();
  }
}
