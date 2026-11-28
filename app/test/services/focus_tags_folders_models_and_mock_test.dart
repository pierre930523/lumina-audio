import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/nav_entry.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';

void main() {
  group('Focus / Tags / Folders Models JSON round-trip', () {
    test('FocusQuery & FocusValue serialize with frozen snake_case contract', () {
      const query = FocusQuery(
        entity: FocusEntity.albums,
        predicates: [
          FocusPredicate(
            facet: FocusFacet.format,
            value: FocusValue.string('flac'),
            mode: FocusPredicateMode.include,
          ),
          FocusPredicate(
            facet: FocusFacet.bitDepth,
            value: FocusValue.int(24),
            mode: FocusPredicateMode.exclude,
          ),
          FocusPredicate(
            facet: FocusFacet.releaseYear,
            value: FocusValue.intRange(min: 1970, max: 1980),
          ),
          FocusPredicate(
            facet: FocusFacet.addedAt,
            value: FocusValue.dateRange(from: '2026-01-01', to: '2026-12-31'),
          ),
        ],
        sort: FocusSort(
          field: FocusSortField.releaseYear,
          direction: FocusSortDirection.desc,
          seed: 7,
        ),
        includeHidden: true,
        profileId: 'prof-default',
      );

      final json = query.toJson();
      expect(json['entity'], 'albums');
      expect(json['include_hidden'], true);
      expect(json['profile_id'], 'prof-default');
      final preds = json['predicates'] as List<dynamic>;
      expect((preds[0] as Map)['facet'], 'format');
      expect(((preds[0] as Map)['value'] as Map)['kind'], 'string');
      expect((preds[1] as Map)['facet'], 'bit_depth');
      expect((preds[1] as Map)['mode'], 'exclude');
      expect(((preds[2] as Map)['value'] as Map)['kind'], 'int_range');
      expect(((preds[3] as Map)['value'] as Map)['kind'], 'date_range');

      final roundTripped = FocusQuery.fromJson(json);
      expect(roundTripped, query);
      expect(query.predicates.first.toggledMode().mode, FocusPredicateMode.exclude);
    });

    test('TrackInfo.fromJson parses snake_case track DTOs', () {
      final track = TrackInfo.fromJson(const {
        'id': 'trk-99',
        'title': 'Echoes',
        'artist_name': 'Pink Floyd',
        'album': 'Meddle',
        'duration_ms': 1412000,
        'codec': 'flac',
        'sample_rate_hz': 96000,
        'bit_depth': 24,
        'channels': 2,
        'is_dsd': false,
        'provider_id': 'local',
        'file_path': r'D:\Music\Pink Floyd\Meddle\06.flac',
        'genre': 'Progressive Rock',
        'release_year': 1971,
        'track_number': 6,
        'disc_number': 1,
        'has_lyrics': true,
      });

      expect(track.id, 'trk-99');
      expect(track.artist, 'Pink Floyd');
      expect(track.format.sampleRateHz, 96000);
      expect(track.format.bitDepth, 24);
      expect(track.year, 1971);
      expect(track.hasLyrics, isTrue);
      expect(track.providerName, 'Local Library');
    });

    test('NavEntry supports tags, folders, and Focus deep-link round-trip', () {
      const q = FocusQuery(
        entity: FocusEntity.tracks,
        predicates: [
          FocusPredicate(
            facet: FocusFacet.tag,
            value: FocusValue.string('tag-audiophile'),
          ),
        ],
      );
      final focusEntry = NavEntry.focus(q);
      expect(focusEntry.tab, HomeTab.library);
      expect(focusEntry.parsedFocusQuery, q);

      final tagEntry = NavEntry.tags(tagId: 'tag-audiophile');
      expect(tagEntry.tab, HomeTab.tags);
      expect(tagEntry.tagId, 'tag-audiophile');

      final folderEntry = NavEntry.folders(folderId: 'fld-dsotm');
      expect(folderEntry.tab, HomeTab.folders);
      expect(folderEntry.folderId, 'fld-dsotm');
    });
  });

  group('MockAudioService Step 3 Focus, Nested Tags & Folders', () {
    late MockAudioService service;

    setUp(() {
      service = MockAudioService();
    });

    tearDown(() {
      service.dispose();
    });

    test('Focus supports AND across facets, OR within facet, NOT exclude, and disjunctive facets', () async {
      // Include FLAC (both albums match primary FLAC), exclude 1979 -> only DSOTM (1973).
      final res = await service.focusQuery(
        const FocusQueryRequest(
          query: FocusQuery(
            entity: FocusEntity.albums,
            predicates: [
              FocusPredicate(
                facet: FocusFacet.format,
                value: FocusValue.string('flac'),
              ),
              FocusPredicate(
                facet: FocusFacet.releaseYear,
                value: FocusValue.int(1979),
                mode: FocusPredicateMode.exclude,
              ),
            ],
          ),
        ),
      );
      expect(res.totalCount, 1);
      expect(res.albums.single.id, 'alb-dsotm');

      // Disjunctive facets on source: filtering source=qobuz still reports tidal bucket count.
      final facets = await service.focusFacets(
        const FocusQuery(
          entity: FocusEntity.albums,
          predicates: [
            FocusPredicate(
              facet: FocusFacet.source,
              value: FocusValue.string('qobuz'),
            ),
          ],
        ),
      );
      expect(facets.totalMatched, 1);
      final sourceBuckets = facets.bucketsFor(FocusFacet.source);
      expect(sourceBuckets.any((b) => b.value == 'qobuz'), isTrue);
      expect(sourceBuckets.any((b) => b.value == 'tidal'), isTrue);
    });

    test('Nested tags enforce DAG cycle detection, recursive expansion, and track inheritance', () async {
      final created = await service.createTag(
        const CreateTagRequest(name: 'Test Child', color: '#34D399'),
      );
      expect(created, isNotNull);

      // Link tag-late-night -> created
      final linked = await service.linkTagParent(
        TagLinkRequest(
          parentTagId: 'tag-late-night',
          childTagId: created!.id,
        ),
      );
      expect(linked, isTrue);

      // Cycle: created -> tag-audiophile (already grandparent) MUST fail
      final cycle = await service.linkTagParent(
        TagLinkRequest(
          parentTagId: created.id,
          childTagId: 'tag-audiophile',
        ),
      );
      expect(cycle, isFalse);

      // Tag alb-dsotm with `created`; querying parent `tag-audiophile` includes it recursively
      // and tracks in alb-dsotm inherit the tag.
      final batchRes = await service.batchTagItems(
        BatchTagItemsRequest(
          tagIds: [created.id],
          entityType: TagEntityType.track,
          entityIds: const ['trk-003'],
        ),
      );
      expect(batchRes.affected, 1);

      final trackFocus = await service.focusQuery(
        const FocusQueryRequest(
          query: FocusQuery(
            entity: FocusEntity.tracks,
            predicates: [
              FocusPredicate(
                facet: FocusFacet.tag,
                value: FocusValue.string('tag-audiophile'),
              ),
            ],
          ),
        ),
      );
      // trk-001 (direct late-night + alb-dsotm), trk-002 (inherited from alb-dsotm), trk-003 (child tag)
      expect(trackFocus.tracks.map((t) => t.id), containsAll(['trk-001', 'trk-002', 'trk-003']));
    });

    test('Physical folders return roots, breadcrumbs, direct tracks, and recursive track IDs', () async {
      final roots = await service.getFolderRoots();
      expect(roots, hasLength(1));
      expect(roots.single.id, 'fld-root-music');

      final dsotm = await service.getFolderContents('fld-dsotm');
      expect(dsotm, isNotNull);
      expect(dsotm!.breadcrumbs.map((b) => b.name), ['Music', 'Pink Floyd', 'The Dark Side of the Moon']);
      expect(dsotm.tracks.map((t) => t.id), ['trk-001', 'trk-002']);

      final recursiveIds = await service.getFolderRecursiveTrackIds('fld-root-music');
      expect(recursiveIds, ['trk-001', 'trk-002', 'trk-003']);
    });
  });
}
