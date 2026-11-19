import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../models/audio_format.dart';
import '../models/playback_state.dart';

/// 自訂來源種類：有聲書 / Podcast / 廣播電台。
class MediaSourceKind {
  static const audiobook = 'audiobook';
  static const podcast = 'podcast';
  static const radio = 'radio';
}

class MediaSourceEntry {
  final String id;
  final String kind;
  final String title;
  final String url;

  const MediaSourceEntry({
    required this.id,
    required this.kind,
    required this.title,
    required this.url,
  });

  factory MediaSourceEntry.fromJson(Map<String, dynamic> json) =>
      MediaSourceEntry(
        id: json['id']?.toString() ?? '',
        kind: json['kind']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'title': title,
    'url': url,
  };

  /// 轉為可由 AudioService 播放的曲目。
  TrackInfo toTrack() {
    final isRemote = url.startsWith('http://') || url.startsWith('https://');
    return TrackInfo(
      id: id,
      title: title,
      artist: switch (kind) {
        MediaSourceKind.audiobook => '有聲書',
        MediaSourceKind.podcast => 'Podcast',
        _ => '廣播電台',
      },
      album: switch (kind) {
        MediaSourceKind.audiobook => '有聲書',
        MediaSourceKind.podcast => 'Podcast',
        _ => '廣播電台',
      },
      duration: Duration.zero,
      format: const AudioFormat(
        codec: AudioCodec.mp3,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
      providerName: isRemote ? '網路串流' : '本機',
      filePath: url,
    );
  }
}

/// 管理使用者自訂的有聲書／Podcast／電台來源，並持久化於
/// `%LOCALAPPDATA%\LuminaAudio\media_sources.json`（測試環境不讀寫檔案）。
class MediaSourcesController extends ChangeNotifier {
  static final MediaSourcesController instance = MediaSourcesController();

  final List<MediaSourceEntry> _entries = [];
  bool _loaded = false;

  List<MediaSourceEntry> byKind(String kind) =>
      _entries.where((e) => e.kind == kind).toList(growable: false);

  bool get _skipIo => Platform.environment.containsKey('FLUTTER_TEST');

  File _file() {
    final base = Platform.environment['LOCALAPPDATA'];
    final dir = (base != null && base.isNotEmpty)
        ? '$base${Platform.pathSeparator}LuminaAudio'
        : '${Directory.systemTemp.path}${Platform.pathSeparator}LuminaAudio';
    return File('$dir${Platform.pathSeparator}media_sources.json');
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (_skipIo) return;
    try {
      final file = _file();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is List) {
        _entries
          ..clear()
          ..addAll(
            raw.whereType<Map<String, dynamic>>().map(
              MediaSourceEntry.fromJson,
            ),
          );
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    if (_skipIo) return;
    try {
      final file = _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(_entries.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<MediaSourceEntry> add({
    required String kind,
    required String title,
    required String url,
  }) async {
    final entry = MediaSourceEntry(
      id: 'custom-$kind-${DateTime.now().microsecondsSinceEpoch}',
      kind: kind,
      title: title.trim(),
      url: url.trim(),
    );
    _entries.add(entry);
    notifyListeners();
    await _save();
    return entry;
  }

  Future<void> remove(String id) async {
    _entries.removeWhere((e) => e.id == id);
    notifyListeners();
    await _save();
  }

  void resetForTest() {
    _entries.clear();
    _loaded = true;
    notifyListeners();
  }
}
