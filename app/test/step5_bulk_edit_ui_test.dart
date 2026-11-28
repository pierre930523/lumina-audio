import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/album_selection_bar.dart';
import 'package:lumina_app/ui/common/bulk_edit_dialog.dart';
import 'package:lumina_app/ui/library/track_selection_bar.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

class _SpyBulkEditAudioService extends MockAudioService {
  BulkEditEntityType? lastEntityType;
  List<String>? lastEntityIds;
  BulkEditPatch? lastPatch;

  @override
  Future<BulkEditResult?> applyBulkEdit(
    BulkEditEntityType entityType,
    List<String> entityIds,
    BulkEditPatch patch,
  ) {
    lastEntityType = entityType;
    lastEntityIds = List<String>.from(entityIds);
    lastPatch = patch;
    return super.applyBulkEdit(entityType, entityIds, patch);
  }
}

Widget _wrapApp(Widget child) => MaterialApp(
  theme: LuminaTokens.buildDarkTheme(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets(
    'renders <Mixed> badges and editing only genre never overwrites <Mixed> fields',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final audio = _SpyBulkEditAudioService();
      addTearDown(audio.dispose);

      final trackIds = audio.queue.take(2).map((t) => t.id).toList();
      expect(trackIds.length, 2);

      BulkEditResult? dialogResult;
      await tester.pumpWidget(
        _wrapApp(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                dialogResult = await showBulkEditDialog(
                  context: context,
                  audioService: audio,
                  entityType: BulkEditEntityType.track,
                  entityIds: trackIds,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('bulk_edit_dialog')), findsOneWidget);
      expect(find.byKey(const Key('bulk_field_mixed_badge_title')), findsOneWidget);
      expect(find.text('<Mixed>'), findsWidgets);

      // Typing into a <Mixed> field then erasing back to empty must restore
      // untouched state rather than clearing <Mixed>.
      await tester.enterText(
        find.byKey(const Key('bulk_field_input_title')),
        'Temp Title',
      );
      await tester.pump();
      expect(find.byKey(const Key('bulk_field_dirty_badge_title')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('bulk_field_input_title')),
        '',
      );
      await tester.pump();
      expect(find.byKey(const Key('bulk_field_mixed_badge_title')), findsOneWidget);

      // Edit ONLY genre and apply.
      final genreFinder = find.byKey(const Key('bulk_field_input_genre'));
      await tester.ensureVisible(genreFinder);
      await tester.enterText(genreFinder, 'Modal Jazz');
      await tester.pump();

      await tester.tap(find.byKey(const Key('btn_bulk_edit_apply')));
      await tester.pumpAndSettle();

      expect(dialogResult, isNotNull);
      expect(audio.lastEntityType, BulkEditEntityType.track);
      expect(audio.lastEntityIds, trackIds);
      expect(audio.lastPatch, isNotNull);
      expect(audio.lastPatch!.fields.keys, <String>['genre']);
      expect(
        audio.lastPatch!.fields['genre'],
        const FieldPatchSet<Object?>('Modal Jazz'),
      );
      expect(audio.lastPatch!.fields.containsKey('title'), isFalse);
      expect(audio.lastPatch!.fields.containsKey('artist_name'), isFalse);

      // Verify summary after edit still keeps title as <Mixed> and genre as Common.
      final after = await audio.getBulkEditSummary(
        BulkEditEntityType.track,
        trackIds,
      );
      expect(after!.fields['title'], isA<TriStateMixed<Object?>>());
      expect(
        after.fields['genre'],
        const TriStateCommon<Object?>('Modal Jazz'),
      );
    },
  );

  testWidgets(
    'explicit per-field clear emits FieldPatchClear and tri-state tags compute exact deltas',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final audio = _SpyBulkEditAudioService();
      addTearDown(audio.dispose);

      final trackIds = audio.queue.take(2).map((t) => t.id).toList();
      final tagAll = (await audio.createTag(const CreateTagRequest(name: 'TagAll')))!;
      final tagSome = (await audio.createTag(const CreateTagRequest(name: 'TagSome')))!;
      final tagNone = (await audio.createTag(const CreateTagRequest(name: 'TagNone')))!;

      await audio.batchTagItems(
        BatchTagItemsRequest(
          tagIds: <String>[tagAll.id],
          entityType: TagEntityType.track,
          entityIds: trackIds,
          op: TagBatchOp.add,
        ),
      );
      await audio.batchTagItems(
        BatchTagItemsRequest(
          tagIds: <String>[tagSome.id],
          entityType: TagEntityType.track,
          entityIds: <String>[trackIds.first],
          op: TagBatchOp.add,
        ),
      );

      await tester.pumpWidget(
        _wrapApp(
          BulkEditDialog(
            audioService: audio,
            entityType: BulkEditEntityType.track,
            entityIds: trackIds,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify tri-state initial checkbox values: All -> true, Some -> null, None -> false.
      Checkbox cbOf(String id) =>
          tester.widget<Checkbox>(find.byKey(Key('bulk_tag_checkbox_$id')));
      expect(cbOf(tagAll.id).value, isTrue);
      expect(cbOf(tagSome.id).value, isNull);
      expect(cbOf(tagNone.id).value, isFalse);

      // Explicitly clear composer override.
      final clearComposer = find.byKey(const Key('btn_bulk_clear_composer'));
      await tester.ensureVisible(clearComposer);
      await tester.tap(clearComposer);
      await tester.pump();
      expect(
        find.byKey(const Key('bulk_field_clear_badge_composer')),
        findsOneWidget,
      );

      // Toggle tagAll off (remove), tagNone on (add), keep tagSome untouched.
      final allFinder = find.byKey(Key('bulk_tag_checkbox_${tagAll.id}'));
      await tester.ensureVisible(allFinder);
      await tester.tap(allFinder);
      await tester.pump();

      final noneFinder = find.byKey(Key('bulk_tag_checkbox_${tagNone.id}'));
      await tester.ensureVisible(noneFinder);
      await tester.tap(noneFinder);
      await tester.pump();

      await tester.tap(find.byKey(const Key('btn_bulk_edit_apply')));
      await tester.pumpAndSettle();

      final patch = audio.lastPatch!;
      expect(patch.fields['composer'], const FieldPatchClear<Object?>());
      expect(patch.addTagIds, <String>[tagNone.id]);
      expect(patch.removeTagIds, <String>[tagAll.id]);
    },
  );

  testWidgets(
    'revert to file meta button opens confirmation and submits revertToFileMeta: true',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final audio = _SpyBulkEditAudioService();
      addTearDown(audio.dispose);

      final albums = await audio.getAlbums();
      final albumId = albums.first.effectiveGroupId;

      // Seed a user edit so the user-edits badge displays.
      await audio.applyBulkEdit(
        BulkEditEntityType.album,
        <String>[albumId],
        const BulkEditPatch(
          fields: <String, FieldPatchOp<Object?>>{
            'editorial_bio': FieldPatchSet<Object?>('Custom Note'),
          },
        ),
      );
      audio.lastPatch = null;

      await tester.pumpWidget(
        _wrapApp(
          BulkEditDialog(
            audioService: audio,
            entityType: BulkEditEntityType.album,
            entityIds: <String>[albumId],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('bulk_edit_user_edits_badge')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('btn_bulk_revert_file_meta')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('bulk_revert_confirm_dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('btn_confirm_bulk_revert')));
      await tester.pumpAndSettle();

      expect(audio.lastEntityType, BulkEditEntityType.album);
      expect(audio.lastPatch, isNotNull);
      expect(audio.lastPatch!.revertToFileMeta, isTrue);

      final after = await audio.getBulkEditSummary(
        BulkEditEntityType.album,
        <String>[albumId],
      );
      expect(after!.hasUserEditsCount, 0);
    },
  );

  testWidgets(
    'AlbumSelectionBar and TrackSelectionBar expose bulk edit and export buttons',
    (tester) async {
      var albumBulkTapped = false;
      var albumExportTapped = false;
      var trackBulkTapped = false;
      var trackExportTapped = false;

      const sampleAlbum = CanonicalAlbumSummary(
        id: 'alb-1',
        title: 'Kind of Blue',
        artist: 'Miles Davis',
      );
      final sampleTrack = TrackInfo(
        id: 'trk-1',
        title: 'So What',
        artist: 'Miles Davis',
        album: 'Kind of Blue',
        duration: const Duration(minutes: 9),
        format: const AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
      );

      await tester.pumpWidget(
        _wrapApp(
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AlbumSelectionBar(
                selectedAlbums: const <CanonicalAlbumSummary>[sampleAlbum],
                onMerge: () {},
                onGroupAsAlternate: () {},
                onToggleHide: () {},
                onBulkEdit: () => albumBulkTapped = true,
                onExport: () => albumExportTapped = true,
                onClearSelection: () {},
              ),
              TrackSelectionBar(
                selectedTracks: <TrackInfo>[sampleTrack],
                onPlaySelected: () {},
                onAddToQueue: () {},
                onBulkEdit: () => trackBulkTapped = true,
                onExport: () => trackExportTapped = true,
                onClearSelection: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_selection_bulk_edit')));
      await tester.tap(find.byKey(const Key('btn_selection_export')));
      await tester.tap(find.byKey(const Key('btn_track_selection_bulk_edit')));
      await tester.tap(find.byKey(const Key('btn_track_selection_export')));
      await tester.pump();

      expect(albumBulkTapped, isTrue);
      expect(albumExportTapped, isTrue);
      expect(trackBulkTapped, isTrue);
      expect(trackExportTapped, isTrue);
    },
  );
}
