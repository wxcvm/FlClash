import 'dart:convert';

class RawNoticeItem {
  String title = '';
  String content = '';
  String url = '';
  String updateTime = '';
  String expireTime = '';

  Map<String, dynamic> toJson() => {
        'title': title,
        'content': content,
        'url': url,
        'update_time': updateTime,
        'expire_time': expireTime,
      };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    title = map['title'] ?? '';
    content = map['content'] ?? '';
    url = map['url'] ?? '';
    updateTime = map['update_time'] ?? '';
    expireTime = map['expire_time'] ?? '';
  }
}

class NoticeUtils {
  static Future<RawNoticeItem?> parseNotice(dynamic content) async {
    if (content == null) {
      return null;
    }
    String text;
    if (content is List<int>) {
      text = utf8.decode(content, allowMalformed: true);
    } else if (content is String) {
      text = content;
    } else {
      text = content.toString();
    }
    text = text.trim();
    if (text.isEmpty) {
      return null;
    }
    final item = RawNoticeItem();
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        item.fromJson(decoded);
        return item;
      }
    } catch (_) {}
    final lines = text.split(RegExp(r'\r?\n'));
    item.title = lines.first;
    item.content = lines.skip(1).join('\n');
    item.updateTime = DateTime.now().toIso8601String();
    return item;
  }
}
