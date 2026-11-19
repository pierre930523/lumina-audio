import 'package:material_ui/material_ui.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../services/audio_service.dart';
import '../../services/media_sources_controller.dart';
import '../media/media_source_widgets.dart';
import '../theme/lumina_tokens.dart';

// ─── Podcasts View ────────────────────────────────────────────────────────────

class PodcastsView extends StatefulWidget {
  final AudioService audioService;

  const PodcastsView({super.key, required this.audioService});

  @override
  State<PodcastsView> createState() => _PodcastsViewState();
}

class _PodcastsViewState extends State<PodcastsView> {
  static const _accentBlue = LuminaTokens.accentBlue;

  final List<_PodcastItem> _podcasts = [
    _PodcastItem(
      id: 'pod-001',
      title: '法客電台',
      publisher: '法律白話文運動',
      episodeCount: 312,
      latestEpisode: '第 312 集：憲法法庭的攻防',
    ),
    _PodcastItem(
      id: 'pod-002',
      title: 'The Vergecast',
      publisher: 'The Verge',
      episodeCount: 580,
      latestEpisode: 'Ep. 580: AI is everywhere',
    ),
  ];

  @override
  void initState() {
    super.initState();
    MediaSourcesController.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.podcasts_rounded, size: 20, color: _accentBlue),
            const SizedBox(width: LuminaTokens.spaceSm),
            const Text(
              'Podcast',
              style: TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: () => _showAddDialog(context),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('新增 Podcast', style: TextStyle(fontSize: 12.5)),
              style: OutlinedButton.styleFrom(
                foregroundColor: _accentBlue,
                side: const BorderSide(color: LuminaTokens.borderControl),
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
        Expanded(
          child: ListenableBuilder(
            listenable: MediaSourcesController.instance,
            builder: (context, _) {
              final custom = MediaSourcesController.instance.byKind(
                MediaSourceKind.podcast,
              );
              final totalCount = custom.length + _podcasts.length;
              return ListView.builder(
                key: const Key('podcasts_list_view'),
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
                      icon: Icons.podcasts_rounded,
                      audioService: widget.audioService,
                    );
                  }
                  final item = _podcasts[index - custom.length];
                  return _PodcastTile(
                    key: Key('podcast_tile_${item.id}'),
                    item: item,
                    onPlay: () => _playSample(item),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _playSample(_PodcastItem item) => widget.audioService.play(
    track: TrackInfo(
      id: item.id,
      title: item.latestEpisode,
      artist: item.publisher,
      album: item.title,
      duration: const Duration(minutes: 32),
      format: const AudioFormat(
        codec: AudioCodec.mp3,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
      providerName: 'Podcast',
    ),
  );

  Future<void> _showAddDialog(BuildContext context) => showAddMediaSourceDialog(
    context,
    kind: MediaSourceKind.podcast,
    dialogTitle: '新增 Podcast',
    nameHint: '節目名稱',
    urlHint: '音訊網址或本機路徑（https://…/episode.mp3）',
    confirmLabel: '新增',
  );
}

class _PodcastItem {
  final String id;
  final String title;
  final String publisher;
  final int episodeCount;
  final String latestEpisode;

  const _PodcastItem({
    required this.id,
    required this.title,
    required this.publisher,
    required this.episodeCount,
    required this.latestEpisode,
  });
}

class _PodcastTile extends StatelessWidget {
  final _PodcastItem item;
  final VoidCallback onPlay;

  static const _accentBlue = LuminaTokens.accentBlue;

  const _PodcastTile({super.key, required this.item, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
      hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.55),
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LuminaTokens.space2xs,
          vertical: LuminaTokens.spaceSm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: LuminaTokens.cardElevatedBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                border: Border.all(color: LuminaTokens.borderSubtle),
              ),
              child: const Icon(
                Icons.podcasts_rounded,
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
                    item.publisher,
                    maxLines: 1,
                    style: const TextStyle(
                      color: LuminaTokens.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: LuminaTokens.space2xs),
                  Text(
                    '最新：${item.latestEpisode}',
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
            const SizedBox(width: LuminaTokens.spaceSm),
            Column(
              children: [
                Text(
                  '${item.episodeCount} 集',
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
                    color: _accentBlue,
                  ),
                  onPressed: onPlay,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  tooltip: '播放最新集數',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}


