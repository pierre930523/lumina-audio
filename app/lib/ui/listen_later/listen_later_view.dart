import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../../services/listen_later_controller.dart';
import '../artwork/album_artwork_view.dart';
import '../artwork/streaming_cover_image.dart';
import '../common/frosted_glass_container.dart';
import '../common/track_context_menu.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

part 'listen_later_item_card.dart';

/// Listen Later workspace showing Pending and Listened queues across local
/// library items and external streaming snapshots, with inline note editing,
/// playback, status toggling, and one-click promotion to the library DB.
class ListenLaterView extends StatefulWidget {
  final AudioService audioService;
  final ListenLaterController controller;
  final LibraryIndexCache? libraryCache;
  final void Function(String albumId)? onOpenAlbumDetail;
  final void Function(StreamingAlbum album)? onOpenStreamingAlbum;
  final Future<void> Function(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
  })? onPlayStreamingTrack;
  final VoidCallback? onLibraryPromoted;

  const ListenLaterView({
    super.key,
    required this.audioService,
    required this.controller,
    this.libraryCache,
    this.onOpenAlbumDetail,
    this.onOpenStreamingAlbum,
    this.onPlayStreamingTrack,
    this.onLibraryPromoted,
  });

  @override
  State<ListenLaterView> createState() => _ListenLaterViewState();
}

class _ListenLaterViewState extends State<ListenLaterView> {
  final GlideScrollController _scrollController = GlideScrollController();
  String _selectedStatus = 'pending';
  final Set<String> _busyIds = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.controller.refresh());
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _playItem(ListenLaterItem item) async {
    if (item.isLibrary) {
      if (item.isAlbum && item.entityId != null) {
        final detail = await widget.audioService.getAlbumDetail(item.entityId!);
        final ver = detail?.versions.where((v) => v.tracks.isNotEmpty).firstOrNull;
        if (detail != null && ver != null) {
          final tracks = ver.orderedTrackEntries
              .map(
                (e) => TrackInfo(
                  id: e.track.id,
                  title: e.track.title,
                  artist: detail.artistName,
                  album: detail.title,
                  duration: Duration(milliseconds: e.track.durationMs),
                  format: AudioFormat(
                    codec: AudioCodec.fromString(e.track.codec),
                    sampleRateHz: e.track.sampleRateHz,
                    bitDepth: e.track.bitDepth,
                    channels: 2,
                    isDsd: ver.isDsd || e.track.isDsd,
                  ),
                  providerName: ver.provider,
                  trackNumber: e.track.trackNumber,
                  discNumber: e.track.discNumber,
                  coverUrl: detail.coverUrl,
                  albumGroupId: detail.id,
                  preference: e.track.preference,
                ),
              )
              .toList(growable: false);
          if (!mounted) return;
          if (tracks.every((t) => t.preference == -1)) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(content: Text('此專輯所有曲目皆已封鎖')),
            );
            return;
          }
          await widget.audioService.playQueue(tracks, excludeBanned: true);
          return;
        }
      }
      if (item.isTrack && item.entityId != null) {
        final all = await widget.audioService.getLibraryTracks(limit: 5000);
        final match =
            all.where((t) => t.id == item.entityId).firstOrNull ??
            widget.audioService.queue
                .where((t) => t.id == item.entityId)
                .firstOrNull;
        if (match != null) {
          await widget.audioService.play(track: match);
          return;
        }
      }
      if (item.isAlbum &&
          item.entityId != null &&
          widget.onOpenAlbumDetail != null) {
        widget.onOpenAlbumDetail!(item.entityId!);
        return;
      }
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('找不到此曲庫項目的可播放音軌')),
        );
      }
      return;
    }

    // External streaming item
    final providerId = item.providerId ?? 'qobuz';
    final externalId = item.externalId ?? item.id;
    if (item.isAlbum) {
      final album = StreamingAlbum(
        id: externalId,
        providerKind: providerId,
        title: item.title,
        artist: item.artistName,
        coverUrl: item.coverUrl,
        trackCount: item.trackCount,
      );
      if (widget.onOpenStreamingAlbum != null) {
        widget.onOpenStreamingAlbum!(album);
        return;
      }
    }

    final meta = item.parseMetadata() ?? const <String, dynamic>{};
    final track = TrackInfo(
      id: '$providerId:$externalId',
      title: item.title,
      artist: item.artistName.isNotEmpty ? item.artistName : '未知藝術家',
      album: item.albumTitle.isNotEmpty ? item.albumTitle : item.title,
      duration: Duration(
        milliseconds: (meta['duration_ms'] as num?)?.toInt() ?? 0,
      ),
      format: AudioFormat(
        codec: AudioCodec.fromString(meta['codec']?.toString()),
        sampleRateHz: (meta['sample_rate_hz'] as num?)?.toInt() ?? 44100,
        bitDepth: (meta['bit_depth'] as num?)?.toInt() ?? 16,
        channels: 2,
      ),
      providerName:
          StreamingProviderMeta.byKind(providerId)?.name ?? providerId,
      coverUrl: item.coverUrl,
      externalAlbumId: meta['external_album_id']?.toString(),
    );
    if (widget.onPlayStreamingTrack != null) {
      await widget.onPlayStreamingTrack!(track);
    } else {
      await widget.audioService.play(track: track);
    }
  }

  Future<void> _editNote(ListenLaterItem item) async {
    final saved = await showDialog<String>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (_) => _ListenLaterNoteDialog(item: item),
    );
    if (saved == null || !mounted) return;
    await widget.controller.updateNote(item.id, saved);
  }

  Future<void> _promoteItem(ListenLaterItem item) async {
    if (_busyIds.contains(item.id)) return;
    setState(() => _busyIds.add(item.id));
    try {
      final res = await widget.controller.promote(item.id);
      if (!mounted) return;
      if (res != null) {
        widget.onLibraryPromoted?.call();
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('已將「${item.title}」收編至曲庫')),
        );
      } else {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('收編失敗：無法取得完整曲目資訊')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          backgroundColor: LuminaTokens.statusErrorBg,
          content: Text('收編至曲庫失敗：$e'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _busyIds.remove(item.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final pending = widget.controller.pendingItems;
        final listened = widget.controller.listenedItems;
        final items = _selectedStatus == 'pending' ? pending : listened;

        return Column(
          key: const Key('listen_later_view'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.watch_later_rounded,
                        size: 20,
                        color: LuminaTokens.accentBlue,
                      ),
                      SizedBox(width: 8),
                      Text(
                        '稍後收聽',
                        style: TextStyle(
                          color: LuminaTokens.glassTextPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        key: const Key('listen_later_tab_pending'),
                        selected: _selectedStatus == 'pending',
                        showCheckmark: false,
                        surfaceTintColor: Colors.transparent,
                        backgroundColor: LuminaTokens.glassPillBg,
                        selectedColor: LuminaTokens.glassSegmentSelectedBg,
                        side: BorderSide(
                          color: _selectedStatus == 'pending'
                              ? LuminaTokens.glassSegmentSelectedBorder
                              : LuminaTokens.glassPillBorder,
                        ),
                        onSelected: (_) =>
                            setState(() => _selectedStatus = 'pending'),
                        label: Text(
                          '待聽 (${pending.length})',
                          style: TextStyle(
                            color: _selectedStatus == 'pending'
                                ? Colors.white
                                : LuminaTokens.glassTextSecondary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      ChoiceChip(
                        key: const Key('listen_later_tab_listened'),
                        selected: _selectedStatus == 'listened',
                        showCheckmark: false,
                        surfaceTintColor: Colors.transparent,
                        backgroundColor: LuminaTokens.glassPillBg,
                        selectedColor: LuminaTokens.glassSegmentSelectedBg,
                        side: BorderSide(
                          color: _selectedStatus == 'listened'
                              ? LuminaTokens.glassSegmentSelectedBorder
                              : LuminaTokens.glassPillBorder,
                        ),
                        onSelected: (_) =>
                            setState(() => _selectedStatus = 'listened'),
                        label: Text(
                          '已聽 (${listened.length})',
                          style: TextStyle(
                            color: _selectedStatus == 'listened'
                                ? Colors.white
                                : LuminaTokens.glassTextSecondary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: widget.controller.loading && items.isEmpty
                  ? const Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: LuminaTokens.glassTextPrimary,
                      ),
                    )
                  : items.isEmpty
                  ? Center(
                      child: Text(
                        _selectedStatus == 'pending'
                            ? '待聽清單目前為空，可從專輯卡片、搜尋或串流頁面快速加入'
                            : '尚無已聽項目',
                        style: const TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 13.5,
                        ),
                      ),
                    )
                  : SmoothScrollWrapper(
                      controller: _scrollController,
                      child: ListView.separated(
                        key: const Key('listen_later_list'),
                        controller: _scrollController,
                        padding: const EdgeInsets.only(
                          bottom: LuminaTokens.bottomScrollClearance,
                        ),
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, idx) {
                          final item = items[idx];
                          return _ListenLaterItemCard(
                            key: Key('listen_later_item_${item.id}'),
                            item: item,
                            busy: _busyIds.contains(item.id),
                            audioService: widget.audioService,
                            libraryCache: widget.libraryCache,
                            onPlay: () => unawaited(_playItem(item)),
                            onEditNote: () => unawaited(_editNote(item)),
                            onToggleStatus: () => unawaited(
                              widget.controller.markStatus(
                                item.id,
                                item.isPending ? 'listened' : 'pending',
                              ),
                            ),
                            onPromote: item.isExternal && !item.isPromoted
                                ? () => unawaited(_promoteItem(item))
                                : null,
                            onRemove: () =>
                                unawaited(widget.controller.remove(item.id)),
                          );
                        },
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}
