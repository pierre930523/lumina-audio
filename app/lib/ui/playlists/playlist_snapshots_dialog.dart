import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';

/// Frosted Glass modal displaying static playlist snapshot history with
/// one-click revert support.
class PlaylistSnapshotsDialog extends StatefulWidget {
  final AudioService audioService;
  final String playlistName;
  final List<PlaylistSnapshotRecord> snapshots;

  const PlaylistSnapshotsDialog({
    super.key,
    required this.audioService,
    required this.playlistName,
    required this.snapshots,
  });

  static Future<RevertPlaylistSnapshotResult?> show({
    required BuildContext context,
    required AudioService audioService,
    required String playlistName,
    required List<PlaylistSnapshotRecord> snapshots,
  }) {
    return showDialog<RevertPlaylistSnapshotResult>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (_) => PlaylistSnapshotsDialog(
        audioService: audioService,
        playlistName: playlistName,
        snapshots: snapshots,
      ),
    );
  }

  @override
  State<PlaylistSnapshotsDialog> createState() =>
      _PlaylistSnapshotsDialogState();
}

class _PlaylistSnapshotsDialogState extends State<PlaylistSnapshotsDialog> {
  String? _revertingId;
  String? _error;

  Future<void> _revert(PlaylistSnapshotRecord snap) async {
    if (_revertingId != null) return;
    setState(() {
      _revertingId = snap.id;
      _error = null;
    });
    try {
      final result = await widget.audioService.revertPlaylistSnapshot(snap.id);
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _revertingId = null;
          _error = '復原快照失敗，請稍後再試';
        });
        return;
      }
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _revertingId = null;
        _error = '復原失敗：$e';
      });
    }
  }

  String _formatTimestamp(String raw) {
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) return raw;
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${parsed.year}-${pad(parsed.month)}-${pad(parsed.day)} '
        '${pad(parsed.hour)}:${pad(parsed.minute)}:${pad(parsed.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final snaps = widget.snapshots;

    return Dialog(
      key: const Key('playlist_snapshots_dialog'),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 500),
        child: FrostedGlassContainer(
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.history_rounded,
                      color: LuminaTokens.glassTextPrimary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '復原歷史 · ${widget.playlistName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.glassTextPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '關閉',
                      onPressed: _revertingId != null
                          ? null
                          : () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: LuminaTokens.textSecondary,
                      ),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: LuminaTokens.spaceXs),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: LuminaTokens.statusError,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                const Divider(color: LuminaTokens.glassCardDivider, height: 18),
                Expanded(
                  child: snaps.isEmpty
                      ? const Center(
                          child: Text(
                            '尚無復原快照，套用優化建議後將自動建立快照',
                            style: TextStyle(color: LuminaTokens.textMuted),
                          ),
                        )
                      : ListView.separated(
                          itemCount: snaps.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: LuminaTokens.spaceXs),
                          itemBuilder: (_, idx) {
                            final snap = snaps[idx];
                            final busy = _revertingId == snap.id;
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: LuminaTokens.spaceSm,
                                vertical: LuminaTokens.spaceSm,
                              ),
                              decoration: BoxDecoration(
                                color: LuminaTokens.glassCardBg,
                                borderRadius: BorderRadius.circular(
                                  LuminaTokens.radiusSm,
                                ),
                                border: Border.all(
                                  color: LuminaTokens.glassCardBorder,
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.restore_rounded,
                                    color: LuminaTokens.accentBlue,
                                    size: 18,
                                  ),
                                  const SizedBox(width: LuminaTokens.spaceSm),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _formatTimestamp(snap.createdAt),
                                          style: const TextStyle(
                                            color: LuminaTokens.textPrimary,
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${snap.trackCount} 首曲目 · 來源：${snap.reason}',
                                          style: const TextStyle(
                                            color: LuminaTokens.textMuted,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: LuminaTokens.spaceXs),
                                  FilledButton.icon(
                                    key: Key('btn_revert_snapshot_${snap.id}'),
                                    style: FilledButton.styleFrom(
                                      backgroundColor:
                                          LuminaTokens.glassSwitchOnTrack,
                                      foregroundColor:
                                          LuminaTokens.onAccentDark,
                                    ),
                                    onPressed: _revertingId != null
                                        ? null
                                        : () => _revert(snap),
                                    icon: const Icon(
                                      Icons.undo_rounded,
                                      size: 16,
                                    ),
                                    label: Text(busy ? '復原中...' : '一鍵復原'),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: LuminaTokens.spaceSm),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: LuminaTokens.glassTextSecondary,
                    ),
                    onPressed: _revertingId != null
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('關閉'),
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
