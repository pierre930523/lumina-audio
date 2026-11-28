import 'dart:convert';

/// Internal typed JSON decoding helper operating strictly on `Map<String, Object?>`
/// so canonical protocol models never expose `dynamic` in public APIs or fields.
class JsonReader {
  final Map<String, Object?> map;

  const JsonReader(this.map);

  static Map<String, Object?>? decodeObject(String raw) {
    final Object? decoded = jsonDecode(raw);
    return asMapOrNull(decoded);
  }

  static List<Object?>? decodeList(String raw) {
    final Object? decoded = jsonDecode(raw);
    return asListOrNull(decoded);
  }

  static Map<String, Object?>? asMapOrNull(Object? value) {
    if (value is Map<String, Object?>) {
      return value;
    }
    if (value is Map<Object?, Object?>) {
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is String) {
          result[key] = entry.value;
        }
      }
      return result;
    }
    return null;
  }

  static List<Object?>? asListOrNull(Object? value) {
    if (value is List<Object?>) {
      return value;
    }
    if (value is List) {
      return List<Object?>.from(value);
    }
    return null;
  }

  Object? raw(String key) => map[key];

  bool containsKey(String key) => map.containsKey(key);

  String? optionalString(String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is String) return value;
    return value.toString();
  }

  String? nonEmptyString(String key) {
    final value = optionalString(key)?.trim();
    return (value != null && value.isNotEmpty) ? value : null;
  }

  String requiredString(String key, {String fallback = ''}) {
    return optionalString(key) ?? fallback;
  }

  int? optionalInt(String key) {
    final value = map[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  int requiredInt(String key, {int fallback = 0}) {
    return optionalInt(key) ?? fallback;
  }

  double? optionalDouble(String key) {
    final value = map[key];
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  double requiredDouble(String key, {double fallback = 0.0}) {
    return optionalDouble(key) ?? fallback;
  }

  bool? optionalBool(String key) {
    final value = map[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final lower = value.trim().toLowerCase();
      if (lower == 'true' || lower == '1') return true;
      if (lower == 'false' || lower == '0') return false;
    }
    return null;
  }

  bool requiredBool(String key, {bool fallback = false}) {
    return optionalBool(key) ?? fallback;
  }

  Map<String, Object?>? optionalMap(String key) {
    return asMapOrNull(map[key]);
  }

  List<Object?>? optionalList(String key) {
    return asListOrNull(map[key]);
  }

  List<int> intList(String key, {List<int> fallback = const <int>[]}) {
    final list = optionalList(key);
    if (list == null) return fallback;
    final out = <int>[];
    for (final item in list) {
      if (item is int) {
        out.add(item);
      } else if (item is num) {
        out.add(item.toInt());
      } else if (item is String) {
        final parsed = int.tryParse(item.trim());
        if (parsed != null) out.add(parsed);
      }
    }
    return List<int>.unmodifiable(out);
  }

  List<T> mapList<T>(
    String key,
    T Function(Map<String, Object?> item) parse,
  ) {
    final list = optionalList(key);
    if (list == null) return List<T>.unmodifiable(<T>[]);
    final out = <T>[];
    for (final item in list) {
      final itemMap = asMapOrNull(item);
      if (itemMap != null) {
        out.add(parse(itemMap));
      }
    }
    return List<T>.unmodifiable(out);
  }
}
