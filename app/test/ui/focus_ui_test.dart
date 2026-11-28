import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/albums_and_credits_view.dart';
import 'package:lumina_app/ui/library/library_browser_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('Focus UI — Albums & Tracks Integration', () {
    late MockAudioService service;

    setUp(() {
      service = MockAudioService();
    });

    tearDown(() {
      service.dispose();
    });

    Widget wrap(Widget child) => MaterialApp(
      theme: LuminaTokens.buildDarkTheme(),
      home: Scaffold(
        backgroundColor: LuminaTokens.canvasBg,
        body: SizedBox(width: 1100, height: 800, child: child),
      ),
    );

    testWidgets(
      'Albums Focus drawer selects bucket with 150ms debounce, toggles include<->exclude capsule, removes & clears',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 960);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          wrap(AlbumsAndCreditsView(audioService: service)),
        );
        await tester.pumpAndSettle();

        // Initially shows both default mock albums (DSOTM & The Wall).
        expect(find.text('The Dark Side of the Moon'), findsOneWidget);
        expect(find.text('The Wall'), findsOneWidget);

        // Open Focus drawer.
        await tester.tap(find.byKey(const Key('btn_focus_toggle')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('focus_filter_drawer')), findsOneWidget);

        // Select source=qobuz bucket (DSOTM is qobuz primary, The Wall is tidal).
        final qobuzBucket = find.byKey(
          const Key('focus_bucket_source_qobuz'),
        );
        expect(qobuzBucket, findsOneWidget);
        await tester.tap(qobuzBucket);
        await tester.pump(const Duration(milliseconds: 50));
        // Still within 150ms debounce window — capsule appears immediately.
        expect(find.byKey(const Key('focus_capsule_0')), findsOneWidget);
        expect(find.textContaining('+ 來源: qobuz'), findsOneWidget);

        // Let 150ms debounce fire and settle.
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        expect(find.text('The Dark Side of the Moon'), findsOneWidget);
        expect(find.text('The Wall'), findsNothing);

        // Click capsule body to toggle `+ 包含` -> `- 排除` (red excluded state).
        await tester.tap(find.byKey(const Key('focus_capsule_toggle_0')));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        expect(find.textContaining('- 來源: qobuz'), findsOneWidget);
        // Now qobuz (DSOTM) is excluded, leaving The Wall!
        expect(find.text('The Wall'), findsOneWidget);
        expect(find.text('The Dark Side of the Moon'), findsNothing);

        // Add a second predicate (tag=tag-classic-rock) then remove capsule 0 via ×.
        final tagBucket = find.byKey(
          const Key('focus_bucket_tag_tag-classic-rock'),
        );
        await tester.ensureVisible(tagBucket);
        await tester.pumpAndSettle();
        await tester.tap(tagBucket);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('focus_capsule_1')), findsOneWidget);

        await tester.tap(find.byKey(const Key('focus_capsule_remove_0')));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('focus_capsule_1')), findsNothing);
        expect(find.byKey(const Key('focus_capsule_0')), findsOneWidget);

        // Clear all predicates restores full unfiltered list.
        await tester.tap(find.byKey(const Key('btn_focus_clear_all')));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('focus_active_capsules')), findsNothing);
        expect(find.text('The Dark Side of the Moon'), findsOneWidget);
        expect(find.text('The Wall'), findsOneWidget);
      },
    );

    testWidgets(
      'Tracks Focus supports initialFocusQuery, exclude toggle, and TrackSelectionBar multi-select',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            LibraryBrowserView(
              audioService: service,
              initialFocusQuery: const FocusQuery(
                entity: FocusEntity.tracks,
                predicates: [
                  FocusPredicate(
                    facet: FocusFacet.format,
                    value: FocusValue.string('flac'),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Only FLAC tracks (Time, Comfortably Numb) shown; DSF track (Money) filtered out.
        expect(find.text('Time'), findsOneWidget);
        expect(find.text('Comfortably Numb'), findsOneWidget);
        expect(find.text('Money'), findsNothing);
        expect(find.textContaining('+ 格式: FLAC'), findsOneWidget);

        // Toggle capsule to `- 排除` FLAC -> only DSF track (Money) shown!
        await tester.tap(find.byKey(const Key('focus_capsule_toggle_0')));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        expect(find.textContaining('- 格式: FLAC'), findsOneWidget);
        expect(find.text('Money'), findsOneWidget);
        expect(find.text('Time'), findsNothing);

        // Enter multi-select mode and select Money -> floating TrackSelectionBar appears.
        await tester.tap(find.byKey(const Key('btn_track_multi_select')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('queue_track_trk-002')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('track_selection_bar')), findsOneWidget);
        expect(find.text('已選取 1 首'), findsOneWidget);
        expect(
          find.byKey(const Key('btn_track_selection_tags')),
          findsOneWidget,
        );

        // Clear selection dismisses bar.
        await tester.tap(find.byKey(const Key('btn_track_selection_clear')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('track_selection_bar')), findsNothing);
      },
    );
  });
}
