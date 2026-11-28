import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/smart_playlist.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../../services/smart_playlist_service.dart';
import '../common/frosted_glass_container.dart';
import '../common/library_export_dialog.dart';
import '../common/preference_toggle_button.dart';
import '../common/track_context_menu.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';
import 'static_playlists_pane.dart';

part 'smart_playlist_detail_pane.dart';
part 'smart_playlist_editor_dialog.dart';

/// Unified FocusQuery-backed Smart Playlists workspace.
class SmartPlaylistsView extends StatefulWidget {
  final AudioService audioService;
  final SmartPlaylistService playlistService;
  final LibraryIndexCache? libraryCache;
  final String? selectedPlaylistId;
  final ValueChanged<String>? onSelectPlaylist;
  final void Function(SmartPlaylistItem playlist)? onEditRules;

  const SmartPlaylistsView({
    super.key,
    required this.audioService,
    required this.playlistService,
    this.libraryCache,
    this.selectedPlaylistId,
    this.onSelectPlaylist,
    this.onEditRules,
  });

  static Future<SmartPlaylistItem?> showCreateDialog({
    required BuildContext context,
    required SmartPlaylistService service,
    SmartPlaylistItem? editing,
    FocusQuery? initialFocusQuery,
  }) {
    return showDialog<SmartPlaylistItem>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (ctx) => _SmartPlaylistEditorDialog(
        service: service,
        editing: editing,
        initialFocusQuery: initialFocusQuery,
      ),
    );
  }

  @override
  State<SmartPlaylistsView> createState() => _SmartPlaylistsViewState();
}

class _SmartPlaylistsViewState extends State<SmartPlaylistsView> {
  final GlideScrollController _railScrollController = GlideScrollController();
  final GlideScrollController _chipRailScrollController =
      GlideScrollController();
  bool _showingStaticPlaylists = false;
  String _activeId = '';
  SmartPlaylistEvaluation? _evaluation;
  bool _evaluating = false;
  int _evalEpoch = 0;

  @override
  void initState() {
    super.initState();
    final all = widget.playlistService.playlists;
    _activeId =
        widget.selectedPlaylistId ?? (all.isNotEmpty ? all.first.id : '');
    widget.playlistService.addListener(_onServiceChanged);
    if (!widget.playlistService.loadedOnce && !widget.playlistService.loading) {
      unawaited(widget.playlistService.load());
    } else {
      _evaluateActive();
    }
  }

  @override
  void didUpdateWidget(covariant SmartPlaylistsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlistService != widget.playlistService) {
      oldWidget.playlistService.removeListener(_onServiceChanged);
      widget.playlistService.addListener(_onServiceChanged);
    }
    if (widget.selectedPlaylistId != null &&
        widget.selectedPlaylistId != _activeId) {
      _activeId = widget.selectedPlaylistId!;
      _evaluateActive();
    }
  }

  @override
  void dispose() {
    widget.playlistService.removeListener(_onServiceChanged);
    _railScrollController.dispose();
    _chipRailScrollController.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    final all = widget.playlistService.playlists;
    if (all.isNotEmpty && !all.any((p) => p.id == _activeId)) {
      _activeId = all.first.id;
    }
    _evaluateActive();
  }

  SmartPlaylistItem? get _activePlaylist {
    final all = widget.playlistService.playlists;
    return all.where((p) => p.id == _activeId).firstOrNull ??
        (all.isNotEmpty ? all.first : null);
  }

  Future<void> _evaluateActive() async {
    final target = _activePlaylist;
    if (target == null) {
      if (mounted) {
        setState(() {
          _evaluation = null;
          _evaluating = false;
        });
      }
      return;
    }
    final epoch = ++_evalEpoch;
    if (mounted) {
      setState(() => _evaluating = true);
    }
    try {
      final eval = await widget.playlistService.evaluatePlaylist(target.id);
      if (!mounted || epoch != _evalEpoch) return;
      setState(() {
        _evaluation = eval;
        _evaluating = false;
      });
    } catch (_) {
      if (!mounted || epoch != _evalEpoch) return;
      setState(() => _evaluating = false);
    }
  }

  void _selectPlaylist(String id) {
    setState(() => _activeId = id);
    widget.onSelectPlaylist?.call(id);
    _evaluateActive();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.playlistService,
      builder: (context, _) {
        final playlists = widget.playlistService.playlists;
        final active = _activePlaylist;
        final matchedTracks = _evaluation?.playlist.id == active?.id
            ? (_evaluation?.tracks ?? const <TrackInfo>[])
            : const <TrackInfo>[];
        final totalMatched = _evaluation?.playlist.id == active?.id
            ? (_evaluation?.totalMatched ?? matchedTracks.length)
            : 0;

        return LayoutBuilder(
          key: const Key('smart_playlists_view'),
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 720;

            final modeSwitcher = FrostedGlassContainer(
              blurSigma: LuminaTokens.glassPillBlur,
              color: LuminaTokens.glassPillBg,
              borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
              border: Border.all(color: LuminaTokens.glassPillBorder),
              padding: const EdgeInsets.all(3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildModeSegment(
                    buttonKey: const Key('tab_smart_playlists'),
                    label: '智慧歌單',
                    selected: !_showingStaticPlaylists,
                    onTap: () => setState(() => _showingStaticPlaylists = false),
                  ),
                  const SizedBox(width: 4),
                  _buildModeSegment(
                    buttonKey: const Key('tab_static_playlists'),
                    label: '靜態歌單',
                    selected: _showingStaticPlaylists,
                    onTap: () => setState(() => _showingStaticPlaylists = true),
                  ),
                ],
              ),
            );

            final headerRow = Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.auto_awesome_rounded,
                            color: LuminaTokens.glassTextPrimary,
                            size: 20,
                          ),
                          SizedBox(width: 8),
                          Text(
                            '智慧播放清單',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      modeSwitcher,
                    ],
                  ),
                  if (!_showingStaticPlaylists)
                    FilledButton.icon(
                      key: const Key('btn_create_smart_playlist'),
                      style: FilledButton.styleFrom(
                        backgroundColor: LuminaTokens.glassSwitchOnTrack,
                        foregroundColor: LuminaTokens.onAccentDark,
                      ),
                      onPressed: () async {
                        final created =
                            await SmartPlaylistsView.showCreateDialog(
                              context: context,
                              service: widget.playlistService,
                            );
                        if (created != null && mounted) {
                          _selectPlaylist(created.id);
                        }
                      },
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('新增智慧歌單'),
                    ),
                ],
              ),
            );

            final playlistRail = Container(
              width: isWide ? 248 : double.infinity,
              decoration: BoxDecoration(
                color: LuminaTokens.glassCardBg,
                borderRadius: BorderRadius.circular(
                  LuminaTokens.glassCardRadius,
                ),
                border: Border.all(color: LuminaTokens.glassCardBorder),
              ),
              child: isWide
                  ? SmoothScrollWrapper(
                      controller: _railScrollController,
                      child: ListView.builder(
                        controller: _railScrollController,
                        padding: const EdgeInsets.only(
                          top: LuminaTokens.spaceXs,
                          bottom: LuminaTokens.bottomScrollClearance,
                        ),
                        itemCount: playlists.length,
                        itemBuilder: (context, index) => _buildPlaylistTile(
                          playlists[index],
                          active?.id == playlists[index].id,
                        ),
                      ),
                    )
                  : SizedBox(
                      height: 46,
                      child: ListView.builder(
                        controller: _chipRailScrollController,
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: LuminaTokens.spaceSm,
                          vertical: LuminaTokens.spaceXs,
                        ),
                        itemCount: playlists.length,
                        itemBuilder: (context, index) {
                          final sp = playlists[index];
                          final selected = active?.id == sp.id;
                          return Padding(
                            padding: const EdgeInsets.only(
                              right: LuminaTokens.spaceXs,
                            ),
                            child: ChoiceChip(
                              key: Key('smart_playlist_item_${sp.id}'),
                              selected: selected,
                              showCheckmark: false,
                              surfaceTintColor: Colors.transparent,
                              backgroundColor: LuminaTokens.glassPillBg,
                              selectedColor:
                                  LuminaTokens.glassSegmentSelectedBg,
                              side: BorderSide(
                                color: selected
                                    ? LuminaTokens.glassSegmentSelectedBorder
                                    : LuminaTokens.glassPillBorder,
                              ),
                              onSelected: (_) => _selectPlaylist(sp.id),
                              label: Text(
                                sp.name,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: selected
                                      ? Colors.white
                                      : LuminaTokens.glassTextSecondary,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            );

            final detailPane = _SmartPlaylistDetailPane(
              active: active,
              matchedTracks: matchedTracks,
              totalMatched: totalMatched,
              evaluating: _evaluating,
              audioService: widget.audioService,
              libraryCache: widget.libraryCache,
              playlistService: widget.playlistService,
              onEditRules: widget.onEditRules,
              onRefreshEval: _evaluateActive,
              onSelectPlaylist: _selectPlaylist,
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                headerRow,
                Expanded(
                  child: _showingStaticPlaylists
                      ? StaticPlaylistsPane(audioService: widget.audioService)
                      : isWide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            playlistRail,
                            const SizedBox(width: 14),
                            Expanded(child: detailPane),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            playlistRail,
                            const SizedBox(height: 10),
                            Expanded(child: detailPane),
                          ],
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildModeSegment({
    required Key buttonKey,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final radius = BorderRadius.circular(LuminaTokens.radiusSm);
    return Material(
      color: selected
          ? LuminaTokens.glassSegmentSelectedBg
          : Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        key: buttonKey,
        borderRadius: radius,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: selected
                ? Border.all(color: LuminaTokens.glassSegmentSelectedBorder)
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : LuminaTokens.glassTextSecondary,
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaylistTile(SmartPlaylistItem sp, bool selected) {
    final radius = BorderRadius.circular(LuminaTokens.radiusSm);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? LuminaTokens.glassNavActiveBg : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          key: Key('smart_playlist_item_${sp.id}'),
          borderRadius: radius,
          hoverColor: LuminaTokens.glassRowHoverBg,
          onTap: () => _selectPlaylist(sp.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(
                  sp.isPinned
                      ? Icons.push_pin_rounded
                      : Icons.auto_awesome_rounded,
                  size: 15,
                  color: selected
                      ? Colors.white
                      : LuminaTokens.glassTextSecondary,
                ),
                const SizedBox(width: LuminaTokens.spaceXs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sp.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? Colors.white
                              : LuminaTokens.glassTextSecondary,
                          fontSize: 13.5,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      if (sp.description.trim().isNotEmpty)
                        Text(
                          sp.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.textMuted,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
