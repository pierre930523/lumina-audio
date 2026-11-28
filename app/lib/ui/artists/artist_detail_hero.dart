part of 'artist_detail_page.dart';

extension _ArtistDetailHero on _ArtistDetailPageState {
  Widget _buildHeroSection({required bool isWide, required double maxWidth}) {
    final avatarSize = isWide ? 156.0 : 116.0;
    final avatarWidget = _buildCircularAvatar(size: avatarSize);
    final infoColumn = _buildHeroInfo(isWide: isWide);

    return Container(
      padding: EdgeInsets.all(isWide ? 24 : 16),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.onBack != null && widget.showInlineBackButton)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: InkWell(
                key: const Key('artist_detail_back_btn'),
                onTap: widget.onBack,
                borderRadius: BorderRadius.circular(8),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.arrow_back_rounded,
                        size: 16,
                        color: Colors.white70,
                      ),
                      SizedBox(width: 6),
                      Text(
                        '返回',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (isWide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                avatarWidget,
                const SizedBox(width: 28),
                Expanded(child: infoColumn),
              ],
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                avatarWidget,
                const SizedBox(width: 16),
                Expanded(child: infoColumn),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildCircularAvatar({required double size}) {
    if (!widget.useAlbumArtworkAsAvatar) {
      return SizedBox(
        key: const Key('artist_hero_avatar'),
        width: size,
        height: size,
        child: _ArtistGradientAvatar(
          key: const Key('artist_hero_gradient_fallback'),
          artistName: _displayName,
          size: size,
        ),
      );
    }

    final useTrack = _preferTrackForAvatar || _representativeAlbum == null;
    final avatarTrack = useTrack ? _representativeTrack : null;
    final avatarAlbum = useTrack ? null : _representativeAlbum;

    return SizedBox(
      key: const Key('artist_hero_avatar'),
      width: size,
      height: size,
      child: AlbumArtworkView(
        track: avatarTrack,
        album: avatarAlbum,
        size: size,
        circular: true,
        fullResolution: true,
        audioService: widget.audioService,
        libraryCache: widget.libraryCache,
        placeholder: _ArtistGradientAvatar(
          key: const Key('artist_hero_gradient_fallback'),
          artistName: _displayName,
          size: size,
        ),
      ),
    );
  }

  Widget _buildHeroInfo({required bool isWide}) {
    final canPlayAll = _tracks.isNotEmpty || _albums.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: LuminaTokens.glassPillBg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: LuminaTokens.glassPillBorder),
          ),
          child: const Text(
            '藝術家',
            style: TextStyle(
              color: LuminaTokens.glassTextSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const SizedBox(height: 10),
        KeyedSubtree(
          key: const Key('artist_hero_name'),
          child: Text(
            _displayName,
            key: const Key('artist_hero_title'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: isWide ? 32 : 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              height: 1.15,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '全部曲目 ${_tracks.length} 首',
              key: const Key('artist_hero_track_stats'),
              style: const TextStyle(
                color: LuminaTokens.textSecondary,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (_albums.isNotEmpty)
              Text(
                '· 主專輯 ${_albums.length} 張',
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 13,
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              key: const Key('btn_artist_play_all'),
              onPressed: canPlayAll ? _playAll : null,
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: const Text(
                '播放全部',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: LuminaTokens.glassSwitchOnTrack,
                foregroundColor: LuminaTokens.onAccentDark,
                disabledBackgroundColor: Colors.white12,
                disabledForegroundColor: LuminaTokens.textDisabled,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 12,
                ),
              ),
            ),
            if (widget.onOpenCredits != null)
              OutlinedButton.icon(
                key: const Key('btn_artist_open_credits'),
                onPressed: widget.onOpenCredits,
                icon: const Icon(Icons.account_tree_rounded, size: 17),
                label: const Text(
                  '製作人員關係圖',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  backgroundColor: LuminaTokens.glassPillBg,
                  foregroundColor: LuminaTokens.glassTextPrimary,
                  side: const BorderSide(color: LuminaTokens.glassPillBorder),
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                ),
              ),
            PreferenceToggleButton(
              buttonKey: const Key('btn_artist_detail_preference'),
              audioService: widget.audioService,
              libraryCache: widget.libraryCache,
              entityType: 'artist',
              entityId: _resolvedArtistId(),
              preference: _artistPreference,
              showLabel: true,
              onChanged: (nextPref) {
                _setState(() => _artistPreference = nextPref);
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTracksHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          '曲目',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        InkWell(
          key: const Key('btn_artist_toggle_all_tracks'),
          borderRadius: BorderRadius.circular(999),
          onTap: () {
            _setState(() {
              _showAllTracks = !_showAllTracks;
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _showAllTracks
                  ? LuminaTokens.glassSegmentSelectedBg
                  : LuminaTokens.glassPillBg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: _showAllTracks
                    ? LuminaTokens.glassSegmentSelectedBorder
                    : LuminaTokens.glassPillBorder,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '全部 ${_tracks.length} 首',
                  style: TextStyle(
                    color: _showAllTracks
                        ? Colors.white
                        : LuminaTokens.glassTextSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  _showAllTracks
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: _showAllTracks
                      ? Colors.white
                      : LuminaTokens.glassTextSecondary,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumsHeader() {
    return Row(
      children: [
        Expanded(
          child: Text(
            '主專輯 (${_albums.length})',
            key: const Key('artist_albums_section_header'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Refined Circular Gradient Avatar Fallback ────────────────────────────────

class _ArtistGradientAvatar extends StatelessWidget {
  final String artistName;
  final double size;

  const _ArtistGradientAvatar({
    super.key,
    required this.artistName,
    required this.size,
  });

  static const List<List<Color>> _palettes = [
    [Color(0xFF312E81), Color(0xFF4F46E5), Color(0xFF0F172A)],
    [Color(0xFF1E3A8A), Color(0xFF2563EB), Color(0xFF0F172A)],
    [Color(0xFF4C1D95), Color(0xFF7C3AED), Color(0xFF111827)],
    [Color(0xFF134E4A), Color(0xFF0D9488), Color(0xFF0F172A)],
  ];

  @override
  Widget build(BuildContext context) {
    final trimmed = artistName.trim().isNotEmpty ? artistName.trim() : '?';
    final hash = trimmed.codeUnits.fold<int>(0, (acc, c) => acc + c);
    final palette = _palettes[hash % _palettes.length];
    final fontSize = (size * 0.16).clamp(13.0, 24.0).toDouble();

    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.symmetric(horizontal: size * 0.12),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette,
        ),
      ),
      child: Center(
        child: Text(
          trimmed,
          key: const Key('artist_hero_avatar_text'),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.94),
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}
