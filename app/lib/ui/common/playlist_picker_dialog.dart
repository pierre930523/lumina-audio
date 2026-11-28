import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';

/// Opens a Liquid Glass picker to add [track] to an existing static playlist
/// or create a new static playlist containing [track].
Future<bool> showPlaylistPickerDialog({
  required BuildContext context,
  required AudioService audioService,
  required TrackInfo track,
}) async {
  final added = await showDialog<bool>(
    context: context,
    barrierColor: LuminaTokens.scrimBg,
    builder: (_) =>
        _PlaylistPickerDialog(audioService: audioService, track: track),
  );
  return added == true;
}

class _PlaylistPickerDialog extends StatefulWidget {
  final AudioService audioService;
  final TrackInfo track;

  const _PlaylistPickerDialog({
    required this.audioService,
    required this.track,
  });

  @override
  State<_PlaylistPickerDialog> createState() => _PlaylistPickerDialogState();
}

class _PlaylistPickerDialogState extends State<_PlaylistPickerDialog> {
  final TextEditingController _newNameController = TextEditingController();
  List<StaticPlaylistSummary> _playlists = const <StaticPlaylistSummary>[];
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  @override
  void dispose() {
    _newNameController.dispose();
    super.dispose();
  }

  Future<void> _loadPlaylists() async {
    try {
      final list = await widget.audioService.listStaticPlaylists();
      if (!mounted) return;
      setState(() {
        _playlists = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '無法載入播放清單：$e';
        _loading = false;
      });
    }
  }

  Future<void> _addToExisting(StaticPlaylistSummary playlist) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final res = await widget.audioService.addTracksToStaticPlaylist(
        playlist.id,
        AddStaticPlaylistTracksRequest(trackIds: <String>[widget.track.id]),
      );
      if (!mounted) return;
      if (res != null) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('已將「${widget.track.title}」加入播放清單「${playlist.name}」')),
        );
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _submitting = false;
          _error = '加入播放清單失敗';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '加入播放清單失敗：$e';
      });
    }
  }

  Future<void> _createAndAdd() async {
    final name = _newNameController.text.trim();
    if (_submitting || name.isEmpty) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final created = await widget.audioService.createStaticPlaylist(
        CreateStaticPlaylistRequest(
          name: name,
          trackIds: <String>[widget.track.id],
        ),
      );
      if (!mounted) return;
      if (created != null) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('已建立播放清單「$name」並加入曲目')),
        );
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _submitting = false;
          _error = '建立播放清單失敗';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '建立播放清單失敗：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 520),
        child: FrostedGlassContainer(
          color: LuminaTokens.cardBg.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: LuminaTokens.borderControl),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.playlist_add_rounded,
                    color: LuminaTokens.accentBlue,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '加入播放清單',
                          style: TextStyle(
                            color: LuminaTokens.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          widget.track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close_rounded,
                      color: LuminaTokens.textSecondary,
                      size: 18,
                    ),
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(false),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('field_new_playlist_name'),
                      controller: _newNameController,
                      enabled: !_submitting,
                      style: const TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        hintText: '輸入新播放清單名稱...',
                        hintStyle: const TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 13,
                        ),
                        isDense: true,
                        filled: true,
                        fillColor: LuminaTokens.cardElevatedBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: LuminaTokens.borderSubtle,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      onSubmitted: (_) => _createAndAdd(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('btn_create_playlist_and_add'),
                    onPressed: _submitting ? null : _createAndAdd,
                    style: FilledButton.styleFrom(
                      backgroundColor: LuminaTokens.accentBlue,
                      foregroundColor: LuminaTokens.onAccentDark,
                    ),
                    child: const Text('建立並加入'),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: LuminaTokens.statusError,
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Flexible(
                child: _loading
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _playlists.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 28),
                          child: Text(
                            '尚無靜態播放清單，可於上方直接建立。',
                            style: TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _playlists.length,
                        separatorBuilder: (_, _) => const Divider(
                          height: 1,
                          color: LuminaTokens.borderSubtle,
                        ),
                        itemBuilder: (context, index) {
                          final pl = _playlists[index];
                          return Material(
                            type: MaterialType.transparency,
                            child: ListTile(
                              key: Key('playlist_picker_item_${pl.id}'),
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              leading: const Icon(
                                Icons.queue_music_rounded,
                                color: LuminaTokens.textSecondary,
                                size: 18,
                              ),
                              title: Text(
                                pl.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: LuminaTokens.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              subtitle: Text(
                                '${pl.trackCount} 首曲目',
                                style: const TextStyle(
                                  color: LuminaTokens.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                              trailing: const Icon(
                                Icons.add_rounded,
                                color: LuminaTokens.accentBlue,
                                size: 18,
                              ),
                              onTap: _submitting ? null : () => _addToExisting(pl),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
