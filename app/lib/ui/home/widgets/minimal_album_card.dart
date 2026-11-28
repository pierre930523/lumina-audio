import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../../models/audio_format.dart';
import '../../../models/playback_state.dart';
import '../../../models/studio_models.dart';
import '../../../services/audio_service.dart';
import '../../../services/home_dashboard_data_controller.dart';
import '../../../services/library_index_cache.dart';
import '../../artwork/album_artwork_view.dart';
import '../../common/track_context_menu.dart';
import '../../common/track_hover_prefetch.dart';
import '../../theme/lumina_glass_theme.dart';
import '../../theme/smooth_scroll.dart';

/// Plays a [HomeMediaCardItem] immediately via smart playlist, track, or album.
Future<void> playHomeMediaItem({
  required BuildContext context,
  required AudioService audioService,
  required HomeMediaCardItem item,
  LibraryIndexCache? libraryCache,
  Map<String, SmartPlaylistEvaluation> smartPlaylistEvals = const {},
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final pid = item.smartPlaylistId;
  if (pid != null && pid.isNotEmpty) {
    final ev =
        smartPlaylistEvals[pid] ?? await audioService.evaluateSmartPlaylist(pid);
    final playable = (ev?.tracks ?? const <TrackInfo>[])
        .where((t) => t.preference != -1)
        .toList();
    if (playable.isNotEmpty) {
      await audioService.playQueue(playable, excludeBanned: true);
      return;
    }
  }
  if (item.track != null) {
    await audioService.play(track: item.track);
    return;
  }
  final album = item.album;
  if (album != null) {
    await _playCanonicalAlbum(
      messenger: messenger,
      audioService: audioService,
      album: album,
      libraryCache: libraryCache,
    );
  }
}

/// Opens detail view for a [HomeMediaCardItem] (or plays directly if no album).
void openHomeMediaItem({
  required BuildContext context,
  required AudioService audioService,
  required HomeMediaCardItem item,
  void Function(String albumId)? onOpenAlbumDetail,
  void Function(String playlistId)? onOpenSmartPlaylist,
  VoidCallback? onOpenAlbums,
}) {
  final album = item.album;
  if (album != null && onOpenAlbumDetail != null) {
    onOpenAlbumDetail(album.id);
    return;
  }
  final pid = item.smartPlaylistId;
  if (pid != null && onOpenSmartPlaylist != null) {
    onOpenSmartPlaylist(pid);
    return;
  }
  if (item.track != null) {
    unawaited(audioService.play(track: item.track));
    return;
  }
  onOpenAlbums?.call();
}

/// Plays a [HomeQuickResumeItem] immediately from quick resume shortcuts.
Future<void> playQuickResumeItem({
  required BuildContext context,
  required AudioService audioService,
  required HomeQuickResumeItem item,
  LibraryIndexCache? libraryCache,
  Map<String, SmartPlaylistEvaluation> smartPlaylistEvals = const {},
}) => playHomeMediaItem(
  context: context,
  audioService: audioService,
  libraryCache: libraryCache,
  smartPlaylistEvals: smartPlaylistEvals,
  item: HomeMediaCardItem(
    id: item.id,
    title: item.title,
    subtitle: item.sourceLabel,
    track: item.track,
    album: item.album,
    smartPlaylistId: item.smartPlaylistId,
    sourceLabel: item.sourceLabel,
  ),
);

Future<void> _playCanonicalAlbum({
  ScaffoldMessengerState? messenger,
  required AudioService audioService,
  required CanonicalAlbumSummary album,
  LibraryIndexCache? libraryCache,
}) async {
  final queue = audioService.queue;
  final detail =
      libraryCache?.albumDetailsById[album.id] ??
      await audioService.getAlbumDetail(album.id);
  final ver = detail?.versions.where((v) => v.tracks.isNotEmpty).firstOrNull;
  var tracks = <TrackInfo>[];
  if (detail != null && ver != null) {
    tracks = ver.orderedTrackEntries.map((entry) {
      final vt = entry.track;
      final existing = queue.where((t) => t.id == vt.id).firstOrNull;
      if (existing != null) return existing;
      final ext = vt.externalTrackId;
      final hasUri = ext.contains('/') || ext.contains('\\') || ext.startsWith('http');
      return TrackInfo(
        id: vt.id,
        title: vt.title,
        artist: detail.artistName,
        album: detail.title,
        duration: Duration(milliseconds: vt.durationMs),
        format: AudioFormat(
          codec: AudioCodec.fromString(vt.codec),
          sampleRateHz: vt.sampleRateHz,
          bitDepth: vt.bitDepth,
          channels: 2,
          isDsd: ver.isDsd || vt.isDsd,
        ),
        providerName: ver.provider,
        trackNumber: vt.trackNumber,
        discNumber: vt.discNumber,
        coverUrl: detail.coverUrl,
        filePath: hasUri ? ext : null,
        albumGroupId: detail.id,
        preference: vt.preference,
      );
    }).toList(growable: false);
  }
  if (tracks.isEmpty) {
    final lower = album.title.toLowerCase();
    tracks = queue
        .where((t) => t.album == album.title || t.album.toLowerCase().startsWith(lower))
        .toList(growable: false);
  }
  if (tracks.isEmpty) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('音樂庫中找不到此專輯的可播放曲目')),
    );
    return;
  }
  await audioService.playQueue(tracks, excludeBanned: true);
}

/// Frameless `1:1` square album card with GPU-composited hover lift/play fade
/// and optional [minimalCoverMode] overlay.
class MinimalAlbumCard extends StatefulWidget {
  final HomeMediaCardItem item;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final bool minimalCoverMode;
  final double borderRadius;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final void Function(String albumId)? onOpenAlbumDetail;
  final void Function(String playlistId)? onOpenSmartPlaylist;
  final VoidCallback? onOpenAlbums;
  final Map<String, SmartPlaylistEvaluation> smartPlaylistEvals;

  const MinimalAlbumCard({
    super.key,
    required this.item,
    required this.audioService,
    this.libraryCache,
    this.minimalCoverMode = false,
    this.borderRadius = 12.0,
    this.onTap,
    this.onPlay,
    this.onOpenAlbumDetail,
    this.onOpenSmartPlaylist,
    this.onOpenAlbums,
    this.smartPlaylistEvals = const {},
  });

  @override
  State<MinimalAlbumCard> createState() => _MinimalAlbumCardState();
}

class _MinimalAlbumCardState extends State<MinimalAlbumCard> {
  static const Duration _hoverDuration = Duration(milliseconds: 180);
  static const Curve _hoverCurve = Curves.easeOutCubic;

  bool _hovered = false;
  bool _focused = false;
  bool get _showOverlay => _hovered || _focused;

  void _handleTap() {
    if (widget.onTap != null) {
      widget.onTap!();
      return;
    }
    openHomeMediaItem(
      context: context,
      audioService: widget.audioService,
      item: widget.item,
      onOpenAlbumDetail: widget.onOpenAlbumDetail,
      onOpenSmartPlaylist: widget.onOpenSmartPlaylist,
      onOpenAlbums: widget.onOpenAlbums,
    );
  }

  void _handlePlay() {
    if (widget.onPlay != null) {
      widget.onPlay!();
      return;
    }
    unawaited(
      playHomeMediaItem(
        context: context,
        audioService: widget.audioService,
        item: widget.item,
        libraryCache: widget.libraryCache,
        smartPlaylistEvals: widget.smartPlaylistEvals,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final radius = BorderRadius.circular(widget.borderRadius);
    final item = widget.item;
    final track = item.track;

    return TrackHoverPrefetch(
      track: track,
      enabled: track != null,
      child: RepaintBoundary(
        child: ScrollCardEntrance(
          child: FocusableActionDetector(
            mouseCursor: SystemMouseCursors.click,
            onShowHoverHighlight: (h) {
              if (_hovered != h) setState(() => _hovered = h);
            },
            onShowFocusHighlight: (f) {
              if (_focused != f) setState(() => _focused = f);
            },
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  _handleTap();
                  return null;
                },
              ),
            },
            child: Semantics(
              button: true,
              label: '${item.title} ${item.subtitle}',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _handleTap,
                onSecondaryTapUp: track == null
                    ? null
                    : (d) => showTrackContextMenu(
                          context: context,
                          audioService: widget.audioService,
                          track: track,
                          globalPosition: d.globalPosition,
                          libraryCache: widget.libraryCache,
                        ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildArtworkTile(glass, radius, item),
                    if (!widget.minimalCoverMode) ...[
                      const SizedBox(height: 10),
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: glass.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.1,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: glass.textSecondary, fontSize: 12.0, height: 1.25),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArtworkTile(LuminaGlassTheme glass, BorderRadius radius, HomeMediaCardItem item) {
    return AnimatedScale(
      scale: _hovered ? 1.02 : 1.0,
      duration: _hoverDuration,
      curve: _hoverCurve,
      child: AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = math.max(
              48.0,
              constraints.maxWidth.isFinite ? constraints.maxWidth : 180.0,
            );
            return DecoratedBox(
              decoration: BoxDecoration(borderRadius: radius, boxShadow: glass.coverShadow),
              child: Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _showOverlay ? 1.0 : 0.0,
                        duration: _hoverDuration,
                        curve: _hoverCurve,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: radius,
                            boxShadow: glass.coverHoverShadow,
                          ),
                        ),
                      ),
                    ),
                  ),
                  ClipRRect(
                    borderRadius: radius,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        AlbumArtworkView(
                          track: item.track,
                          album: item.album,
                          size: side,
                          audioService: widget.audioService,
                          libraryCache: widget.libraryCache,
                          fullResolution: false,
                          frameless: true,
                          borderRadius: radius,
                          boxShadow: const [],
                        ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: radius,
                                border: Border.all(
                                  color: Colors.white.withValues(
                                    alpha: glass.isDark ? 0.08 : 0.65,
                                  ),
                                  width: 0.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (widget.minimalCoverMode) _buildHoverOverlay(radius, item),
                        Positioned(right: 10, bottom: 10, child: _buildPlayButton(glass, item)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHoverOverlay(BorderRadius radius, HomeMediaCardItem item) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _showOverlay ? 1.0 : 0.0,
        duration: _hoverDuration,
        curve: _hoverCurve,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0.35, 1.0],
              colors: [Colors.transparent, Color(0xD90A0C12)],
            ),
          ),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 54, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xF5FFFFFF),
                      fontSize: 13.0,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xCCFFFFFF),
                      fontSize: 11.5,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayButton(LuminaGlassTheme glass, HomeMediaCardItem item) {
    final pillBg = glass.isDark ? const Color(0xBD14161B) : const Color(0xDCFFFFFF);
    return AnimatedOpacity(
      opacity: _showOverlay ? 1.0 : 0.0,
      duration: _hoverDuration,
      curve: _hoverCurve,
      child: Tooltip(
        message: '播放 ${item.title}',
        child: Semantics(
          button: true,
          label: '播放 ${item.title}',
          child: GestureDetector(
            key: Key('minimal_card_play_${item.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: _handlePlay,
            child: ClipOval(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: pillBg,
                    border: Border.all(color: glass.glassBorderStrong),
                  ),
                  child: Icon(Icons.play_arrow_rounded, size: 20, color: glass.textPrimary),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
