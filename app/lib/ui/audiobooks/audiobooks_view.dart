import 'package:material_ui/material_ui.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../services/audio_service.dart';
import '../../services/media_sources_controller.dart';
import '../media/media_source_widgets.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

// ─── Audiobooks View ──────────────────────────────────────────────────────────

class AudiobooksView extends StatefulWidget {
  final AudioService audioService;

  const AudiobooksView({super.key, required this.audioService});

  @override
  State<AudiobooksView> createState() => _AudiobooksViewState();
}

class _AudiobooksViewState extends State<AudiobooksView> {
  final GlideScrollController _scrollController = GlideScrollController();
  final List<_AudiobookItem> _items = [
    _AudiobookItem(
      id: 'ab-001',
      title: '原子習慣',
      author: '詹姆斯．克利爾',
      narrator: '由 AI 語音合成',
      durationLabel: '5 小時 35 分',
      progress: 0.42,
    ),
    _AudiobookItem(
      id: 'ab-002',
      title: '人類大歷史',
      author: '哈拉瑞',
      narrator: '由 AI 語音合成',
      durationLabel: '15 小時 12 分',
      progress: 0.0,
    ),
  ];

  @override
  void initState() {
    super.initState();
    MediaSourcesController.instance.load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            const Icon(
              Icons.menu_book_rounded,
              size: 20,
              color: LuminaTokens.glassTextSecondary,
            ),
            const SizedBox(width: LuminaTokens.spaceSm),
            const Text(
              '有聲書',
              style: TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: () => _showImportDialog(context),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('匯入有聲書', style: TextStyle(fontSize: 12.5)),
              style: OutlinedButton.styleFrom(
                foregroundColor: LuminaTokens.glassTextPrimary,
                backgroundColor: LuminaTokens.glassPillBg,
                side: const BorderSide(color: LuminaTokens.glassPillBorder),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: LuminaTokens.spaceSm,
                  vertical: LuminaTokens.spaceXs,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: LuminaTokens.spaceMd),

        // List
        Expanded(
          child: ListenableBuilder(
            listenable: MediaSourcesController.instance,
            builder: (context, _) {
              final custom = MediaSourcesController.instance.byKind(
                MediaSourceKind.audiobook,
              );
              final totalCount = custom.length + _items.length;
              return SmoothScrollWrapper(
                controller: _scrollController,
                child: ListView.builder(
                  key: const Key('audiobooks_list_view'),
                  controller: _scrollController,
                  padding: const EdgeInsets.only(
                    bottom: LuminaTokens.bottomScrollClearance,
                  ),
                  itemCount: totalCount,
                  itemBuilder: (context, index) {
                    if (index < custom.length) {
                      final e = custom[index];
                      return CustomSourceTile(
                        key: Key('custom_${e.id}'),
                        entry: e,
                        icon: Icons.menu_book_rounded,
                        audioService: widget.audioService,
                      );
                    }
                    final item = _items[index - custom.length];
                    return _AudiobookTile(
                      key: Key('audiobook_tile_${item.id}'),
                      item: item,
                      onPlay: () => _playSample(item),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _playSample(_AudiobookItem item) => widget.audioService.play(
    track: TrackInfo(
      id: item.id,
      title: item.title,
      artist: item.author,
      album: '有聲書',
      duration: const Duration(minutes: 45),
      format: const AudioFormat(
        codec: AudioCodec.mp3,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
      providerName: '有聲書',
    ),
  );

  Future<void> _showImportDialog(BuildContext context) => showAddMediaSourceDialog(
    context,
    kind: MediaSourceKind.audiobook,
    dialogTitle: '匯入有聲書',
    nameHint: '有聲書名稱',
    urlHint: '本機檔案路徑或網址（例如 C:\\Audiobooks\\book.mp3）',
    confirmLabel: '匯入',
    allowFilePicker: true,
  );
}

class _AudiobookItem {
  final String id;
  final String title;
  final String author;
  final String narrator;
  final String durationLabel;
  final double progress; // 0.0–1.0

  const _AudiobookItem({
    required this.id,
    required this.title,
    required this.author,
    required this.narrator,
    required this.durationLabel,
    required this.progress,
  });
}

class _AudiobookTile extends StatelessWidget {
  final _AudiobookItem item;
  final VoidCallback onPlay;

  const _AudiobookTile({super.key, required this.item, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
      hoverColor: LuminaTokens.glassRowHoverBg,
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LuminaTokens.space2xs,
          vertical: LuminaTokens.spaceSm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cover placeholder
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: LuminaTokens.glassPillBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                border: Border.all(color: LuminaTokens.glassCardBorder),
              ),
              child: const Icon(
                Icons.menu_book_rounded,
                size: 28,
                color: LuminaTokens.textMuted,
              ),
            ),
            const SizedBox(width: LuminaTokens.spaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.narrator,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 11.5,
                    ),
                  ),
                  if (item.progress > 0) ...[
                    const SizedBox(height: LuminaTokens.spaceXs),
                    Row(
                      children: [
                        Expanded(
                          child: LinearProgressIndicator(
                            value: item.progress,
                            backgroundColor: LuminaTokens.glassTrackUnplayed,
                            color: LuminaTokens.glassTextPrimary,
                            minHeight: 4,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: LuminaTokens.spaceXs),
                        Text(
                          '${(item.progress * 100).round()}%',
                          style: const TextStyle(
                            color: LuminaTokens.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: LuminaTokens.spaceSm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  item.durationLabel,
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 11.5,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceXs),
                IconButton(
                  icon: const Icon(
                    Icons.play_circle_outline_rounded,
                    size: 24,
                    color: LuminaTokens.glassTextPrimary,
                  ),
                  onPressed: onPlay,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  tooltip: '繼續播放',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}


