String? asString(Object? value) {
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int? asInt(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  return int.tryParse(value.toString());
}

bool? asBool(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value == 1;
  }
  final text = value.toString().trim().toLowerCase();
  return text == 'true' || text == '1';
}

List<dynamic> asList(Object? value) {
  if (value is List) {
    return value;
  }
  return const [];
}

Map<String, dynamic> asMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return const {};
}

Duration? durationFromSeconds(Object? value) {
  final seconds = asInt(value);
  return seconds == null ? null : Duration(seconds: seconds);
}

Duration? durationFromMilliseconds(Object? value) {
  final milliseconds = asInt(value);
  return milliseconds == null ? null : Duration(milliseconds: milliseconds);
}

String? normalizeImageUrl(String? url, {int size = 480}) {
  if (url == null) {
    return null;
  }
  return url
      .replaceAll('{size}', '$size')
      .replaceAll('{SIZE}', '$size')
      .replaceAll('/{size}/', '/$size/')
      .replaceAll('/{SIZE}/', '/$size/');
}

/// 归一化 MV 封面地址：
/// - 完整 URL（含 `{size}` 占位符）走 [normalizeImageUrl]；
/// - 酷狗 MV 搜索/详情接口常见的纯文件名（如 `"Pic": "20200620174316264397.jpg"`，
///   前 8 位为 `YYYYMMDD` 日期目录）补全为 `http://imge.kugou.com/mvhdpic/$size/YYYYMMDD/文件名`。
String? normalizeMvCoverUrl(String? url, {int size = 480}) {
  final raw = asString(url);
  if (raw == null) {
    return null;
  }
  if (raw.startsWith('http://') || raw.startsWith('https://')) {
    return normalizeImageUrl(raw, size: size);
  }
  if (RegExp(r'^\d{8}').hasMatch(raw)) {
    final dateDir = raw.substring(0, 8);
    return 'http://imge.kugou.com/mvhdpic/$size/$dateDir/$raw';
  }
  return normalizeImageUrl(raw, size: size);
}

String formatDuration(Duration? duration) {
  if (duration == null) {
    return '--:--';
  }
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
