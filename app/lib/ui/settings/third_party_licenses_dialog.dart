import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../services/streaming/yt_dlp_service.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';

/// Shared scrollable dialog displaying bundled `THIRD_PARTY_LICENSES.txt`
/// (yt-dlp Unlicense + PyInstaller bundled licenses, Deno MIT, FFmpeg LGPL).
class ThirdPartyLicensesDialog extends StatefulWidget {
  final YtDlpService ytDlpService;

  const ThirdPartyLicensesDialog({
    super.key,
    required this.ytDlpService,
  });

  static Future<void> show(
    BuildContext context, {
    YtDlpService? ytDlpService,
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) => ThirdPartyLicensesDialog(
        ytDlpService: ytDlpService ?? YtDlpService.instance,
      ),
    );
  }

  @override
  State<ThirdPartyLicensesDialog> createState() =>
      _ThirdPartyLicensesDialogState();
}

class _ThirdPartyLicensesDialogState extends State<ThirdPartyLicensesDialog> {
  final ScrollController _scrollController = ScrollController();
  late final Future<List<String>> _chunksFuture;

  @override
  void initState() {
    super.initState();
    _chunksFuture = widget.ytDlpService.readThirdPartyLicenses().then(
      _chunkLicenseText,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Splits large license texts (~5,000 lines) into lightweight chunks so
  /// [ListView.builder] opens smoothly at 60 FPS with full text selection.
  static List<String> _chunkLicenseText(String text) {
    final lines = LineSplitter.split(text).toList(growable: false);
    if (lines.isEmpty) return const <String>[''];
    const linesPerChunk = 32;
    final chunks = <String>[];
    for (var i = 0; i < lines.length; i += linesPerChunk) {
      final end = (i + linesPerChunk < lines.length)
          ? i + linesPerChunk
          : lines.length;
      chunks.add(lines.sublist(i, end).join('\n'));
    }
    return chunks;
  }

  @override
  Widget build(BuildContext context) {
    final licensePath = widget.ytDlpService.status.licenseFilePath;

    return Dialog(
      key: const Key('third_party_licenses_dialog'),
      backgroundColor: LuminaTokens.cardBg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
        side: const BorderSide(color: LuminaTokens.borderControl),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 740,
          maxHeight: 560,
          minWidth: 420,
          minHeight: 320,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LuminaTokens.spaceMd + LuminaTokens.space2xs,
                LuminaTokens.spaceMd,
                LuminaTokens.spaceSm,
                LuminaTokens.spaceSm,
              ),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: LuminaTokens.accentBlue.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusSm,
                      ),
                    ),
                    child: const Icon(
                      Icons.description_outlined,
                      size: 18,
                      color: LuminaTokens.accentBlue,
                    ),
                  ),
                  const SizedBox(width: LuminaTokens.spaceSm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '第三方開源授權（yt-dlp / Deno / FFmpeg）',
                          style: TextStyle(
                            color: LuminaTokens.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          licensePath ?? '內建開源元件授權摘要',
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
                    tooltip: '關閉',
                    onPressed: () => Navigator.of(context).pop(),
                    style: LuminaSettingsStyles.iconButtonStyle(),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
            ),
            const Divider(color: LuminaTokens.borderSubtle, height: 1),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(LuminaTokens.spaceMd),
                child: Container(
                  decoration: BoxDecoration(
                    color: LuminaTokens.canvasBg,
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                    border: Border.all(color: LuminaTokens.borderSubtle),
                  ),
                  child: FutureBuilder<List<String>>(
                    future: _chunksFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: LuminaTokens.accentBlue,
                            ),
                          ),
                        );
                      }

                      final chunks =
                          snapshot.data ?? const <String>['無法讀取開源授權內容。'];
                      return Scrollbar(
                        controller: _scrollController,
                        thumbVisibility: true,
                        child: SelectionArea(
                          child: ListView.builder(
                            key: const Key('third_party_licenses_list'),
                            controller: _scrollController,
                            padding: const EdgeInsets.all(LuminaTokens.spaceMd),
                            itemCount: chunks.length,
                            itemBuilder: (context, index) => Padding(
                              padding: EdgeInsets.only(
                                bottom: index + 1 < chunks.length ? 2 : 0,
                              ),
                              child: Text(
                                chunks[index],
                                style: const TextStyle(
                                  color: LuminaTokens.textSecondary,
                                  fontFamily: 'Consolas',
                                  fontSize: 12,
                                  height: 1.45,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            const Divider(color: LuminaTokens.borderSubtle, height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LuminaTokens.spaceMd,
                vertical: LuminaTokens.spaceSm,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    key: const Key('btn_close_licenses_dialog'),
                    onPressed: () => Navigator.of(context).pop(),
                    style: LuminaSettingsStyles.outlinedButtonStyle(),
                    child: const Text('關閉'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
