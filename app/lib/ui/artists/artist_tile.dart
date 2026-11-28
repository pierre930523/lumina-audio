part of 'artists_view.dart';

class _ArtistTile extends StatefulWidget {
  final ArtistIndexEntry artist;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final bool isSelected;
  final VoidCallback onTap;

  const _ArtistTile({
    super.key,
    required this.artist,
    required this.audioService,
    this.libraryCache,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_ArtistTile> createState() => _ArtistTileState();
}

class _ArtistTileState extends State<_ArtistTile> {
  bool _hovered = false;

  String _resolveEntityId() {
    final direct = widget.artist.artistId?.trim();
    if (direct != null && direct.isNotEmpty) return direct;
    for (final t in widget.artist.tracks) {
      final id = t.artistId?.trim();
      if (id != null && id.isNotEmpty) return id;
    }
    return widget.artist.key;
  }

  @override
  Widget build(BuildContext context) {
    final artist = widget.artist;
    final isSelected = widget.isSelected;
    final isBanned = artist.preference == -1;
    final bgColor = isSelected
        ? LuminaTokens.glassNavActiveBg
        : (_hovered ? LuminaTokens.glassRowHoverBg : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: Opacity(
        opacity: isBanned ? 0.55 : 1.0,
        child: Semantics(
          button: true,
          selected: isSelected,
          label: artist.displayName,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: LuminaTokens.focusDuration,
              curve: LuminaTokens.motionCurve,
              margin: const EdgeInsets.symmetric(vertical: 2),
              padding: const EdgeInsets.symmetric(
                horizontal: LuminaTokens.spaceSm,
                vertical: LuminaTokens.spaceSm,
              ),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected
                      ? LuminaTokens.glassCoverRim
                      : (_hovered
                            ? LuminaTokens.glassPillBorder
                            : Colors.transparent),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isSelected || _hovered
                          ? LuminaTokens.glassNavActiveBg
                          : LuminaTokens.glassPillBg,
                      border: Border.all(
                        color: isSelected || _hovered
                            ? LuminaTokens.glassCoverRim
                            : LuminaTokens.glassPillBorder,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        artist.displayName.isNotEmpty
                            ? artist.displayName[0].toUpperCase()
                            : '?',
                        style: TextStyle(
                          color: isSelected || _hovered
                              ? Colors.white
                              : LuminaTokens.glassTextSecondary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                artist.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isSelected || _hovered
                                      ? Colors.white
                                      : LuminaTokens.glassTextPrimary,
                                  fontSize: 13.5,
                                  fontWeight: isSelected || _hovered
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                            if (isBanned) ...[
                              const SizedBox(width: 8),
                              const BannedStatusPill(),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitle(artist),
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
                  PreferenceToggleButton(
                    buttonKey: Key('btn_artist_pref_${artist.key}'),
                    audioService: widget.audioService,
                    libraryCache: widget.libraryCache,
                    entityType: 'artist',
                    entityId: _resolveEntityId(),
                    preference: artist.preference,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: isSelected || _hovered
                        ? Colors.white
                        : LuminaTokens.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle(ArtistIndexEntry a) {
    final parts = <String>[];
    if (a.albumCount > 0) parts.add('${a.albumCount} 張專輯');
    if (a.trackCount > 0) parts.add('${a.trackCount} 首曲目');
    return parts.isEmpty ? '暫無資料' : parts.join(' · ');
  }
}
