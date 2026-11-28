part of 'podcast_detail_page.dart';

extension _PodcastDetailEpisodeRow on _PodcastDetailPageState {
  Widget _buildEpisodeRow({
    required PodcastEpisode episode,
    required PlaybackState playbackState,
    required bool isCompact,
  }) {
    final trackId = episode.toTrack().id;
    final isCurrentTrack = playbackState.track?.id == trackId;
    final isPlaying =
        isCurrentTrack && playbackState.status == PlaybackStatus.playing;
    final isLoading = isCurrentTrack &&
        (playbackState.status == PlaybackStatus.loading ||
            playbackState.status == PlaybackStatus.buffering);
    final progress = _store.progressFor(trackId);
    final durText = _formatDuration(episode.duration);
    final metaParts = <String>[
      if (episode.publishedLabel != null &&
          episode.publishedLabel!.trim().isNotEmpty)
        episode.publishedLabel!.trim(),
      if (durText.isNotEmpty) durText,
    ];

    return TrackHoverPrefetch(
      trackIdentity: episode.externalAudioUrl ?? episode.videoId,
      trackBuilder: episode.toTrack,
      child: Container(
        key: Key('podcast_episode_tile_${episode.videoId}'),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: isCurrentTrack
              ? LuminaTokens.glassCardActiveBg
              : LuminaTokens.glassCardBg,
          borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
          border: Border.all(
            color: isCurrentTrack
                ? LuminaTokens.glassCoverRim
                : LuminaTokens.glassCardBorder,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
          hoverColor: LuminaTokens.glassRowHoverBg,
          onTap: () {
            if (isCurrentTrack) {
              widget.audioService.togglePlayPause();
            } else {
              _playEpisode(episode);
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildArtworkBox(
                  url: episode.artworkUrl ?? _show?.artworkUrl,
                  width: isCompact ? 52 : 64,
                  height: isCompact ? 52 : 64,
                  borderRadius: 8,
                  iconSize: 24,
                  targetSize: 300,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        episode.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrentTrack
                              ? Colors.white
                              : LuminaTokens.glassTextPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      if (metaParts.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              metaParts.join(' · '),
                              style: const TextStyle(
                                color: LuminaTokens.textMuted,
                                fontSize: 11.5,
                              ),
                            ),
                            if (progress != null &&
                                (progress.positionSeconds > 0 ||
                                    progress.completed))
                              Container(
                                key: Key(
                                  'podcast_episode_progress_${episode.videoId}',
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: progress.completed
                                      ? LuminaTokens.statusSuccess
                                          .withValues(alpha: 0.14)
                                      : LuminaTokens.glassPillBg,
                                  borderRadius: BorderRadius.circular(
                                    LuminaTokens.radiusPill,
                                  ),
                                  border: progress.completed
                                      ? null
                                      : Border.all(
                                          color: LuminaTokens.glassPillBorder,
                                        ),
                                ),
                                child: Text(
                                  progress.completed
                                      ? '已播完'
                                      : '已播 ${progress.formattedPosition}',
                                  style: TextStyle(
                                    color: progress.completed
                                        ? LuminaTokens.statusSuccess
                                        : LuminaTokens.glassTextSecondary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (episode.description != null &&
                          episode.description!.trim().isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          episode.description!.trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.textSecondary,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ],
                      if (progress != null &&
                          progress.positionSeconds > 0 &&
                          progress.durationSeconds > 0) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: progress.progressFraction,
                            minHeight: 3,
                            backgroundColor: LuminaTokens.glassTrackUnplayed,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              progress.completed
                                  ? LuminaTokens.statusSuccess
                                  : LuminaTokens.glassTextPrimary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isCurrentTrack) ...[
                      IconButton(
                        key: Key('btn_episode_skip_back_${episode.videoId}'),
                        tooltip: '倒退 15 秒',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: EdgeInsets.zero,
                        icon: const Icon(
                          Icons.replay_10_rounded,
                          size: 19,
                          color: LuminaTokens.textSecondary,
                        ),
                        onPressed: () => PodcastPlaybackTracker.seekRelative(
                          widget.audioService,
                          PodcastPlaybackTracker.skipBackwardDelta,
                          store: _store,
                        ),
                      ),
                      IconButton(
                        key: Key('btn_episode_skip_forward_${episode.videoId}'),
                        tooltip: '快轉 30 秒',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: EdgeInsets.zero,
                        icon: const Icon(
                          Icons.forward_30_rounded,
                          size: 19,
                          color: LuminaTokens.textSecondary,
                        ),
                        onPressed: () => PodcastPlaybackTracker.seekRelative(
                          widget.audioService,
                          PodcastPlaybackTracker.skipForwardDelta,
                          store: _store,
                        ),
                      ),
                    ],
                    IconButton(
                      key: Key('btn_play_episode_${episode.videoId}'),
                      tooltip: isPlaying ? '暫停單集' : '播放單集',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      padding: EdgeInsets.zero,
                      icon: isLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: LuminaTokens.glassTextPrimary,
                              ),
                            )
                          : Icon(
                              isPlaying
                                  ? Icons.pause_circle_filled_rounded
                                  : Icons.play_circle_fill_rounded,
                              size: 28,
                              color: LuminaTokens.glassTextPrimary,
                            ),
                      onPressed: () {
                        if (isCurrentTrack) {
                          widget.audioService.togglePlayPause();
                        } else {
                          _playEpisode(episode);
                        }
                      },
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

  Widget _buildArtworkBox({
    required String? url,
    required double width,
    required double height,
    required double borderRadius,
    required double iconSize,
    int? targetSize,
  }) {
    Widget placeholder() => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: LuminaTokens.glassPillBg,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: LuminaTokens.glassSidebarBorder),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.podcasts_rounded,
            size: iconSize,
            color: LuminaTokens.textMuted,
          ),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: StreamingCoverImage(
        url: url,
        targetSize: targetSize ?? (width >= 120 ? 1200 : 300),
        width: width,
        height: height,
        fallbackBuilder: (_) => placeholder(),
      ),
    );
  }
}
