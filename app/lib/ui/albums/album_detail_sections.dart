part of 'album_detail_page.dart';

extension _AlbumDetailSections on _AlbumDetailPageState {
  Widget _buildDetail(CanonicalAlbumDetail detail) {
    final visibleVersions = detail.versions
        .where((v) => v.tracks.isNotEmpty)
        .toList();
    final selectedVersion = visibleVersions.isNotEmpty
        ? visibleVersions[
            _selectedVersionIndex.clamp(0, visibleVersions.length - 1)
          ]
        : null;
    final trackEntries = selectedVersion?.orderedTrackEntries ?? const [];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 560;
        final coverSize = constraints.maxWidth >= 780
            ? 200.0
            : (isWide ? 168.0 : 148.0);
        final hPad = isWide ? 28.0 : 16.0;
        final vPad = isWide ? 24.0 : 16.0;

        return SmoothScrollWrapper(
          controller: _scrollController,
          child: CustomScrollView(
            key: PageStorageKey<String>('album_detail_${widget.albumId}'),
            controller: _scrollController,
            slivers: [
            // 1. Hero & Metadata Header Sliver
            SliverPadding(
              padding: EdgeInsets.fromLTRB(hPad, vPad, hPad, 12),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isWide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildCover(size: coverSize),
                          const SizedBox(width: 28),
                          Expanded(
                            child: _buildHeroMeta(
                              detail,
                              selectedVersion,
                              isWide: true,
                            ),
                          ),
                        ],
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(child: _buildCover(size: coverSize)),
                          const SizedBox(height: 16),
                          _buildHeroMeta(
                            detail,
                            selectedVersion,
                            isWide: false,
                          ),
                        ],
                      ),

                    // Step 2: Interactive Album Versions Management Section
                    if (visibleVersions.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      AlbumVersionsSection(
                        versions: visibleVersions,
                        selectedIndex: _selectedVersionIndex.clamp(
                          0,
                          visibleVersions.length - 1,
                        ),
                        isPrimaryLocked: detail.isPrimaryLocked,
                        hiddenVersionCount: detail.hiddenVersionCount,
                        isStreamingAlbum:
                            widget.albumId.startsWith('streaming:'),
                        onSelectVersion: (i) =>
                            _setState(() => _selectedVersionIndex = i),
                        onVersionAction: (ver, action) =>
                            unawaited(_handleVersionAction(detail, ver, action)),
                      ),
                    ],

                    // Contributor chips (kept near Hero so always accessible without cluttering)
                    if (detail.credits.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      const Text(
                        '製作人員',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final c in detail.credits)
                            _CreditChip(
                              credit: c,
                              onTap: widget.onOpenArtistCredits != null
                                  ? () => widget.onOpenArtistCredits!(
                                      c.artistId,
                                    )
                                  : (widget.onOpenArtist != null
                                        ? () => widget.onOpenArtist!(
                                            c.artistName,
                                          )
                                        : null),
                            ),
                        ],
                      ),
                    ],

                    if (trackEntries.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      Container(
                        padding: const EdgeInsets.only(bottom: 8),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: LuminaTokens.glassCardDivider,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 42,
                              child: Text(
                                '#',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: LuminaTokens.textMuted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                '曲目列表',
                                style: TextStyle(
                                  color: LuminaTokens.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            Semantics(
                              label: '曲目時長',
                              child: const Icon(
                                Icons.schedule_rounded,
                                size: 15,
                                color: LuminaTokens.textMuted,
                              ),
                            ),
                            const SizedBox(width: 68),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // 2. Virtualized Track List Sliver (SliverList.builder)
            if (trackEntries.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: hPad),
                sliver: SliverList.builder(
                  itemCount: trackEntries.length,
                  itemBuilder: (context, i) {
                    final entry = trackEntries[i];
                    final isStreamingVersion =
                        selectedVersion != null &&
                        selectedVersion.provider != 'local';
                    final row = RepaintBoundary(
                      child: TrackHoverPrefetch(
                        enabled: isStreamingVersion,
                        trackIdentity: entry.track.id,
                        trackBuilder: isStreamingVersion
                            ? () => _toTrackInfo(
                                detail,
                                selectedVersion,
                                entry.track,
                              )
                            : null,
                        child: _AlbumTrackRow(
                          key: Key('album_track_$i'),
                          index: i,
                          track: entry.track,
                          displayNumber: entry.displayNumber,
                          artistName: detail.artistName,
                          albumTitle: detail.title,
                          audioService: widget.audioService,
                          libraryCache: widget.libraryCache,
                          listenLaterController: widget.listenLaterController,
                          trackInfoBuilder: () {
                            final ver =
                                selectedVersion ?? detail.versions.firstOrNull;
                            if (ver != null) {
                              return _toTrackInfo(detail, ver, entry.track);
                            }
                            return _findTrack(
                                  detail,
                                  title: entry.track.title,
                                  versionTrack: entry.track,
                                ) ??
                                TrackInfo(
                                  id: entry.track.id,
                                  title: entry.track.title,
                                  artist: detail.artistName,
                                  album: detail.title,
                                  duration: Duration(
                                    milliseconds: entry.track.durationMs,
                                  ),
                                  format: AudioFormat(
                                    codec: AudioCodec.fromString(
                                      entry.track.codec,
                                    ),
                                    sampleRateHz: entry.track.sampleRateHz > 0
                                        ? entry.track.sampleRateHz
                                        : 44100,
                                    bitDepth: entry.track.bitDepth > 0
                                        ? entry.track.bitDepth
                                        : 16,
                                    channels: 2,
                                    isDsd: entry.track.isDsd,
                                  ),
                                  coverUrl: detail.coverUrl,
                                  albumGroupId: detail.id,
                                  preference: entry.track.preference,
                                );
                          },
                          onTrackMutated: () =>
                              unawaited(_load(forceRefresh: true)),
                          isStreaming: isStreamingVersion,
                          playbackListenable: _playbackNotifier,
                          onPlay: () => _playTrack(
                            detail,
                            title: entry.track.title,
                            versionTrack: entry.track,
                          ),
                          onAddToQueue: () =>
                              _addTrackToQueue(detail, entry.track),
                          onOpenArtist: () =>
                              _handleOpenArtist(detail.artistName, detail),
                          onManageTags: isStreamingVersion
                              ? null
                              : () => _promptManageTrackTags(entry.track),
                          onPreferenceChanged: (nextPref) {
                            final nextVersions = detail.versions
                                .map(
                                  (v) => v.copyWith(
                                    tracks: v.tracks
                                        .map(
                                          (t) => t.id == entry.track.id
                                              ? t.copyWith(preference: nextPref)
                                              : t,
                                        )
                                        .toList(growable: false),
                                  ),
                                )
                                .toList(growable: false);
                            final updated = detail.copyWith(
                              versions: nextVersions,
                            );
                            widget.libraryCache?.putAlbumDetailSync(updated);
                            _setState(() => _detail = updated);
                          },
                        ),
                      ),
                    );
                    if (!entry.showDiscHeader) {
                      return row;
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(
                            top: i == 0 ? 4 : 14,
                            bottom: 6,
                            left: 8,
                          ),
                          child: Text(
                            'Disc ${entry.track.discNumber}',
                            style: const TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                        row,
                      ],
                    );
                  },
                ),
              ),

            // 3. Editorial Bio & Bottom Padding Sliver
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                hPad,
                LuminaTokens.spaceMd,
                hPad,
                vPad + LuminaTokens.bottomScrollClearance,
              ),
              sliver: SliverToBoxAdapter(
                child:
                    (detail.editorialBio != null &&
                        detail.editorialBio!.isNotEmpty)
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '簡介',
                            style: TextStyle(
                              color: LuminaTokens.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: LuminaTokens.spaceXs),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: LuminaTokens.glassCardBg,
                              borderRadius: BorderRadius.circular(
                                LuminaTokens.glassCardRadius,
                              ),
                              border: Border.all(
                                color: LuminaTokens.glassCardBorder,
                              ),
                            ),
                            child: Text(
                              detail.editorialBio!,
                              style: const TextStyle(
                                color: LuminaTokens.textSecondary,
                                fontSize: 13,
                                height: 1.6,
                              ),
                            ),
                          ),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
        );
      },
    );
  }
}
