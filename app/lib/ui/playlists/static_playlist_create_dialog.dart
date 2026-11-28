import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';

/// Frosted Glass modal for creating a new static playlist with optional
/// initial tracks picked from the active queue.
Future<StaticPlaylistDetail?> showCreateStaticPlaylistDialog({
  required BuildContext context,
  required AudioService audioService,
}) {
  return showDialog<StaticPlaylistDetail>(
    context: context,
    barrierColor: LuminaTokens.scrimBg,
    builder: (_) => _CreateStaticPlaylistDialog(audioService: audioService),
  );
}

class _CreateStaticPlaylistDialog extends StatefulWidget {
  final AudioService audioService;

  const _CreateStaticPlaylistDialog({required this.audioService});

  @override
  State<_CreateStaticPlaylistDialog> createState() =>
      _CreateStaticPlaylistDialogState();
}

class _CreateStaticPlaylistDialogState
    extends State<_CreateStaticPlaylistDialog> {
  final TextEditingController _nameCtrl = TextEditingController();
  final Set<String> _selectedTrackIds = <String>{};
  bool _creating = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_creating) return;
    setState(() => _creating = true);
    final name = _nameCtrl.text.trim().isEmpty
        ? '新靜態歌單'
        : _nameCtrl.text.trim();
    final res = await widget.audioService.createStaticPlaylist(
      CreateStaticPlaylistRequest(
        name: name,
        trackIds: _selectedTrackIds.toList(growable: false),
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pop(res);
  }

  @override
  Widget build(BuildContext context) {
    final queueTracks = widget.audioService.queue;
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 460),
        child: FrostedGlassContainer(
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '新增靜態歌單',
                  style: TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceSm),
                TextField(
                  key: const Key('input_static_playlist_name'),
                  controller: _nameCtrl,
                  style: const TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 13.5,
                  ),
                  decoration: InputDecoration(
                    labelText: '歌單名稱',
                    hintText: '例如：深夜試音清單',
                    labelStyle: const TextStyle(
                      color: LuminaTokens.glassTextSecondary,
                    ),
                    hintStyle: const TextStyle(color: LuminaTokens.textMuted),
                    filled: true,
                    fillColor: LuminaTokens.glassPillBg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                      borderSide: const BorderSide(
                        color: LuminaTokens.glassPillBorder,
                      ),
                    ),
                  ),
                ),
                if (queueTracks.isNotEmpty) ...[
                  const SizedBox(height: LuminaTokens.spaceSm),
                  const Text(
                    '從目前曲庫勾選初始曲目（選填）',
                    style: TextStyle(
                      color: LuminaTokens.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: queueTracks.length.clamp(0, 12),
                      itemBuilder: (_, idx) {
                        final t = queueTracks[idx];
                        final checked = _selectedTrackIds.contains(t.id);
                        return CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: checked,
                          title: Text(
                            t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: LuminaTokens.textPrimary,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: Text(
                            t.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                          onChanged: _creating
                              ? null
                              : (v) => setState(() {
                                  if (v == true) {
                                    _selectedTrackIds.add(t.id);
                                  } else {
                                    _selectedTrackIds.remove(t.id);
                                  }
                                }),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: LuminaTokens.spaceSm),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _creating
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: LuminaTokens.spaceXs),
                    FilledButton(
                      key: const Key('btn_confirm_create_static_playlist'),
                      style: FilledButton.styleFrom(
                        backgroundColor: LuminaTokens.glassSwitchOnTrack,
                        foregroundColor: LuminaTokens.onAccentDark,
                      ),
                      onPressed: _creating ? null : _submit,
                      child: const Text('建立歌單'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
