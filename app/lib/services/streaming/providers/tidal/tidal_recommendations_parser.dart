part of '../tidal_provider.dart';

bool _isExcludedRecommendationType(String upperType) {
  if (upperType.isEmpty) return false;
  for (final excluded in const <String>[
    'ARTIST',
    'VIDEO',
    'PLAYLIST',
    'MIX',
    'LINK',
    'HEADER',
  ]) {
    if (upperType == excluded ||
        upperType == '${excluded}_LIST' ||
        upperType == '${excluded}S') {
      return true;
    }
  }
  return false;
}

extension _TidalRecommendationsParser on TidalProvider {
  ({List<StreamingAlbum> albums, List<TrackInfo> tracks, List<String> mixIds})
      _extractHomeRecommendations(
    Map<String, dynamic> root, {
    int coverSize = 640,
  }) {
    final rawAlbums = <Map<String, dynamic>>[];
    final rawTracks = <Map<String, dynamic>>[];
    final mixIds = <String>[];
    final seenAlbumIds = <String>{};
    final seenTrackIds = <String>{};
    final seenMixIds = <String>{};

    void considerItem(
      Map<String, dynamic> rawMap, {
      String? hintType,
      String? parentCover,
      String? parentAlbumTitle,
    }) {
      final wrapperType = rawMap['type']?.toString().trim().toUpperCase() ?? '';
      final map = rawMap['data'] is Map
          ? Map<String, dynamic>.from(rawMap['data'] as Map)
          : (rawMap['item'] is Map
                ? Map<String, dynamic>.from(rawMap['item'] as Map)
                : rawMap);
      final mapType = map['type']?.toString().trim().toUpperCase() ?? '';
      final explicitType = mapType.isNotEmpty ? mapType : wrapperType;
      final upperHint = explicitType.isNotEmpty
          ? explicitType
          : (hintType?.trim().toUpperCase() ?? '');

      if (explicitType == 'MIX' ||
          (explicitType.isEmpty &&
              (upperHint == 'MIX' || upperHint == 'MIX_LIST'))) {
        final mixId = map['id']?.toString().trim() ?? '';
        if (mixId.isNotEmpty && seenMixIds.add(mixId)) {
          mixIds.add(mixId);
        }
        return;
      }
      if (_isExcludedRecommendationType(explicitType) ||
          (explicitType.isEmpty && _isExcludedRecommendationType(upperHint))) {
        return;
      }

      final id = map['id']?.toString().trim() ?? '';
      if (id.isEmpty || map['uuid'] != null) return;
      if (map['items'] is List ||
          map['modules'] is List ||
          map['rows'] is List ||
          map['pagedList'] is Map) {
        return;
      }
      if (map['title'] == null) return;

      final isAlbum = upperHint.contains('ALBUM') ||
          map['numberOfTracks'] != null ||
          map['releaseDate'] != null ||
          map['upc'] != null;
      final isTrack = !isAlbum &&
          (upperHint.contains('TRACK') ||
              map['album'] is Map ||
              map['trackNumber'] != null ||
              map['duration'] != null);

      if (isTrack) {
        if (seenTrackIds.add(id)) {
          final enriched = Map<String, dynamic>.from(map);
          if (_extractTidalCoverFromMap(enriched, size: coverSize) == null) {
            final fallbackCover =
                _extractTidalCoverFromMap(rawMap, size: coverSize) ??
                parentCover;
            if (fallbackCover != null) {
              enriched['cover'] = fallbackCover;
            }
          }
          if (parentAlbumTitle != null &&
              parentAlbumTitle.isNotEmpty &&
              enriched['album'] == null) {
            enriched['album'] = <String, dynamic>{'title': parentAlbumTitle};
          }
          rawTracks.add(enriched);
        }
      } else if (isAlbum) {
        if (seenAlbumIds.add(id)) {
          final enriched = Map<String, dynamic>.from(map);
          if (_extractTidalCoverFromMap(enriched, size: coverSize) == null) {
            final fallbackCover =
                _extractTidalCoverFromMap(rawMap, size: coverSize) ??
                parentCover;
            if (fallbackCover != null) {
              enriched['cover'] = fallbackCover;
            }
          }
          rawAlbums.add(enriched);
        }
      }
    }

    void walk(
      dynamic node, {
      String? hintType,
      String? parentCover,
      String? parentAlbumTitle,
    }) {
      if (node is Map) {
        final map = Map<String, dynamic>.from(node);
        final nextHint = map['type']?.toString() ?? hintType;
        final nodeCover =
            _extractTidalCoverFromMap(map, size: coverSize) ?? parentCover;
        final isContainer = map['items'] is List ||
            map['modules'] is List ||
            map['rows'] is List ||
            map['pagedList'] is Map;
        final nextHintUpper = (nextHint ?? '').trim().toUpperCase();
        final nodeAlbumTitle = (!isContainer &&
                (map['numberOfTracks'] != null ||
                    nextHintUpper.contains('ALBUM')))
            ? (map['title']?.toString() ?? parentAlbumTitle)
            : parentAlbumTitle;

        if (map['albums'] is List) {
          for (final item in map['albums'] as List) {
            if (item is Map) {
              considerItem(
                Map<String, dynamic>.from(item),
                hintType: 'ALBUM',
                parentCover: nodeCover,
                parentAlbumTitle: nodeAlbumTitle,
              );
            }
          }
        }
        if (map['tracks'] is List) {
          for (final item in map['tracks'] as List) {
            if (item is Map) {
              considerItem(
                Map<String, dynamic>.from(item),
                hintType: 'TRACK',
                parentCover: nodeCover,
                parentAlbumTitle: nodeAlbumTitle,
              );
            }
          }
        }

        final innerCandidate = map['data'] is Map
            ? map['data'] as Map
            : (map['item'] is Map ? map['item'] as Map : null);
        final hasDirectItem = map['id'] != null && map['title'] != null;
        final hasWrappedItem = innerCandidate != null &&
            innerCandidate['id'] != null &&
            innerCandidate['title'] != null &&
            innerCandidate['items'] is! List &&
            innerCandidate['modules'] is! List &&
            innerCandidate['rows'] is! List &&
            innerCandidate['pagedList'] is! Map;

        if (!isContainer && (hasDirectItem || hasWrappedItem)) {
          considerItem(
            map,
            hintType: nextHint,
            parentCover: parentCover,
            parentAlbumTitle: parentAlbumTitle,
          );
          if (map['tracks'] == null &&
              map['items'] == null &&
              (innerCandidate == null ||
                  (innerCandidate['tracks'] == null &&
                      innerCandidate['items'] == null))) {
            return;
          }
        }

        for (final entry in map.entries) {
          if (entry.key == 'albums' || entry.key == 'tracks') continue;
          walk(
            entry.value,
            hintType: nextHint,
            parentCover: nodeCover,
            parentAlbumTitle: nodeAlbumTitle,
          );
        }
      } else if (node is List) {
        for (final item in node) {
          walk(
            item,
            hintType: hintType,
            parentCover: parentCover,
            parentAlbumTitle: parentAlbumTitle,
          );
        }
      }
    }

    walk(root);
    final parsedAlbums = _parseAlbumList(rawAlbums);
    final coverByAlbumId = <String, String>{};
    for (final a in parsedAlbums) {
      if (a.coverUrl != null && a.coverUrl!.isNotEmpty) {
        coverByAlbumId[a.id] = a.coverUrl!;
      }
    }
    if (coverByAlbumId.isNotEmpty) {
      for (final tMap in rawTracks) {
        final albumObj = tMap['album'];
        if (albumObj is Map) {
          final albId = albumObj['id']?.toString();
          final existing = _extractTidalCoverFromMap(tMap, size: coverSize);
          if (existing == null &&
              albId != null &&
              coverByAlbumId.containsKey(albId)) {
            tMap['cover'] = coverByAlbumId[albId];
          }
        }
      }
    }
    return (
      albums: parsedAlbums,
      tracks: _parseTrackList(rawTracks, coverSize: coverSize),
      mixIds: mixIds,
    );
  }
}
