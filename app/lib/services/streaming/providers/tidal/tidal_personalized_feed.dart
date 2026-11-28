part of '../tidal_provider.dart';

extension _TidalPersonalizedFeed on TidalProvider {
  Future<List<FeedSection>> _getPersonalizedFeedImpl({
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    _requireRecAuth();

    final sections = <FeedSection>[];
    final seenSectionIds = <String>{};
    final collectedMixIds = <String>[];

    void addSectionsFromJson(Map<String, dynamic> root, String prefix) {
      final ext = _extractHomeRecommendations(root, coverSize: 1280);
      for (final id in ext.mixIds) {
        if (!collectedMixIds.contains(id)) {
          collectedMixIds.add(id);
        }
      }

      var idx = 0;
      void extractStructuredContainers(dynamic node, {String? fallbackTitle}) {
        if (node is List) {
          for (final item in node) {
            extractStructuredContainers(item, fallbackTitle: fallbackTitle);
          }
          return;
        }
        if (node is! Map) return;
        final map = Map<String, dynamic>.from(node);
        final rawTitle = (map['title'] ??
                (map['header'] is Map ? (map['header'] as Map)['title'] : null))
            ?.toString()
            .trim();
        final sectionTitle = (rawTitle != null && rawTitle.isNotEmpty)
            ? rawTitle
            : fallbackTitle;

        final pagedList = map['pagedList'];
        final directItems = map['items'] is List
            ? map['items'] as List
            : (pagedList is Map && pagedList['items'] is List
                  ? pagedList['items'] as List
                  : null);

        if (directItems != null && directItems.isNotEmpty) {
          final isContainer = directItems.any(
            (e) =>
                e is Map &&
                (e['items'] is List ||
                    e['modules'] is List ||
                    e['rows'] is List ||
                    e['pagedList'] is Map),
          );
          if (!isContainer) {
            final containerExt = _extractHomeRecommendations(
              <String, dynamic>{
                'items': directItems,
                if (map['type'] != null) 'type': map['type'],
              },
              coverSize: 1280,
            );
            final sectionTracks = containerExt.tracks
                .map(
                  (t) =>
                      TrackMetadata.fromTrackInfo(t, providerIdOverride: kind),
                )
                .toList(growable: false);
            if (sectionTracks.isNotEmpty || containerExt.albums.isNotEmpty) {
              final secId = '${prefix}_${idx++}';
              if (seenSectionIds.add(secId)) {
                sections.add(
                  FeedSection(
                    id: secId,
                    title: sectionTitle ?? 'Tidal Discovery',
                    providerId: kind,
                    tracks: sectionTracks,
                    albums: containerExt.albums,
                  ),
                );
              }
            }
            return;
          }
        }

        for (final key in const <String>[
          'items',
          'rows',
          'modules',
          'contents',
        ]) {
          if (map[key] != null) {
            extractStructuredContainers(
              map[key],
              fallbackTitle: sectionTitle,
            );
          }
        }
      }

      extractStructuredContainers(root);
      if (sections.isEmpty &&
          (ext.tracks.isNotEmpty || ext.albums.isNotEmpty)) {
        final secId = '${prefix}_fallback';
        if (seenSectionIds.add(secId)) {
          sections.add(
            FeedSection(
              id: secId,
              title: 'Tidal Home',
              providerId: kind,
              tracks: ext.tracks
                  .map(
                    (t) => TrackMetadata.fromTrackInfo(
                      t,
                      providerIdOverride: kind,
                    ),
                  )
                  .toList(growable: false),
              albums: ext.albums,
            ),
          );
        }
      }
    }

    try {
      final v2Json = await _tryTidalGet(
        '/home/feed/static',
        const <String, String>{
          'deviceType': 'BROWSER',
          'locale': 'en_US',
          'platform': 'WEB',
        },
        v2: true,
        cancel: cancel,
      );
      if (v2Json != null) {
        addSectionsFromJson(v2Json, 'tidal_v2');
      }

      if (sections.isEmpty) {
        final homeJson = await _tryTidalGet(
          '/pages/home',
          const <String, String>{'deviceType': 'BROWSER'},
          cancel: cancel,
        );
        if (homeJson != null) {
          addSectionsFromJson(homeJson, 'tidal_home');
        }
      }

      if (collectedMixIds.isNotEmpty) {
        final mixJson = await _tryTidalGet(
          '/mixes/${collectedMixIds.first}/items',
          const <String, String>{'limit': '20'},
          cancel: cancel,
        );
        if (mixJson != null) {
          final mixTracks = _parseTrackList(
                mixJson['items'] ?? mixJson['data'],
                coverSize: 1280,
              )
              .map(
                (t) => TrackMetadata.fromTrackInfo(
                  t,
                  providerIdOverride: kind,
                ),
              )
              .toList(growable: false);
          if (mixTracks.isNotEmpty && seenSectionIds.add('tidal_mix_0')) {
            sections.add(
              FeedSection(
                id: 'tidal_mix_0',
                title: 'Tidal Mixes',
                providerId: kind,
                tracks: mixTracks,
              ),
            );
          }
        }
      }
    } on StreamingException catch (e) {
      throw _mapRecError(e);
    }

    return List<FeedSection>.unmodifiable(sections);
  }
}
