part of 'album_detail_page.dart';

extension _AlbumDetailHero on _AlbumDetailPageState {
  Widget _buildCover({required double size}) {
    final title = _detail?.title ?? _summaryFallback?.title ?? '';
    final artist = _detail?.artistName ?? _summaryFallback?.artist ?? '';
    final coverUrl = _detail?.coverUrl ?? _summaryFallback?.coverUrl;
    return KeyedSubtree(
      key: const Key('album_cover_view'),
      child: AlbumCoverGalleryTrigger(
        imageCount: _albumAssets?.images.length ?? 0,
        onOpenGallery: _openAlbumImageGallery,
        child: AlbumArtworkView(
          key: ValueKey('album_detail_cover_${widget.albumId}_$_coverRevision'),
          album: CanonicalAlbumSummary(
            id: widget.albumId,
            title: title,
            artist: artist,
            coverUrl: coverUrl,
          ),
          size: size,
          revision: _coverRevision,
          audioService: widget.audioService,
          libraryCache: widget.libraryCache,
          fullResolution: true,
          coverTargetSize: 1200,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [
            BoxShadow(
              color: Color(0x77000000),
              blurRadius: 32,
              offset: Offset(0, 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroMeta(
    CanonicalAlbumDetail detail,
    AlbumVersionInfo? ver, {
    required bool isWide,
  }) {
    final unifiedMetadata = AlbumDetailPage.formatUnifiedMetadata(ver);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Album Title (large bold white, wrapping cleanly)
        Text(
          detail.title,
          key: const Key('album_hero_title'),
          style: TextStyle(
            color: Colors.white,
            fontSize: isWide ? 26 : 22,
            fontWeight: FontWeight.w800,
            height: 1.2,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 8),

        // Hoverable & clickable artist name directly below title
        RepaintBoundary(
          child: _ClickableArtistLink(
            key: const Key('album_hero_artist'),
            artistName: detail.artistName,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            defaultColor: LuminaTokens.glassTextSecondary,
            hoverColor: Colors.white,
            onTap: () => _handleOpenArtist(detail.artistName, detail),
          ),
        ),

        // Release Year, Audio Format, Metadata Policy, Overrides & Custom Tags (inline single-row pill Wrap)
        if (detail.releaseYear != null ||
            ver != null ||
            detail.hasUserEdits ||
            _overrides.isNotEmpty ||
            detail.metaPolicy != MetadataPolicy.inherit ||
            !widget.albumId.startsWith('streaming:')) ...[
          const SizedBox(height: 8),
          Wrap(
            key: const Key('album_detail_tags_wrap'),
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (detail.releaseYear != null)
                Text(
                  '${detail.releaseYear}',
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              if (ver != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: LuminaTokens.glassPillBg,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: LuminaTokens.glassPillBorder,
                    ),
                  ),
                  child: Text(
                    ver.formatSummary,
                    style: const TextStyle(
                      color: LuminaTokens.glassTextPrimary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (detail.metaPolicy != MetadataPolicy.inherit)
                Container(
                  key: const Key('album_policy_badge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: LuminaTokens.accentBlue.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: LuminaTokens.accentBlue.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Text(
                    detail.metaPolicy.displayLabel,
                    style: const TextStyle(
                      color: LuminaTokens.accentBlue,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (detail.hasUserEdits || _overrides.isNotEmpty)
                Container(
                  key: const Key('album_override_badge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: LuminaTokens.statusSuccess.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: LuminaTokens.statusSuccess.withValues(alpha: 0.45),
                    ),
                  ),
                  child: const Text(
                    '已自訂',
                    style: TextStyle(
                      color: LuminaTokens.statusSuccess,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (!widget.albumId.startsWith('streaming:')) ...[
                for (final tag in _albumTags)
                  Container(
                    key: Key('album_detail_tag_chip_${tag.id}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: parseLuminaTagColor(
                        tag.color,
                      ).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: parseLuminaTagColor(
                          tag.color,
                        ).withValues(alpha: 0.48),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: parseLuminaTagColor(tag.color),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          tag.name,
                          style: const TextStyle(
                            color: LuminaTokens.glassTextPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                Material(
                  color: LuminaTokens.glassPillBg,
                  shape: const StadiumBorder(
                    side: BorderSide(color: LuminaTokens.glassPillBorder),
                  ),
                  child: InkWell(
                    key: const Key('btn_album_manage_tags'),
                    customBorder: const StadiumBorder(),
                    hoverColor: LuminaTokens.glassPillHoverBg,
                    onTap: () => _promptManageAlbumTags(detail),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.add_rounded,
                            size: 13,
                            color: LuminaTokens.glassTextSecondary,
                          ),
                          SizedBox(width: 3),
                          Text(
                            '管理標籤',
                            style: TextStyle(
                              color: LuminaTokens.glassTextSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],

        const SizedBox(height: 10),

        // Single-line unified metadata row: '總時長 · 音檔格式 · 取樣率 · 位元深度 · 曲目數'
        Text(
          unifiedMetadata,
          key: const Key('album_unified_metadata_row'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: LuminaTokens.textSecondary,
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
        ),

        const SizedBox(height: LuminaTokens.spaceMd),

        // Action Buttons Row (Play Album, Add to Queue, More Options '...')
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              key: const Key('btn_play_album'),
              onPressed: () => _playTrack(detail),
              icon: const Icon(Icons.play_arrow_rounded, size: 19),
              label: const Text(
                '播放專輯',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: LuminaTokens.glassSwitchOnTrack,
                foregroundColor: LuminaTokens.onAccentDark,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 11,
                ),
              ),
            ),
            IconButton.outlined(
              key: const Key('btn_add_album_to_queue'),
              tooltip: '將專輯加入播放佇列',
              onPressed: () => _addAlbumToQueue(detail, ver),
              icon: const Icon(Icons.playlist_add_rounded, size: 19),
              style: OutlinedButton.styleFrom(
                backgroundColor: LuminaTokens.glassPillBg,
                foregroundColor: LuminaTokens.glassTextPrimary,
                side: const BorderSide(color: LuminaTokens.glassPillBorder),
              ),
            ),
            Builder(
              builder: (btnCtx) => IconButton.outlined(
                key: const Key('btn_album_more_options'),
                tooltip: '更多專輯選項',
                onPressed: () => unawaited(
                  _showAlbumMoreOptionsMenu(btnCtx, detail, ver),
                ),
                icon: const Icon(Icons.more_horiz_rounded, size: 19),
                style: OutlinedButton.styleFrom(
                  backgroundColor: LuminaTokens.glassPillBg,
                  foregroundColor: LuminaTokens.glassTextPrimary,
                  side: const BorderSide(color: LuminaTokens.glassPillBorder),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
