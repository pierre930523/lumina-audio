import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';

/// Displays complete technical file, audio stream, and analysis information
/// for a single track.
Future<void> showTrackFileInfoDialog({
  required BuildContext context,
  required AudioService audioService,
  required TrackInfo track,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: LuminaTokens.scrimBg,
    builder: (_) =>
        _TrackFileInfoDialog(audioService: audioService, track: track),
  );
}

class _TrackFileInfoDialog extends StatefulWidget {
  final AudioService audioService;
  final TrackInfo track;

  const _TrackFileInfoDialog({
    required this.audioService,
    required this.track,
  });

  @override
  State<_TrackFileInfoDialog> createState() => _TrackFileInfoDialogState();
}

class _TrackFileInfoDialogState extends State<_TrackFileInfoDialog> {
  TrackFileInfo? _info;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await widget.audioService.getTrackFileInfo(widget.track.id);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return '不適用（串流或未記錄）';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB ($bytes B)';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB ($bytes B)';
  }

  String _formatDuration(int durationMs) {
    final totalSecs = (durationMs / 1000).round();
    final mins = totalSecs ~/ 60;
    final secs = totalSecs % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final fmt = info?.format ?? widget.track.format;
    final path = info?.filePath ?? widget.track.filePath ?? '';
    final container = info?.containerFormat ?? fmt.codec.displayName;
    final bitrate = info?.bitrateKbps ?? widget.track.format.bitrateKbps;
    final durationMs = info?.durationMs ?? widget.track.duration.inMilliseconds;

    return Dialog(
      key: const Key('track_file_info_dialog'),
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: FrostedGlassContainer(
          color: LuminaTokens.cardBg.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: LuminaTokens.borderControl),
          padding: const EdgeInsets.all(22),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      color: LuminaTokens.accentBlue,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '檔案與音訊資訊',
                            style: TextStyle(
                              color: LuminaTokens.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            info?.effectiveLayer.title ?? widget.track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: LuminaTokens.textSecondary,
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
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: LuminaTokens.cardElevatedBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: LuminaTokens.borderSubtle),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              '檔案完整路徑',
                              style: TextStyle(
                                color: LuminaTokens.textMuted,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            if (path.isNotEmpty)
                              TextButton.icon(
                                key: const Key('btn_copy_track_path'),
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: path));
                                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                    const SnackBar(
                                      content: Text('已複製檔案路徑'),
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                },
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                ),
                                icon: const Icon(Icons.copy_rounded, size: 13),
                                label: const Text(
                                  '複製路徑',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          path.isNotEmpty ? path : '（雲端串流或無本地檔案路徑）',
                          style: const TextStyle(
                            color: LuminaTokens.textPrimary,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _InfoRow(label: '容器 / 編碼格式', value: container),
                  _InfoRow(
                    label: '取樣率',
                    value: AudioFormat.formatSampleRateKhz(fmt.sampleRateHz),
                  ),
                  _InfoRow(
                    label: '位元深度',
                    value: fmt.isDsd ? '1-bit (DSD)' : '${fmt.bitDepth}-bit',
                  ),
                  _InfoRow(label: '聲道數', value: '${fmt.channels} 聲道'),
                  _InfoRow(
                    label: '位元率',
                    value: bitrate != null && bitrate > 0
                        ? '$bitrate kbps'
                        : '未記錄',
                  ),
                  _InfoRow(
                    label: '檔案大小',
                    value: _formatBytes(info?.fileSizeBytes),
                  ),
                  _InfoRow(label: '曲目長度', value: _formatDuration(durationMs)),
                  if (info != null) ...[
                    const Divider(height: 20, color: LuminaTokens.borderSubtle),
                    _InfoRow(
                      label: '檔案完整性檢查',
                      value: info.corruptionStatus.displayLabel,
                    ),
                    if (info.integratedLufs != null)
                      _InfoRow(
                        label: '整合響度 / 真峰值',
                        value:
                            '${info.integratedLufs!.toStringAsFixed(1)} LUFS / ${(info.truePeakDb ?? 0).toStringAsFixed(1)} dBTP',
                      ),
                    if (info.replayGainTrackDb != null)
                      _InfoRow(
                        label: 'ReplayGain 增益',
                        value:
                            '${info.replayGainTrackDb!.toStringAsFixed(2)} dB',
                      ),
                    if (info.analysisError != null &&
                        info.analysisError!.trim().isNotEmpty)
                      _InfoRow(
                        label: '分析錯誤訊息',
                        value: info.analysisError!,
                      ),
                  ],
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: FilledButton.styleFrom(
                        backgroundColor: LuminaTokens.accentBlue,
                        foregroundColor: LuminaTokens.onAccentDark,
                      ),
                      child: const Text('關閉'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: const TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
