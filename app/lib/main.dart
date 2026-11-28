import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'services/artwork_palette_service.dart';
import 'services/audio_service.dart';
import 'services/ffi_audio_service.dart';
import 'services/now_playing_view_controller.dart';
import 'services/ui_scale_controller.dart';
import 'ui/home_screen.dart';
import 'ui/theme/lumina_tokens.dart';
import 'ui/theme/smooth_scroll.dart';

/// Desktop-friendly scroll behavior supporting mouse wheel, trackpad, touch,
/// and drag scrolling without mobile-style rubber-band overscroll jank.
class LuminaDesktopScrollBehavior extends MaterialScrollBehavior {
  @visibleForTesting
  final bool? forceDesktop;

  const LuminaDesktopScrollBehavior({this.forceDesktop});

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const ClampingScrollPhysics();
  }

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final Widget scrollbarChild;
    switch (axisDirectionToAxis(details.direction)) {
      case Axis.horizontal:
        scrollbarChild = child;
      case Axis.vertical:
        switch (getPlatform(context)) {
          case TargetPlatform.linux:
          case TargetPlatform.macOS:
          case TargetPlatform.windows:
            scrollbarChild = Scrollbar(
              controller: details.controller,
              thumbVisibility: false,
              interactive: true,
              child: child,
            );
          case TargetPlatform.android:
          case TargetPlatform.fuchsia:
          case TargetPlatform.iOS:
            scrollbarChild = child;
        }
    }

    final controller = details.controller;
    if (controller == null ||
        !isLuminaDesktopPlatform(forceDesktop: forceDesktop) ||
        SmoothScrollWrapper.isControllerManagedByAncestor(context, controller)) {
      return scrollbarChild;
    }

    return LuminaDesktopScrollScope(
      controller: controller,
      axisDirection: details.direction,
      forceDesktop: forceDesktop,
      child: scrollbarChild,
    );
  }
}

/// Propagates the current effective UI scale factor so artwork widgets can
/// compute exact HiDPI decode targets at 100%, 125%, 150%, etc.
class UiScaleScope extends InheritedWidget {
  final double scale;
  final bool scaleAppliedToMediaQuery;

  const UiScaleScope({
    super.key,
    required this.scale,
    this.scaleAppliedToMediaQuery = false,
    required super.child,
  });

  static double maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<UiScaleScope>()?.scale ??
        1.0;
  }

  static bool isAppliedToMediaQuery(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<UiScaleScope>()
            ?.scaleAppliedToMediaQuery ??
        false;
  }

  @override
  bool updateShouldNotify(covariant UiScaleScope oldWidget) =>
      (oldWidget.scale - scale).abs() > 0.001 ||
      oldWidget.scaleAppliedToMediaQuery != scaleAppliedToMediaQuery;
}

void _configureImageCache() {
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 500;
  imageCache.maximumSizeBytes = 256 << 20;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _configureImageCache();
  runApp(const LuminaApp());
}

class LuminaApp extends StatefulWidget {
  final AudioService? audioService;
  final UiScaleController? uiScaleController;
  final NowPlayingViewController? nowPlayingController;
  final ArtworkPaletteService? artworkPaletteService;

  const LuminaApp({
    super.key,
    this.audioService,
    this.uiScaleController,
    this.nowPlayingController,
    this.artworkPaletteService,
  });

  @override
  State<LuminaApp> createState() => _LuminaAppState();
}

class _LuminaAppState extends State<LuminaApp> with WidgetsBindingObserver {
  late final AudioService _audioService;
  late final bool _ownsService;
  late final UiScaleController _scaleController;
  late final bool _ownsScaleController;
  Size? _lastPhysicalSize;
  double? _lastDpr;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    _lastPhysicalSize = view?.physicalSize;
    _lastDpr = view?.devicePixelRatio;
    _configureImageCache();
    _ownsService = widget.audioService == null;
    _audioService = widget.audioService ?? FfiAudioService();
    _ownsScaleController = widget.uiScaleController == null;
    _scaleController = widget.uiScaleController ?? UiScaleController();
    _scaleController.loadSync();
    _scaleController.load(audioService: _audioService);
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final view =
        View.maybeOf(context) ??
        WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null) return;
    final nextSize = view.physicalSize;
    final nextDpr = view.devicePixelRatio;
    final sizeChanged =
        _lastPhysicalSize == null ||
        (_lastPhysicalSize!.width - nextSize.width).abs() > 0.001 ||
        (_lastPhysicalSize!.height - nextSize.height).abs() > 0.001;
    final dprChanged = _lastDpr == null || (_lastDpr! - nextDpr).abs() > 0.001;
    if (sizeChanged || dprChanged) {
      _lastPhysicalSize = nextSize;
      _lastDpr = nextDpr;
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsService) {
      _audioService.dispose();
    }
    if (_ownsScaleController) {
      _scaleController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _scaleController,
      builder: (context, _) {
        final scale = _scaleController.scale;
        return MaterialApp(
          title: 'Lumina Audio',
          debugShowCheckedModeBanner: false,
          scrollBehavior: const LuminaDesktopScrollBehavior(),
          theme: LuminaTokens.buildLightTheme(),
          darkTheme: LuminaTokens.buildDarkTheme(),
          themeMode: _scaleController.themeMode,
          builder: (context, child) {
            if (child == null) return const SizedBox.shrink();
            final isScaled = (scale - 1.0).abs() >= 0.001;
            final withShortcuts = UiScaleScope(
              scale: scale,
              scaleAppliedToMediaQuery: isScaled,
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(
                    LogicalKeyboardKey.equal,
                    control: true,
                  ): () => _scaleController.stepBy(0.10),
                  const SingleActivator(
                    LogicalKeyboardKey.numpadAdd,
                    control: true,
                  ): () => _scaleController.stepBy(0.10),
                  const SingleActivator(
                    LogicalKeyboardKey.minus,
                    control: true,
                  ): () => _scaleController.stepBy(-0.10),
                  const SingleActivator(
                    LogicalKeyboardKey.numpadSubtract,
                    control: true,
                  ): () => _scaleController.stepBy(-0.10),
                  const SingleActivator(
                    LogicalKeyboardKey.digit0,
                    control: true,
                  ): _scaleController.reset,
                },
                child: Focus(autofocus: false, child: child),
              ),
            );

            if (!isScaled) {
              return withShortcuts;
            }

            final mq = MediaQuery.of(context);
            final scaledSize = mq.size / scale;
            return MediaQuery(
              data: mq.copyWith(
                size: scaledSize,
                devicePixelRatio: mq.devicePixelRatio * scale,
                padding: mq.padding / scale,
                viewPadding: mq.viewPadding / scale,
                viewInsets: mq.viewInsets / scale,
              ),
              child: Align(
                alignment: Alignment.topLeft,
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: scaledSize.width,
                    height: scaledSize.height,
                    child: withShortcuts,
                  ),
                ),
              ),
            );
          },
          home: HomeScreen(
            audioService: _audioService,
            uiScaleController: _scaleController,
            nowPlayingController: widget.nowPlayingController,
            artworkPaletteService: widget.artworkPaletteService,
          ),
        );
      },
    );
  }
}
