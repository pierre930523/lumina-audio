import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../common/library_export_dialog.dart';
import '../common/track_context_menu.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';
import 'playlist_improver_dialog.dart';
import 'playlist_snapshots_dialog.dart';
import 'static_playlist_create_dialog.dart';

part 'static_playlist_detail_pane.dart';

/// Rail + detail workspace for static playlists with Playlist Improver and
/// Snapshot History / Revert integration.
class StaticPlaylistsPane extends StatefulWidget {
  final AudioService audioService;

  const StaticPlaylistsPane({super.key, required this.audioService});

  @override
  State<StaticPlaylistsPane> createState() => _StaticPlaylistsPaneState();
}

class _StaticPlaylistsPaneState extends State<StaticPlaylistsPane> {
  final GlideScrollController _railScrollController = GlideScrollController();
  final GlideScrollController _chipRailScrollController =
      GlideScrollController();
  List<StaticPlaylistSummary> _playlists = const <StaticPlaylistSummary>[];
  String _activeId = '';
  StaticPlaylistDetail? _detail;
  bool _loadingList = false;
  bool _loadingDetail = false;
  bool _busyAction = false;
  int _detailEpoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPlaylists());
  }

  @override
  void dispose() {
    _railScrollController.dispose();
    _chipRailScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadPlaylists({String? selectId}) async {
    if (mounted) setState(() => _loadingList = true);
    try {
      final list = await widget.audioService.listStaticPlaylists();
      if (!mounted) return;
      var nextId = selectId ?? _activeId;
      if (nextId.isEmpty || !list.any((p) => p.id == nextId)) {
        nextId = list.isNotEmpty ? list.first.id : '';
      }
      setState(() {
        _playlists = list;
        _activeId = nextId;
        _loadingList = false;
      });
      await _loadDetail(nextId);
    } catch (_) {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  Future<void> _loadDetail(String playlistId) async {
    if (playlistId.isEmpty) {
      if (mounted) setState(() => _detail = null);
      return;
    }
    final epoch = ++_detailEpoch;
    if (mounted) setState(() => _loadingDetail = true);
    try {
      final detail = await widget.audioService.getStaticPlaylistDetail(
        playlistId,
      );
      if (!mounted || epoch != _detailEpoch) return;
      setState(() {
        _detail = detail;
        _loadingDetail = false;
      });
    } catch (_) {
      if (!mounted || epoch != _detailEpoch) return;
      setState(() => _loadingDetail = false);
    }
  }

  TrackInfo _trackInfoForSummary(PlaylistTrackSummary s) {
    final existing = widget.audioService.queue
        .where((t) => t.id == s.trackId)
        .firstOrNull;
    if (existing != null) return existing;
    return TrackInfo(
      id: s.trackId,
      title: s.title,
      artist: s.artistName,
      album: s.albumTitle,
      duration: Duration(milliseconds: s.durationMs),
      format: AudioFormat(
        codec: AudioCodec.fromString(s.codec),
        sampleRateHz: s.sampleRateHz > 0 ? s.sampleRateHz : 44100,
        bitDepth: s.bitDepth > 0 ? s.bitDepth : 16,
        channels: 2,
        isDsd: s.isDsd,
      ),
      providerName: s.providerId,
      filePath: s.filePath,
      isrc: s.isrc,
    );
  }

  Future<void> _playDetail(StaticPlaylistDetail detail) async {
    final tracks = detail.items
        .where((i) => !i.isMissing && i.track != null)
        .map((i) => _trackInfoForSummary(i.track!))
        .toList(growable: false);
    if (tracks.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('此靜態歌單中沒有可播放的曲目')),
      );
      return;
    }
    await widget.audioService.playQueue(tracks);
  }

  Future<void> _openCreateDialog() async {
    final created = await showCreateStaticPlaylistDialog(
      context: context,
      audioService: widget.audioService,
    );
    if (created != null && mounted) {
      await _loadPlaylists(selectId: created.playlist.id);
    }
  }

  Future<void> _openImprover(StaticPlaylistSummary summary) async {
    if (_busyAction) return;
    setState(() => _busyAction = true);
    try {
      final report = await widget.audioService.analyzePlaylistImprovements(
        summary.id,
      );
      if (!mounted) return;
      setState(() => _busyAction = false);
      if (report == null) return;
      final applied = await PlaylistImproverDialog.show(
        context: context,
        audioService: widget.audioService,
        report: report,
      );
      if (applied != null && mounted) {
        await _loadPlaylists(selectId: summary.id);
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              '已套用優化：去重 ${applied.duplicatesRemoved}、修復 ${applied.tracksRepaired}、升級 ${applied.tracksUpgraded}（已自動建立快照）',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  Future<void> _openSnapshots(StaticPlaylistSummary summary) async {
    if (_busyAction) return;
    setState(() => _busyAction = true);
    try {
      final snapshots = await widget.audioService.listPlaylistSnapshots(
        summary.id,
      );
      if (!mounted) return;
      setState(() => _busyAction = false);
      final reverted = await PlaylistSnapshotsDialog.show(
        context: context,
        audioService: widget.audioService,
        playlistName: summary.name,
        snapshots: snapshots,
      );
      if (reverted != null && mounted) {
        await _loadPlaylists(selectId: summary.id);
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('已復原歌單快照（共 ${reverted.restoredTrackCount} 首曲目）'),
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  Future<void> _deletePlaylist(StaticPlaylistSummary summary) async {
    final ok = await widget.audioService.deleteStaticPlaylist(summary.id);
    if (ok && mounted) await _loadPlaylists();
  }

  Widget _buildRail(bool isWide) {
    return Container(
      width: isWide ? 248 : double.infinity,
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(LuminaTokens.spaceXs),
            child: FilledButton.icon(
              key: const Key('btn_create_static_playlist'),
              style: FilledButton.styleFrom(
                backgroundColor: LuminaTokens.glassSwitchOnTrack,
                foregroundColor: LuminaTokens.onAccentDark,
              ),
              onPressed: _openCreateDialog,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('新增靜態歌單'),
            ),
          ),
          if (isWide)
            Expanded(
              child: _loadingList && _playlists.isEmpty
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : SmoothScrollWrapper(
                      controller: _railScrollController,
                      child: ListView.builder(
                        controller: _railScrollController,
                        padding: const EdgeInsets.only(
                          bottom: LuminaTokens.bottomScrollClearance,
                        ),
                        itemCount: _playlists.length,
                        itemBuilder: (_, idx) => _buildRailTile(_playlists[idx]),
                      ),
                    ),
            )
          else
            SizedBox(
              height: 44,
              child: ListView.builder(
                controller: _chipRailScrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: _playlists.length,
                itemBuilder: (_, idx) {
                  final pl = _playlists[idx];
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      key: Key('static_playlist_item_${pl.id}'),
                      selected: pl.id == _activeId,
                      showCheckmark: false,
                      label: Text(pl.name),
                      onSelected: (_) {
                        setState(() => _activeId = pl.id);
                        unawaited(_loadDetail(pl.id));
                      },
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRailTile(StaticPlaylistSummary pl) {
    final selected = pl.id == _activeId;
    final radius = BorderRadius.circular(LuminaTokens.radiusSm);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? LuminaTokens.glassNavActiveBg : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          key: Key('static_playlist_item_${pl.id}'),
          borderRadius: radius,
          hoverColor: LuminaTokens.glassRowHoverBg,
          onTap: () {
            setState(() => _activeId = pl.id);
            unawaited(_loadDetail(pl.id));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pl.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected
                        ? Colors.white
                        : LuminaTokens.glassTextSecondary,
                    fontSize: 13.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                Text(
                  '${pl.trackCount} 首${pl.unresolvedCount > 0 ? " · ${pl.unresolvedCount} 失效" : ""}',
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detailPane = _StaticPlaylistDetailPane(
      audioService: widget.audioService,
      detail: _detail,
      loading: _loadingDetail,
      busyAction: _busyAction,
      onPlay: _playDetail,
      onImprove: _openImprover,
      onOpenSnapshots: _openSnapshots,
      onDelete: _deletePlaylist,
    );

    return LayoutBuilder(
      key: const Key('static_playlists_pane'),
      builder: (_, constraints) {
        final isWide = constraints.maxWidth >= 720;
        return isWide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildRail(true),
                  const SizedBox(width: 14),
                  Expanded(child: detailPane),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildRail(false),
                  const SizedBox(height: 10),
                  Expanded(child: detailPane),
                ],
              );
      },
    );
  }
}
