part of 'now_playing_overlay.dart';

extension _NowPlayingMetadata on NowPlayingOverlayState {
  StreamingProviderMeta? _resolveStreamingMeta(TrackInfo? track) {
    if (track == null || track.providerName.trim().isEmpty) return null;
    for (final meta in StreamingProviderMeta.streamingServices) {
      if (meta.matchesTrackProvider(track.providerName)) {
        return meta;
      }
    }
    return null;
  }

  Widget _buildTrackMetadata(
    TrackInfo? track, {
    required bool centered,
    bool showPills = false,
    double? titleFontSize,
    double? subtitleFontSize,
    double? metaTitleGap,
    double? metaPillGap,
    bool compact = false,
  }) {
    final crossAxis =
        centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final align = centered ? TextAlign.center : TextAlign.start;
    final effectiveSubtitleSize = subtitleFontSize ?? (compact ? 12.5 : 14.0);
    final effectiveTitleGap =
        metaTitleGap ?? (compact ? 2.0 : LuminaTokens.space2xs);
    final effectivePillGap =
        metaPillGap ?? (compact ? 6.0 : LuminaTokens.spaceSm);
    final badgeBoxSize =
        compact ? 15.0 : (effectiveSubtitleSize + 2.0).clamp(16.0, 20.0);

    final artistLabel = track == null
        ? ''
        : (track.hasDistinctAlbumArtist
              ? '${track.artist} (${track.albumArtist})'
              : track.artist);
    final sourceLabel = track == null
        ? ''
        : (track.providerName.trim().isNotEmpty
              ? track.providerName.trim()
              : track.album.trim());
    final metaSubtitle = track == null
        ? ''
        : (sourceLabel.isNotEmpty
              ? '• $artistLabel · $sourceLabel'
              : '• $artistLabel');
    final streamingMeta = _resolveStreamingMeta(track);

    return Column(
      key: const ValueKey('now_playing_hero_metadata'),
      crossAxisAlignment: crossAxis,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track?.title ?? '尚未選擇曲目',
          textAlign: align,
          maxLines: compact ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: LuminaTokens.glassTextPrimary,
            fontSize: titleFontSize ?? (centered ? 25.0 : 16.0),
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: effectiveTitleGap),
        if (streamingMeta != null)
          Row(
            mainAxisSize: centered ? MainAxisSize.min : MainAxisSize.max,
            mainAxisAlignment:
                centered ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              Tooltip(
                message: streamingMeta.name,
                child: KeyedSubtree(
                  key: Key('now_playing_provider_badge_${streamingMeta.kind}'),
                  child: streamingMeta.buildBadge(
                    boxSize: badgeBoxSize,
                    borderRadius: 4,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  metaSubtitle,
                  textAlign: align,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: LuminaTokens.glassTextSecondary,
                    fontSize: effectiveSubtitleSize,
                  ),
                ),
              ),
            ],
          )
        else
          Text(
            metaSubtitle,
            textAlign: align,
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: LuminaTokens.glassTextSecondary,
              fontSize: effectiveSubtitleSize,
            ),
          ),
        if (showPills && track != null) ...[
          SizedBox(height: effectivePillGap),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: centered ? WrapAlignment.center : WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildFormatSpecCapsule(track),
              if (track.id.isNotEmpty && !track.id.startsWith('podcast'))
                Container(
                  decoration: BoxDecoration(
                    color: LuminaTokens.glassPillBg,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: LuminaTokens.glassPillBorder),
                  ),
                  child: PreferenceToggleButton(
                    buttonKey: const Key('now_playing_preference_btn'),
                    audioService: widget.audioService,
                    libraryCache: widget.libraryCache,
                    entityType: 'track',
                    entityId: track.id,
                    preference: track.preference,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildFormatSpecCapsule(TrackInfo track) {
    final tier = getAudioQualityTier(track);
    final style = AudioQualityBadgeStyle.forTier(tier);
    return AnimatedContainer(
      key: const Key('now_playing_format_spec_capsule'),
      duration: LuminaTokens.qualityBadgeTransitionDuration,
      curve: Curves.ease,
      padding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: style.backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: style.borderColor,
          width: 1,
        ),
        boxShadow: style.boxShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            key: const Key('now_playing_format_spec_dot'),
            duration: LuminaTokens.qualityBadgeTransitionDuration,
            curve: Curves.ease,
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: style.textColor,
              boxShadow: style.glowColor != null
                  ? [
                      BoxShadow(
                        color: style.glowColor!,
                        blurRadius: 6,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              track.format.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: style.textColor,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
