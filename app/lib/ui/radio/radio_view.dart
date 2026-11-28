import 'package:material_ui/material_ui.dart';

import '../../services/audio_service.dart';
import '../../services/media_sources_controller.dart';
import '../media/media_source_widgets.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

// ─── Radio View ───────────────────────────────────────────────────────────────

class RadioView extends StatefulWidget {
  final AudioService audioService;

  const RadioView({super.key, required this.audioService});

  @override
  State<RadioView> createState() => _RadioViewState();
}

class _RadioViewState extends State<RadioView> {
  final GlideScrollController _scrollController = GlideScrollController();
  final List<_RadioStation> _stations = [
    _RadioStation(
      id: 'radio-001',
      name: 'Classical KING FM',
      genre: '古典樂',
      location: '美國西雅圖',
      streamUrl: 'https://king.fm/stream',
      bitrate: '320 kbps AAC',
    ),
    _RadioStation(
      id: 'radio-002',
      name: 'NHK World Radio Japan',
      genre: '新聞 / 資訊',
      location: '日本東京',
      streamUrl: 'https://nhkworld.jp/stream',
      bitrate: '128 kbps AAC',
    ),
    _RadioStation(
      id: 'radio-003',
      name: 'Radio Paradise',
      genre: '另類搖滾',
      location: '美國加州',
      streamUrl: 'https://radioparadise.com/stream',
      bitrate: '320 kbps MP3',
    ),
  ];

  String? _playingId;

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
        Row(
          children: [
            const Icon(
              Icons.radio_rounded,
              size: 20,
              color: LuminaTokens.glassTextSecondary,
            ),
            const SizedBox(width: LuminaTokens.spaceSm),
            const Text(
              '廣播電台',
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
              label: const Text('新增電台', style: TextStyle(fontSize: 12.5)),
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
        Expanded(
          child: ListenableBuilder(
            listenable: MediaSourcesController.instance,
            builder: (context, _) {
              final custom = MediaSourcesController.instance.byKind(
                MediaSourceKind.radio,
              );
              final totalCount = custom.length + _stations.length;
              return SmoothScrollWrapper(
                controller: _scrollController,
                child: ListView.builder(
                  key: const Key('radio_list_view'),
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
                        icon: Icons.radio_rounded,
                        audioService: widget.audioService,
                      );
                    }
                    final s = _stations[index - custom.length];
                    return _RadioTile(
                      key: Key('radio_tile_${s.id}'),
                      station: s,
                      isPlaying: _playingId == s.id,
                      onPlay: () {
                        setState(() => _playingId = s.id);
                        playMediaSource(
                          context,
                          widget.audioService,
                          MediaSourceEntry(
                            id: s.id,
                            kind: MediaSourceKind.radio,
                            title: s.name,
                            url: s.streamUrl,
                          ),
                        );
                      },
                      onStop: () {
                        setState(() => _playingId = null);
                        widget.audioService.stop();
                      },
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

  Future<void> _showAddDialog(BuildContext context) => showAddMediaSourceDialog(
    context,
    kind: MediaSourceKind.radio,
    dialogTitle: '新增廣播電台',
    nameHint: '電台名稱',
    urlHint: '串流網址（http / https）',
    confirmLabel: '新增',
  );

}

class _RadioStation {
  final String id;
  final String name;
  final String genre;
  final String location;
  final String streamUrl;
  final String bitrate;

  const _RadioStation({
    required this.id,
    required this.name,
    required this.genre,
    required this.location,
    required this.streamUrl,
    required this.bitrate,
  });
}

class _RadioTile extends StatelessWidget {
  final _RadioStation station;
  final bool isPlaying;
  final VoidCallback onPlay;
  final VoidCallback onStop;

  const _RadioTile({
    super.key,
    required this.station,
    required this.isPlaying,
    required this.onPlay,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
      hoverColor: LuminaTokens.glassRowHoverBg,
      onTap: isPlaying ? onStop : onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LuminaTokens.space2xs,
          vertical: LuminaTokens.spaceSm,
        ),
        child: Row(
          children: [
            // Live indicator / icon
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: isPlaying
                    ? LuminaTokens.glassCardActiveBg
                    : LuminaTokens.glassPillBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                border: Border.all(
                  color: isPlaying
                      ? LuminaTokens.glassCoverRim
                      : LuminaTokens.glassCardBorder,
                  width: 1.5,
                ),
              ),
              child: Icon(
                isPlaying ? Icons.graphic_eq_rounded : Icons.radio_rounded,
                size: 24,
                color: isPlaying
                    ? Colors.white
                    : LuminaTokens.glassTextSecondary,
              ),
            ),
            const SizedBox(width: LuminaTokens.spaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (isPlaying) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: LuminaTokens.glassNavActiveBg,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: LuminaTokens.glassCoverRim,
                            ),
                          ),
                          child: const Text(
                            'LIVE',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          station.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isPlaying
                                ? Colors.white
                                : LuminaTokens.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${station.genre} · ${station.location}',
                    maxLines: 1,
                    style: const TextStyle(
                      color: LuminaTokens.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    station.bitrate,
                    style: const TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: LuminaTokens.spaceSm),
            IconButton(
              icon: Icon(
                isPlaying
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline_rounded,
                size: 26,
                color: LuminaTokens.glassTextPrimary,
              ),
              onPressed: isPlaying ? onStop : onPlay,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              tooltip: isPlaying ? '停止' : '播放',
            ),
          ],
        ),
      ),
    );
  }
}


