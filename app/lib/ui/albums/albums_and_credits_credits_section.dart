part of 'albums_and_credits_view.dart';

extension _AlbumsAndCreditsGraphSection on _AlbumsAndCreditsViewState {
  Widget _buildCreditsGraph() {
    final artist = _selectedArtist;
    final credits = artist?.credits.isNotEmpty == true
        ? artist!.credits
        : _defaultCredits;
    final groupedByRole = <String, List<AlbumCreditInfo>>{};
    for (final c in credits) {
      groupedByRole.putIfAbsent(c.role, () => []).add(c);
    }

    return SmoothScrollWrapper(
      controller: _creditsScrollController,
      child: ListView(
        key: const Key('credits_graph_view'),
        controller: _creditsScrollController,
        padding: const EdgeInsets.fromLTRB(
          LuminaTokens.spaceLg,
          LuminaTokens.spaceSm,
          LuminaTokens.spaceLg,
          LuminaTokens.bottomScrollClearance,
        ),
        children: [
        Container(
          padding: const EdgeInsets.all(LuminaTokens.spaceMd),
          decoration: BoxDecoration(
            color: LuminaTokens.glassCardBg,
            borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
            border: Border.all(color: LuminaTokens.glassCardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                artist?.name ?? _defaultArtistName ?? '藝術家與製作人員關係圖',
                style: const TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (artist?.biography != null) ...[
                const SizedBox(height: LuminaTokens.space2xs),
                Text(
                  artist!.biography!,
                  style: const TextStyle(
                    color: LuminaTokens.glassTextSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: LuminaTokens.spaceSm),
        if (groupedByRole.isEmpty)
          const Text(
            '尚無創作者與製作人員紀錄，請先至「專輯與發行版本」執行「補全製作人員」。',
            style: TextStyle(color: LuminaTokens.textMuted),
          )
        else
          ...groupedByRole.entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
              child: Container(
                padding: const EdgeInsets.all(LuminaTokens.spaceSm),
                decoration: BoxDecoration(
                  color: LuminaTokens.glassCardBg,
                  borderRadius: BorderRadius.circular(
                    LuminaTokens.glassCardRadius,
                  ),
                  border: Border.all(color: LuminaTokens.glassCardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.key,
                      style: const TextStyle(
                        color: LuminaTokens.glassTextPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: LuminaTokens.spaceXs),
                    Wrap(
                      spacing: LuminaTokens.spaceXs,
                      runSpacing: LuminaTokens.spaceXs,
                      children: entry.value.map((credit) {
                        return ActionChip(
                          avatar: const Icon(
                            Icons.hub_rounded,
                            size: 16,
                            color: LuminaTokens.glassTextSecondary,
                          ),
                          surfaceTintColor: Colors.transparent,
                          backgroundColor: LuminaTokens.glassPillBg,
                          side: const BorderSide(
                            color: LuminaTokens.glassPillBorder,
                          ),
                          labelStyle: const TextStyle(
                            color: LuminaTokens.glassTextPrimary,
                            fontSize: 12.5,
                          ),
                          label: Text(
                            credit.albumTitle != null
                                ? '${credit.artistName} → ${credit.albumTitle}'
                                : credit.artistName,
                          ),
                          onPressed: () {
                            if (credit.albumId != null) {
                              if (widget.onOpenAlbumDetail != null) {
                                widget.onOpenAlbumDetail!(credit.albumId!);
                              } else {
                                _openAlbum(credit.albumId!);
                              }
                            } else {
                              _openArtistGraph(credit.artistId);
                            }
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
