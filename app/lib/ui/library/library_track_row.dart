import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../common/preference_toggle_button.dart';
import '../common/track_context_menu.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';

/// Interactive library track list row supporting multi-select, right-click
/// context menus, tri-state preference toggle, quick actions, and navigation.
class LibraryTrackRow extends StatelessWidget {
  final TrackInfo track;
  final bool isPlayingTrack;
  final bool multiSelectMode;
  final bool isSelected;
  final AudioService? audioService;
  final LibraryIndexCache? libraryCache;
  final VoidCallback onTap;
  final VoidCallback onToggleSelect;
  final VoidCallback onPlay;
  final VoidCallback onAddToQueue;
  final VoidCallback? onOpenAlbum;
  final VoidCallback? onOpenArtist;
  final VoidCallback? onManageTags;
  final ValueChanged<int>? onPreferenceChanged;

  const LibraryTrackRow({
    super.key,
    required this.track,
    required this.isPlayingTrack,
    required this.multiSelectMode,
    required this.isSelected,
    this.audioService,
    this.libraryCache,
    required this.onTap,
    required this.onToggleSelect,
    required this.onPlay,
    required this.onAddToQueue,
    this.onOpenAlbum,
    this.onOpenArtist,
    this.onManageTags,
    this.onPreferenceChanged,
  });

  Future<void> _showContextMenu(
    BuildContext context, {
    Offset? globalPosition,
    BuildContext? anchorContext,
  }) async {
    final svc = audioService;
    if (svc == null) return;
    await showTrackContextMenu(
      context: context,
      audioService: svc,
      track: track,
      globalPosition: globalPosition,
      anchorContext: anchorContext,
      libraryCache: libraryCache,
      currentPreference: track.preference,
      onPreferenceChanged: onPreferenceChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isBanned = track.preference == -1;
    final highlightBg = isSelected
        ? LuminaTokens.accentBlue.withValues(alpha: 0.16)
        : (isPlayingTrack ? LuminaTokens.glassNavActiveBg : Colors.transparent);

    return TrackHoverPrefetch(
      track: track,
      child: GestureDetector(
        onSecondaryTapUp: (details) =>
            _showContextMenu(context, globalPosition: details.globalPosition),
        child: Opacity(
          opacity: isBanned ? 0.48 : 1.0,
          child: Material(
            color: highlightBg,
            borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            child: ListTile(
              key: Key('queue_track_${track.id}'),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                side: isSelected
                    ? BorderSide(
                        color: LuminaTokens.accentBlue.withValues(alpha: 0.55),
                      )
                    : BorderSide.none,
              ),
              hoverColor: LuminaTokens.glassRowHoverBg,
              leading: multiSelectMode || isSelected
                  ? InkWell(
                      key: Key('track_select_checkbox_${track.id}'),
                      onTap: onToggleSelect,
                      borderRadius: BorderRadius.circular(6),
                      child: Icon(
                        isSelected
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        color: isSelected
                            ? LuminaTokens.accentBlue
                            : LuminaTokens.textSecondary,
                        size: 20,
                      ),
                    )
                  : Icon(
                      isPlayingTrack
                          ? Icons.equalizer_rounded
                          : Icons.music_note_rounded,
                      color: isPlayingTrack
                          ? Colors.white
                          : LuminaTokens.textSecondary,
                    ),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isPlayingTrack
                            ? Colors.white
                            : LuminaTokens.glassTextPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (isBanned) ...[
                    const SizedBox(width: 8),
                    const BannedStatusPill(),
                  ],
                ],
              ),
              subtitle: Text(
                '${track.artist} • ${track.album} • ${track.format.label}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: LuminaTokens.textMuted),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (audioService != null)
                    PreferenceToggleButton(
                      buttonKey: Key('btn_track_pref_${track.id}'),
                      audioService: audioService!,
                      libraryCache: libraryCache,
                      entityType: 'track',
                      entityId: track.id,
                      preference: track.preference,
                      onChanged: onPreferenceChanged,
                    ),
                  Builder(
                    builder: (btnCtx) => IconButton(
                      key: Key('btn_track_more_${track.id}'),
                      tooltip: '更多曲目選項',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 30,
                        minHeight: 30,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.more_horiz_rounded,
                        size: 18,
                        color: LuminaTokens.textMuted,
                      ),
                      onPressed: () =>
                          _showContextMenu(btnCtx, anchorContext: btnCtx),
                    ),
                  ),
                ],
              ),
              onTap: onTap,
            ),
          ),
        ),
      ),
    );
  }
}
