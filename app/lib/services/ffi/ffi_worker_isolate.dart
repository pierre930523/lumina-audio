part of '../ffi_audio_service.dart';

/// Identifies which dedicated FFI worker isolate handles an operation so
/// fast UI read/artwork calls never queue behind long scans/rebuilds.
enum FfiWorkerLane {
  read,
  write,
}

/// Canonical routing table classifying every background FFI op into either
/// [FfiWorkerLane.read] (UI queries & artwork) or [FfiWorkerLane.write]
/// (scans, rebuilds, mutations).
class FfiWorkerRouter {
  static const Set<String> readOps = <String>{
    'get_tracks',
    'get_albums',
    'get_album_detail',
    'get_artist_detail',
    'search',
    'artwork_get',
    'watch_list',
    'skipped_files',
    'get_metadata_overrides',
    'get_lyrics',
    'list_profiles',
    'get_albums_with_options',
    'focus_query',
    'focus_facets',
    'list_tags',
    'get_entity_tags',
    'get_folder_roots',
    'get_folder_contents',
    'get_folder_recursive_track_ids',
    'list_bookmarks',
    'list_smart_playlists',
    'evaluate_smart_playlist',
    'list_listen_later',
    'list_static_playlists',
    'get_static_playlist_detail',
    'analyze_playlist_improvements',
    'list_playlist_snapshots',
    'get_bulk_edit_summary',
    'get_album_assets',
    'read_album_asset_content',
    'get_backup_settings',
    'list_backup_history',
    'get_audio_export_progress',
  };

  static const Set<String> writeOps = <String>{
    'library_init',
    'l2_cache_init',
    'scan_dir',
    'scan_start',
    'rescan_start',
    'force_rebuild_start',
    'rescan_tags',
    'deduplicate',
    'enrich_credits',
    'provider_sync',
    'ingest_external_catalog',
    'watch_add',
    'watch_remove',
    'dismiss_skipped_file',
    'retry_skipped_file',
    'set_metadata_override',
    'clear_metadata_override',
    'set_user_cover',
    'clear_user_cover',
    'set_user_lyrics',
    'clear_user_lyrics',
    'create_profile',
    'update_profile',
    'delete_profile',
    'switch_profile',
    'create_tag',
    'update_tag',
    'delete_tag',
    'link_tag_parent',
    'unlink_tag_parent',
    'batch_tag_items',
    'set_entity_preference',
    'create_bookmark',
    'update_bookmark',
    'delete_bookmark',
    'reorder_bookmarks',
    'create_smart_playlist',
    'update_smart_playlist',
    'delete_smart_playlist',
    'duplicate_smart_playlist',
    'add_listen_later',
    'mark_listen_later_status',
    'update_listen_later_note',
    'remove_listen_later',
    'promote_listen_later',
    'create_static_playlist',
    'delete_static_playlist',
    'add_tracks_to_static_playlist',
    'apply_playlist_improvements',
    'revert_playlist_snapshot',
    'apply_bulk_edit',
    'update_backup_settings',
    'create_library_backup',
    'restore_library_backup',
    'export_catalog',
    'start_audio_export',
    'cancel_audio_export',
  };

  static FfiWorkerLane laneForOp(String op) {
    if (readOps.contains(op)) return FfiWorkerLane.read;
    return FfiWorkerLane.write;
  }
}

class _FfiWorkerClient {
  final String dylibPath;
  final FfiWorkerLane lane;
  final String debugName;
  ReceivePort? _mainPort;
  StreamSubscription<dynamic>? _mainPortSub;
  SendPort? _workerPort;
  Future<SendPort>? _startFuture;
  int _nextReqId = 1;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  bool _disposed = false;

  _FfiWorkerClient(
    this.dylibPath, {
    required this.lane,
    required this.debugName,
  });

  bool get isStarted => _workerPort != null;

  Future<Object?> call(String op, [Map<String, Object?> args = const {}]) async {
    if (_disposed) {
      throw StateError('$debugName disposed');
    }
    final port = await _ensureStarted();
    if (_disposed) {
      throw StateError('$debugName disposed');
    }
    final id = _nextReqId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send((id, op, args));
    return completer.future;
  }

  Future<SendPort> _ensureStarted() {
    final existing = _workerPort;
    if (existing != null) return Future<SendPort>.value(existing);
    return _startFuture ??= _spawn();
  }

  Future<SendPort> _spawn() async {
    final receivePort = ReceivePort();
    _mainPort = receivePort;
    final initCompleter = Completer<SendPort>();

    _mainPortSub = receivePort.listen(
      (message) {
        if (!initCompleter.isCompleted) {
          if (message is SendPort) {
            _workerPort = message;
            initCompleter.complete(message);
          } else {
            initCompleter.completeError(
              StateError('$debugName init failed: $message'),
            );
          }
          return;
        }
        if (message is (int, bool, Object?)) {
          final (id, ok, payload) = message;
          final completer = _pending.remove(id);
          if (completer != null && !completer.isCompleted) {
            if (ok) {
              completer.complete(payload);
            } else {
              completer.completeError(
                StateError(payload?.toString() ?? '$debugName error'),
              );
            }
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!initCompleter.isCompleted) {
          initCompleter.completeError(error, stack);
        }
      },
    );

    try {
      await Isolate.spawn(
        _ffiWorkerMain,
        (receivePort.sendPort, dylibPath, lane == FfiWorkerLane.read),
        debugName: debugName,
      );
      return await initCompleter.future;
    } catch (e) {
      _startFuture = null;
      _workerPort = null;
      await _mainPortSub?.cancel();
      _mainPortSub = null;
      _mainPort?.close();
      _mainPort = null;
      rethrow;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _workerPort?.send(null);
    } catch (_) {}
    _workerPort = null;
    _startFuture = null;
    unawaited(_mainPortSub?.cancel());
    _mainPortSub = null;
    _mainPort?.close();
    _mainPort = null;
    final pending = List<Completer<Object?>>.from(_pending.values);
    _pending.clear();
    for (final c in pending) {
      if (!c.isCompleted) {
        c.completeError(StateError('$debugName disposed'));
      }
    }
  }
}

void _ffiWorkerMain((SendPort, String, bool) boot) {
  final (replyPort, dylibPath, isReadLane) = boot;
  final ffi.DynamicLibrary dylib;
  try {
    dylib = ffi.DynamicLibrary.open(dylibPath);
  } catch (e) {
    replyPort.send('Failed to open native library "$dylibPath": $e');
    return;
  }

  final helpers = _FfiWorkerNativeHelpers(dylib);
  final handlers = isReadLane
      ? _buildFfiReadHandlers(helpers)
      : _buildFfiWriteHandlers(helpers);

  final cmdPort = ReceivePort();
  replyPort.send(cmdPort.sendPort);

  cmdPort.listen((message) {
    if (message == null) {
      cmdPort.close();
      return;
    }
    if (message is (int, String, Map<String, Object?>)) {
      final (id, op, args) = message;
      try {
        final handler = handlers[op];
        if (handler == null) {
          throw ArgumentError(
            'Unknown ${isReadLane ? 'read' : 'write'} FFI worker op: $op',
          );
        }
        final result = handler(args);
        replyPort.send((id, true, result));
      } catch (e) {
        replyPort.send((id, false, e.toString()));
      }
    }
  });
}
