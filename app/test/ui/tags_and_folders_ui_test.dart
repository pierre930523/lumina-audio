import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/albums/album_selection_bar.dart';
import 'package:lumina_app/ui/folders/folders_view.dart';
import 'package:lumina_app/ui/tags/tag_picker_dialog.dart';
import 'package:lumina_app/ui/tags/tags_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

Widget _wrapApp(Widget child) {
  return MaterialApp(
    theme: LuminaTokens.buildDarkTheme(),
    home: Scaffold(body: child),
  );
}

void main() {
  group('TagsView CRUD, cycle detection & Focus jump', () {
    late MockAudioService service;

    setUp(() {
      service = MockAudioService();
    });

    tearDown(() {
      service.dispose();
    });

    testWidgets('supports create, rename, cycle error display, focus jump, and delete', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      FocusQuery? jumpedQuery;
      await tester.pumpWidget(
        _wrapApp(
          TagsView(
            audioService: service,
            onOpenFocusQuery: (q) => jumpedQuery = q,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Seeded tags rendered
      expect(find.byKey(const Key('tag_tree_row_tag-audiophile')), findsOneWidget);
      expect(find.byKey(const Key('tag_tree_row_tag-late-night')), findsOneWidget);
      expect(find.byKey(const Key('tag_tree_row_tag-classic-rock')), findsOneWidget);

      // 1. Create a new tag
      await tester.tap(find.byKey(const Key('btn_create_tag')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('tag_editor_name_input')),
        '爵士女聲',
      );
      await tester.tap(find.byKey(const Key('btn_tag_editor_save')));
      await tester.pumpAndSettle();
      expect(find.text('爵士女聲'), findsOneWidget);

      // 2. Rename an existing tag
      await tester.tap(find.byKey(const Key('btn_tag_edit_tag-classic-rock')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('tag_editor_name_input')),
        '搖滾經典',
      );
      await tester.tap(find.byKey(const Key('btn_tag_editor_save')));
      await tester.pumpAndSettle();
      expect(find.text('搖滾經典'), findsOneWidget);

      // 3. Cycle detection: try linking child `tag-late-night` as parent of `tag-audiophile`
      await tester.tap(
        find.byKey(const Key('btn_tag_link_parent_tag-audiophile')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('link_parent_option_tag-late-night')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tags_view_error_banner')), findsOneWidget);
      expect(find.textContaining('循環參照'), findsOneWidget);

      // 4. Jump to Focus albums for tag-audiophile
      await tester.tap(
        find.byKey(const Key('btn_tag_focus_albums_tag-audiophile')),
      );
      await tester.pumpAndSettle();
      expect(jumpedQuery, isNotNull);
      expect(jumpedQuery!.entity, FocusEntity.albums);
      expect(jumpedQuery!.predicates.single.facet, FocusFacet.tag);
      expect(
        jumpedQuery!.predicates.single.value,
        const FocusStringValue('tag-audiophile'),
      );

      // 5. Delete tag-classic-rock
      await tester.tap(find.byKey(const Key('btn_tag_delete_tag-classic-rock')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_confirm_delete_tag')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tag_tree_row_tag-classic-rock')), findsNothing);
    });
  });

  group('showTagPickerDialog type-to-create & batch assignment', () {
    late MockAudioService service;

    setUp(() {
      service = MockAudioService();
    });

    tearDown(() {
      service.dispose();
    });

    testWidgets('pre-checks existing tags, creates new tag inline, and applies batch', (
      tester,
    ) async {
      bool? dialogResult;
      await tester.pumpWidget(
        _wrapApp(
          Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                key: const Key('btn_open_picker'),
                onPressed: () async {
                  dialogResult = await showTagPickerDialog(
                    context: ctx,
                    audioService: service,
                    entityType: TagEntityType.albumGroup,
                    entityIds: const ['alb-dsotm'],
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('btn_open_picker')));
      await tester.pumpAndSettle();

      // Existing tag-audiophile is pre-checked
      final existingTile = tester.widget<CheckboxListTile>(
        find.byKey(const Key('tag_picker_item_tag-audiophile')),
      );
      expect(existingTile.value, isTrue);

      // Type a brand-new tag name and click inline create
      await tester.enterText(
        find.byKey(const Key('tag_picker_search_input')),
        '黑膠母帶',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('btn_tag_picker_create_inline')), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_tag_picker_create_inline')));
      await tester.pumpAndSettle();

      // Confirm and apply
      await tester.tap(find.byKey(const Key('btn_tag_picker_confirm')));
      await tester.pumpAndSettle();

      expect(dialogResult, isTrue);
      final tagsAfter = await service.getEntityTags(
        TagEntityType.albumGroup,
        'alb-dsotm',
      );
      expect(tagsAfter.map((t) => t.name), containsAll(['發燒試音', '黑膠母帶']));
    });
  });

  group('FoldersView browsing, breadcrumbs, playback & album jump', () {
    late MockAudioService service;
    late LibraryIndexCache cache;

    setUp(() async {
      service = MockAudioService();
      cache = LibraryIndexCache();
      await cache.prime(service);
    });

    tearDown(() {
      cache.dispose();
      service.dispose();
    });

    testWidgets('drills root -> subfolder -> breadcrumbs -> play folder -> jump to album', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      String? openedAlbumId;
      await tester.pumpWidget(
        _wrapApp(
          FoldersView(
            audioService: service,
            libraryCache: cache,
            onOpenAlbumDetail: (id) => openedAlbumId = id,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Root visible -> tap into Music -> Pink Floyd -> DSOTM
      expect(find.byKey(const Key('folder_root_fld-root-music')), findsOneWidget);
      await tester.tap(find.byKey(const Key('folder_root_fld-root-music')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('folder_sub_fld-pink-floyd')), findsOneWidget);

      await tester.tap(find.byKey(const Key('folder_sub_fld-pink-floyd')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('folder_sub_fld-dsotm')), findsOneWidget);

      await tester.tap(find.byKey(const Key('folder_sub_fld-dsotm')));
      await tester.pumpAndSettle();

      // Direct tracks rendered + breadcrumbs rendered
      expect(find.byKey(const Key('folder_track_trk-001')), findsOneWidget);
      expect(find.byKey(const Key('folder_breadcrumb_fld-pink-floyd')), findsOneWidget);

      // Play current folder
      await tester.tap(find.byKey(const Key('btn_play_current_folder')));
      await tester.pumpAndSettle();
      expect(service.currentState.track?.id, 'trk-001');

      // Jump from track to album detail
      await tester.tap(find.byKey(const Key('btn_folder_track_album_trk-001')));
      await tester.pumpAndSettle();
      expect(openedAlbumId, 'alb-dsotm');

      // Navigate back via breadcrumb
      await tester.tap(find.byKey(const Key('folder_breadcrumb_fld-pink-floyd')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('folder_sub_fld-wall')), findsOneWidget);
    });
  });

  group('AlbumDetailPage & AlbumSelectionBar tag integration', () {
    testWidgets('renders album tag chips, manage tags button, and selection bar tag hook', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final service = MockAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(
        _wrapApp(
          AlbumDetailPage(
            albumId: 'alb-dsotm',
            audioService: service,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('album_detail_tag_chip_tag-audiophile')), findsOneWidget);
      expect(find.byKey(const Key('btn_album_manage_tags')), findsOneWidget);

      var manageTapped = false;
      await tester.pumpWidget(
        _wrapApp(
          AlbumSelectionBar(
            selectedAlbums: const [
              CanonicalAlbumSummary(
                id: 'alb-dsotm',
                title: 'The Dark Side of the Moon',
                artist: 'Pink Floyd',
              ),
            ],
            onMerge: () {},
            onGroupAsAlternate: () {},
            onToggleHide: () {},
            onManageTags: () => manageTapped = true,
            onClearSelection: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_selection_manage_tags')));
      expect(manageTapped, isTrue);
    });
  });
}
