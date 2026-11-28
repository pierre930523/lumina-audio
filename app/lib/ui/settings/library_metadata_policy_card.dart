import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/ingestion_models.dart';
import '../../services/audio_service.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';

/// Settings card for configuring the global `default_metadata_policy`
/// (`'file'` default vs `'cloud'`).
class LibraryMetadataPolicyCard extends StatefulWidget {
  final AudioService audioService;
  final VoidCallback? onLibraryChanged;

  const LibraryMetadataPolicyCard({
    super.key,
    required this.audioService,
    this.onLibraryChanged,
  });

  @override
  State<LibraryMetadataPolicyCard> createState() =>
      _LibraryMetadataPolicyCardState();
}

class _LibraryMetadataPolicyCardState extends State<LibraryMetadataPolicyCard> {
  MetadataPolicy _policy = MetadataPolicy.file;
  bool _saving = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPolicy());
  }

  @override
  void didUpdateWidget(covariant LibraryMetadataPolicyCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.audioService, widget.audioService)) {
      unawaited(_loadPolicy());
    }
  }

  Future<void> _loadPolicy() async {
    try {
      final current = await widget.audioService.getDefaultMetadataPolicy();
      if (!mounted) return;
      setState(() {
        _policy = current == MetadataPolicy.cloud
            ? MetadataPolicy.cloud
            : MetadataPolicy.file;
      });
    } catch (_) {}
  }

  Future<void> _selectPolicy(MetadataPolicy next) async {
    if (_saving || next == _policy) return;
    final previous = _policy;
    setState(() {
      _policy = next;
      _saving = true;
      _statusMessage = null;
    });
    try {
      final ok = await widget.audioService.setDefaultMetadataPolicy(next);
      if (!mounted) return;
      if (ok) {
        widget.onLibraryChanged?.call();
        setState(() {
          _statusMessage = '已更新全域預設策略為「${next.displayLabel}」';
        });
      } else {
        setState(() {
          _policy = previous;
          _statusMessage = '無法儲存詮釋資料策略設定';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _policy = previous;
        _statusMessage = '無法儲存詮釋資料策略設定';
      });
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsGroupCard(
      key: const Key('metadata_policy_section'),
      title: '詮釋資料優先順序',
      description:
          '設定套用「跟隨全域」策略之專輯與曲目的預設標籤來源。使用者手動編輯始終具有最高優先權，且不會被重新掃描或雲端補全覆蓋。',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LuminaTokens.spaceMd + LuminaTokens.space2xs,
            LuminaTokens.spaceXs,
            LuminaTokens.spaceMd + LuminaTokens.space2xs,
            LuminaTokens.spaceMd,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '全域預設來源',
                style: TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: LuminaTokens.space2xs),
              const Text(
                '預設採用本機音訊檔案內嵌標籤（file）；切換為優先雲端資料時，將以 MusicBrainz / Discogs 補全欄位優先顯示。',
                style: TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: LuminaTokens.spaceSm),
              DecoratedBox(
                decoration: LuminaSettingsStyles.segmentedCapsuleDecoration(),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final option in const [
                        MetadataPolicy.file,
                        MetadataPolicy.cloud,
                      ])
                        LuminaSettingsStyles.frostedSegmentChip(
                          key: Key('chip_global_meta_policy_${option.toJson()}'),
                          label: option.displayLabel,
                          selected: _policy == option,
                          disabled: _saving,
                          onSelected: _saving
                              ? null
                              : (_) => unawaited(_selectPolicy(option)),
                        ),
                    ],
                  ),
                ),
              ),
              if (_statusMessage != null) ...[
                const SizedBox(height: LuminaTokens.spaceXs),
                Text(
                  _statusMessage!,
                  key: const Key('metadata_policy_status_label'),
                  style: const TextStyle(
                    color: LuminaTokens.statusSuccess,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
