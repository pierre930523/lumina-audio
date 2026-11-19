import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../services/audio_service.dart';
import '../../services/media_sources_controller.dart';
import '../theme/lumina_tokens.dart';

const _accentBlue = LuminaTokens.accentBlue;
const _cardBg = LuminaTokens.cardBg;

Future<String?> _pickAudioFileNative() async {
  if (!Platform.isWindows || Platform.environment.containsKey('FLUTTER_TEST')) {
    return null;
  }
  try {
    final res = await Process.run('powershell', [
      '-NoProfile',
      '-STA',
      '-Command',
      "Add-Type -AssemblyName System.Windows.Forms; "
          "\$d = New-Object System.Windows.Forms.OpenFileDialog; "
          "\$d.Filter = 'Audio Files|*.mp3;*.m4a;*.m4b;*.flac;*.wav;*.ogg;*.opus;*.aac|All Files|*.*'; "
          "if (\$d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output \$d.FileName }",
    ]);
    if (res.exitCode == 0) {
      final path = res.stdout.toString().trim();
      if (path.isNotEmpty) return path;
    }
  } catch (_) {}
  return null;
}

/// 通用「新增自訂來源」對話框（名稱 + 網址／本機路徑）。
Future<void> showAddMediaSourceDialog(
  BuildContext context, {
  required String kind,
  required String dialogTitle,
  required String nameHint,
  required String urlHint,
  required String confirmLabel,
  bool allowFilePicker = false,
}) async {
  final nameCtrl = TextEditingController();
  final urlCtrl = TextEditingController();
  InputDecoration deco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: LuminaTokens.textMuted, fontSize: 12),
    filled: true,
    fillColor: LuminaTokens.cardElevatedBg,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
      borderSide: const BorderSide(color: LuminaTokens.borderControl),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
      borderSide: const BorderSide(color: LuminaTokens.borderControl),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
      borderSide: const BorderSide(color: LuminaTokens.focusRing, width: 1.5),
    ),
    contentPadding: const EdgeInsets.symmetric(
      horizontal: LuminaTokens.spaceSm,
      vertical: LuminaTokens.spaceSm,
    ),
  );
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: _cardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
        side: const BorderSide(color: LuminaTokens.borderControl),
      ),
      title: Text(
        dialogTitle,
        style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('media_source_name_field'),
            controller: nameCtrl,
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 13),
            decoration: deco(nameHint),
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('media_source_url_field'),
                  controller: urlCtrl,
                  style: const TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 13,
                  ),
                  decoration: deco(urlHint),
                ),
              ),
              if (allowFilePicker) ...[
                const SizedBox(width: LuminaTokens.spaceXs),
                IconButton(
                  key: const Key('media_source_pick_file_btn'),
                  tooltip: '瀏覽本機檔案',
                  icon: const Icon(Icons.folder_open_rounded, color: _accentBlue),
                  onPressed: () async {
                    final chosen = await _pickAudioFileNative();
                    if (chosen != null) {
                      urlCtrl.text = chosen;
                      if (nameCtrl.text.trim().isEmpty) {
                        final seg = chosen.split(Platform.pathSeparator).last;
                        nameCtrl.text = seg.replaceFirst(RegExp(r'\.[^.]+$'), '');
                      }
                    }
                  },
                ),
              ],
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text(
            '取消',
            style: TextStyle(color: LuminaTokens.textSecondary),
          ),
        ),
        FilledButton(
          key: const Key('media_source_confirm_btn'),
          style: FilledButton.styleFrom(
            backgroundColor: _accentBlue,
            foregroundColor: LuminaTokens.onAccentDark,
          ),
          onPressed: () async {
            final name = nameCtrl.text.trim();
            final url = urlCtrl.text.trim();
            if (name.isEmpty || url.isEmpty) return;
            await MediaSourcesController.instance.add(
              kind: kind,
              title: name,
              url: url,
            );
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

Future<void> playMediaSource(
  BuildContext context,
  AudioService audio,
  MediaSourceEntry entry,
) async {
  try {
    await audio.play(track: entry.toTrack());
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('無法播放「${entry.title}」：$e')));
    }
  }
}

/// 使用者自訂來源列表項目（可播放／刪除）。
class CustomSourceTile extends StatelessWidget {
  final MediaSourceEntry entry;
  final IconData icon;
  final AudioService audioService;

  const CustomSourceTile({
    super.key,
    required this.entry,
    required this.icon,
    required this.audioService,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
      hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.55),
      onTap: () => playMediaSource(context, audioService, entry),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LuminaTokens.spaceXs,
          vertical: LuminaTokens.spaceSm,
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: LuminaTokens.cardElevatedBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                border: Border.all(color: LuminaTokens.borderSubtle),
              ),
              child: Icon(icon, size: 24, color: _accentBlue),
            ),
            const SizedBox(width: LuminaTokens.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '自訂來源 · ${entry.url}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '播放',
              icon: const Icon(
                Icons.play_circle_outline_rounded,
                size: 26,
                color: _accentBlue,
              ),
              onPressed: () => playMediaSource(context, audioService, entry),
            ),
            IconButton(
              tooltip: '移除',
              icon: const Icon(
                Icons.delete_outline_rounded,
                size: 20,
                color: LuminaTokens.textSecondary,
              ),
              onPressed: () => MediaSourcesController.instance.remove(entry.id),
            ),
          ],
        ),
      ),
    );
  }
}

