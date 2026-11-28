import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/playback_state.dart';
import '../models/studio_models.dart';
import 'audio_service.dart';
import 'library_index_cache.dart';
import 'smart_playlist_service.dart';

/// Card model shared across Home dashboard layouts (`AF`, `AI`, `AJ`, `Classic`).
@immutable
class HomeMediaCardItem {
  final String id;
  final String title;
  final String subtitle;
  final TrackInfo? track;
  final CanonicalAlbumSummary? album;
  final String? smartPlaylistId;
  final String? sourceLabel;

  const HomeMediaCardItem({
    required this.id,
    required this.title,
    required this.subtitle,
    this.track,
    this.album,
    this.smartPlaylistId,
    this.sourceLabel,
  });
}

/// Compact quick-resume card model used by `AJ` (`aura-quick-resume`).
@immutable
class HomeQuickResumeItem {
  final String id;
  final String title;
  final String sourceLabel;
  final TrackInfo? track;
  final CanonicalAlbumSummary? album;
  final String? smartPlaylistId;

  const HomeQuickResumeItem({
    required this.id,
    required this.title,
    required this.sourceLabel,
    this.track,
    this.album,
    this.smartPlaylistId,
  });
}

/// Shared ChangeNotifier caching Home dashboard metadata across layout switches
/// so switching `AF`, `AI`, `AJ`, and `Classic` never issues duplicate API calls.
class HomeDashboardDataController extends ChangeNotifier {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final SmartPlaylistService? playlistService;

  String _profileName = 'Lumina';
  List<CanonicalAlbumSummary> _albums = const [];
  List<AudioZoneInfo> _zones = const [];
  Map<String, SmartPlaylistEvaluation> _smartPlaylistEvals = const {};

  List<HomeMediaCardItem> _continueListeningItems = const [];
  List<HomeMediaCardItem> _newlyAddedItems = const [];
  List<HomeMediaCardItem> _favoriteItems = const [];
  List<HomeMediaCardItem> _shuffledItems = const [];
  List<HomeQuickResumeItem> _quickResumeItems = const [];

  bool _isLoading = false;
  bool _hasLoaded = false;
  bool _disposed = false;
  bool _pendingForceReload = false;
  Future<void>? _inFlightLoad;
  Future<void>? _inFlightEvalRefresh;
  String? _lastPlaylistSig;
  String? _lastActiveTrackId;
  int _shuffleNonce = 0;

  StreamSubscription<TrackInfo>? _trackChangedSub;
  StreamSubscription<PlaybackState>? _stateSub;
  StreamSubscription<void>? _libraryReloadedSub;

  HomeDashboardDataController({
    required this.audioService,
    this.libraryCache,
    this.playlistService,
  }) {
    if (libraryCache != null && libraryCache!.albums.isNotEmpty) {
      _albums = List.unmodifiable(libraryCache!.albums.take(50));
    }
    _lastActiveTrackId = audioService.currentState.track?.id;
    _rebuildDerivedItems();
    libraryCache?.addListener(_onLibraryCacheChanged);
    playlistService?.addListener(_onPlaylistServiceChanged);
    _trackChangedSub = audioService.trackChangedStream.listen(_onTrackEvent);
    _stateSub = audioService.stateStream.listen((s) => _onTrackEvent(s.track));
    _libraryReloadedSub = audioService.libraryReloadedStream.listen(
      (_) => _disposed ? null : unawaited(ensureLoaded(force: true)),
    );
  }

  String get profileName => _profileName;
  List<CanonicalAlbumSummary> get albums => _albums;
  List<AudioZoneInfo> get zones => _zones;
  Map<String, SmartPlaylistEvaluation> get smartPlaylistEvals =>
      _smartPlaylistEvals;
  bool get isLoading => _isLoading;
  bool get hasLoaded => _hasLoaded;
  List<HomeMediaCardItem> get continueListeningItems => _continueListeningItems;
  List<HomeMediaCardItem> get newlyAddedItems => _newlyAddedItems;
  List<HomeMediaCardItem> get favoriteItems => _favoriteItems;
  List<HomeMediaCardItem> get shuffledItems => _shuffledItems;
  List<HomeQuickResumeItem> get quickResumeItems => _quickResumeItems;

  /// Fetches Home metadata once (single-flight) unless [force] is `true`.
  Future<void> ensureLoaded({bool force = false}) {
    if (_disposed) return Future<void>.value();
    if (_inFlightLoad != null) {
      if (force) _pendingForceReload = true;
      return _inFlightLoad!;
    }
    if (_hasLoaded && !force) return Future<void>.value();
    _isLoading = true;
    final future = _performLoad(force: force).whenComplete(() {
      _inFlightLoad = null;
      _isLoading = false;
      if (!_disposed && _pendingForceReload) {
        _pendingForceReload = false;
        unawaited(ensureLoaded(force: true));
      }
    });
    _inFlightLoad = future;
    return future;
  }

  Future<void> _performLoad({required bool force}) async {
    final top = playlistService?.playlists.take(3).toList(growable: false) ??
        const <SmartPlaylistItem>[];
    final evalSig = top.map((p) => p.id).join('|');
    final results = await Future.wait<dynamic>([
      _safeCall(audioService.listProfiles, const <UserProfileInfo>[]),
      _safeCall(() => audioService.getAlbums(limit: 50), const <CanonicalAlbumSummary>[]),
      _safeCall(audioService.listZones, const <AudioZoneInfo>[]),
      _evaluateTopPlaylists(top),
    ]);
    if (_disposed) return;

    final profiles = results[0] as List<UserProfileInfo>;
    final fetchedAlbums = results[1] as List<CanonicalAlbumSummary>;
    final fetchedZones = results[2] as List<AudioZoneInfo>;
    final evalMap = results[3] as Map<String, SmartPlaylistEvaluation>;

    final activeProfile =
        profiles.where((p) => p.isDefault).firstOrNull ?? profiles.firstOrNull;
    if (activeProfile != null && activeProfile.name.isNotEmpty) {
      _profileName = activeProfile.name == 'Default Listener'
          ? '預設聆聽者'
          : activeProfile.name;
    }

    if (fetchedAlbums.isNotEmpty) {
      _albums = List.unmodifiable(fetchedAlbums);
    } else if (force || (libraryCache?.albums.isEmpty ?? true)) {
      _albums = const [];
    } else {
      _albums = List.unmodifiable(libraryCache!.albums.take(50));
    }

    _zones = List.unmodifiable(fetchedZones);
    _smartPlaylistEvals = Map.unmodifiable(evalMap);
    _lastPlaylistSig = evalSig;
    _hasLoaded = true;
    _isLoading = false;
    _rebuildDerivedItems();
    notifyListeners();
  }

  Future<Map<String, SmartPlaylistEvaluation>> _evaluateTopPlaylists(
    List<SmartPlaylistItem> playlists,
  ) async {
    if (playlists.isEmpty) return const {};
    final entries = await Future.wait(
      playlists.map((sp) async {
        final ev = await _safeCall<SmartPlaylistEvaluation?>(
          () => audioService.evaluateSmartPlaylist(sp.id),
          null,
        );
        return ev != null ? MapEntry(sp.id, ev) : null;
      }),
    );
    return {
      for (final e in entries)
        if (e != null) e.key: e.value,
    };
  }

  void _onLibraryCacheChanged() {
    if (_disposed) return;
    final cached = libraryCache?.albums;
    if (cached != null && cached.isNotEmpty) {
      _albums = List.unmodifiable(cached.take(50));
    }
    _rebuildDerivedItems();
    notifyListeners();
  }

  void _onPlaylistServiceChanged() {
    if (_disposed) return;
    final top = playlistService?.playlists.take(3).toList(growable: false) ??
        const <SmartPlaylistItem>[];
    final sig = top.map((p) => p.id).join('|');
    if (sig != _lastPlaylistSig && _inFlightEvalRefresh == null) {
      _inFlightEvalRefresh = _evaluateTopPlaylists(top).then((nextEvals) {
        if (_disposed) return;
        _smartPlaylistEvals = Map.unmodifiable(nextEvals);
        _lastPlaylistSig = sig;
        _rebuildDerivedItems();
        notifyListeners();
      }).whenComplete(() => _inFlightEvalRefresh = null);
      return;
    }
    _rebuildDerivedItems();
    notifyListeners();
  }

  void _onTrackEvent(TrackInfo? track) {
    if (_disposed || track?.id == _lastActiveTrackId) return;
    _lastActiveTrackId = track?.id;
    _rebuildContinueAndResume();
    notifyListeners();
  }

  /// Shuffles the cached discovery items in memory without issuing API calls.
  void reshuffleDiscovery() {
    if (_disposed) return;
    _shuffleNonce++;
    _shuffledItems = _buildShuffledList(_buildDiscoveryPool());
    notifyListeners();
  }

  void _rebuildDerivedItems() {
    _rebuildContinueAndResume();
    _newlyAddedItems = _buildNewlyAddedList();
    _favoriteItems = _buildFavoritesList();
    _shuffledItems = _buildShuffledList(_buildDiscoveryPool());
  }

  void _rebuildContinueAndResume() {
    _continueListeningItems = _buildContinueListeningList();
    _quickResumeItems = _buildQuickResumeList();
  }

  HomeMediaCardItem _cardForAlbum(
    String prefix,
    CanonicalAlbumSummary album,
    List<TrackInfo> tracks,
  ) {
    final matchTrack = _findTrackForAlbum(album, tracks);
    return HomeMediaCardItem(
      id: '${prefix}_${album.id}',
      title: album.title,
      subtitle: album.artist,
      track: matchTrack,
      album: album,
      sourceLabel: _sourceLabelFor(track: matchTrack, album: album),
    );
  }

  HomeMediaCardItem _cardForTrack(
    String prefix,
    TrackInfo track, {
    CanonicalAlbumSummary? album,
  }) {
    final resolvedAlbum = album ?? _findAlbumForTrack(track);
    final title = resolvedAlbum?.title ??
        (track.album.trim().isNotEmpty ? track.album : track.title);
    return HomeMediaCardItem(
      id: '${prefix}_${resolvedAlbum?.id ?? track.id}',
      title: title,
      subtitle: resolvedAlbum?.artist ?? track.artist,
      track: track,
      album: resolvedAlbum,
      sourceLabel: _sourceLabelFor(track: track, album: resolvedAlbum),
    );
  }

  List<HomeMediaCardItem> _buildContinueListeningList() {
    final tracks = audioService.queue;
    final active = audioService.currentState.track;
    final seen = <String>{};
    final items = <HomeMediaCardItem>[];
    void addTrack(TrackInfo t) {
      final alb = _findAlbumForTrack(t);
      if (seen.add(alb != null ? 'alb:${alb.id}' : 'trk:${t.id}')) {
        items.add(_cardForTrack('continue', t, album: alb));
      }
    }
    if (active != null) addTrack(active);
    for (final t in tracks.where((t) => t.preference != -1)) {
      addTrack(t);
    }
    for (final a in _albums.where((a) => a.preference != -1)) {
      if (seen.add('alb:${a.id}')) items.add(_cardForAlbum('continue', a, tracks));
    }
    return List.unmodifiable(items);
  }

  List<HomeMediaCardItem> _buildNewlyAddedList() {
    final tracks = audioService.queue;
    final items = <HomeMediaCardItem>[
      for (final a in _albums)
        if (a.preference != -1) _cardForAlbum('new', a, tracks),
    ];
    if (items.isEmpty) {
      final seenAlbums = <String>{};
      for (final t in tracks.where((t) => t.preference != -1)) {
        final key = '${t.effectiveAlbumArtist}|${t.album}'.toLowerCase();
        if (seenAlbums.add(key)) items.add(_cardForTrack('new_trk', t));
      }
    }
    return List.unmodifiable(items);
  }

  List<HomeMediaCardItem> _buildFavoritesList() {
    final tracks = audioService.queue;
    final liked = <HomeMediaCardItem>[];
    final seen = <String>{};
    for (final a in _albums.where((a) => a.preference > 0)) {
      if (seen.add('alb:${a.id}')) liked.add(_cardForAlbum('fav', a, tracks));
    }
    for (final t in tracks.where((t) => t.preference > 0)) {
      final alb = _findAlbumForTrack(t);
      if (seen.add(alb != null ? 'alb:${alb.id}' : 'trk:${t.id}')) {
        liked.add(_cardForTrack('fav', t, album: alb));
      }
    }
    if (liked.isNotEmpty) return List.unmodifiable(liked);
    final ranked = _buildDiscoveryPool().toList(growable: true)
      ..sort((a, b) => (b.album?.qualityScore ?? 0.0).compareTo(a.album?.qualityScore ?? 0.0));
    return List.unmodifiable(ranked);
  }

  List<HomeMediaCardItem> _buildDiscoveryPool() {
    final pool = <HomeMediaCardItem>[];
    final seen = <String>{};
    for (final item in [..._newlyAddedItems, ..._continueListeningItems]) {
      if (seen.add(item.album?.id ?? item.id)) pool.add(item);
    }
    return pool;
  }

  List<HomeMediaCardItem> _buildShuffledList(List<HomeMediaCardItem> pool) {
    if (pool.length <= 1) return List.unmodifiable(pool);
    final copy = List<HomeMediaCardItem>.from(pool)
      ..shuffle(math.Random(0x5A17 + _shuffleNonce * 7919));
    if (_shuffleNonce > 0 && copy.first.id == pool.first.id) {
      copy.add(copy.removeAt(0));
    }
    return List.unmodifiable(copy);
  }

  List<HomeQuickResumeItem> _buildQuickResumeList() {
    final items = <HomeQuickResumeItem>[];
    final seen = <String>{};
    final tracks = audioService.queue;
    final active = audioService.currentState.track;

    void addTrackResume(TrackInfo t) {
      if (items.length >= 6 || t.preference == -1) return;
      final alb = _findAlbumForTrack(t);
      if (!seen.add(alb != null ? 'alb:${alb.id}' : 'trk:${t.id}')) return;
      items.add(HomeQuickResumeItem(
        id: 'qr_${alb?.id ?? t.id}',
        title: alb?.title ?? (t.album.trim().isNotEmpty ? t.album : t.title),
        sourceLabel: _sourceLabelFor(track: t, album: alb),
        track: t,
        album: alb,
      ));
    }

    if (active != null) addTrackResume(active);
    for (final t in tracks) {
      if (items.length >= 3) break;
      addTrackResume(t);
    }
    for (final sp in (playlistService?.playlists ?? const <SmartPlaylistItem>[]).take(2)) {
      if (items.length >= 6 || !seen.add('sp:${sp.id}')) continue;
      items.add(HomeQuickResumeItem(
        id: 'qr_sp_${sp.id}',
        title: sp.name,
        sourceLabel: '智慧歌單',
        track: _smartPlaylistEvals[sp.id]?.tracks.firstOrNull,
        smartPlaylistId: sp.id,
      ));
    }
    for (final a in _albums.where((a) => a.preference != -1)) {
      if (items.length >= 6 || !seen.add('alb:${a.id}')) continue;
      final matchTrack = _findTrackForAlbum(a, tracks);
      items.add(HomeQuickResumeItem(
        id: 'qr_${a.id}',
        title: a.title,
        sourceLabel: _sourceLabelFor(track: matchTrack, album: a),
        track: matchTrack,
        album: a,
      ));
    }
    return List.unmodifiable(items);
  }

  CanonicalAlbumSummary? _findAlbumForTrack(TrackInfo track) {
    final fromCache = libraryCache?.resolveAlbumForTrack(track);
    if (fromCache != null) return fromCache;
    return _albums
            .where((a) => a.title == track.album && (a.artist == track.artist || a.artist == track.effectiveAlbumArtist))
            .firstOrNull ??
        _albums.where((a) => a.title == track.album).firstOrNull;
  }

  TrackInfo? _findTrackForAlbum(CanonicalAlbumSummary album, List<TrackInfo> tracks) {
    return tracks
            .where((t) => t.album == album.title && (t.effectiveAlbumArtist == album.artist || t.artist == album.artist))
            .firstOrNull ??
        tracks.where((t) => t.album == album.title).firstOrNull;
  }

  String _sourceLabelFor({TrackInfo? track, CanonicalAlbumSummary? album}) {
    final raw = track?.providerName ?? album?.provider ?? album?.availableProviders.firstOrNull ?? '';
    final lower = raw.trim().toLowerCase();
    if (lower.isEmpty || lower == 'local' || lower.contains('local library') || lower.contains('local nas')) {
      return '本機曲庫';
    }
    if (lower.contains('qobuz')) return 'Qobuz';
    if (lower.contains('tidal')) return 'Tidal';
    if (lower.contains('deezer')) return 'Deezer';
    if (lower.contains('apple')) return 'Apple Music';
    if (lower.contains('youtube') || lower.contains('ytm')) return 'YouTube Music';
    return raw.trim();
  }

  Future<T> _safeCall<T>(Future<T> Function() fn, T fallback) async {
    try {
      return await fn();
    } catch (_) {
      return fallback;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    libraryCache?.removeListener(_onLibraryCacheChanged);
    playlistService?.removeListener(_onPlaylistServiceChanged);
    _trackChangedSub?.cancel();
    _stateSub?.cancel();
    _libraryReloadedSub?.cancel();
    _trackChangedSub = null;
    _stateSub = null;
    _libraryReloadedSub = null;
    super.dispose();
  }
}
