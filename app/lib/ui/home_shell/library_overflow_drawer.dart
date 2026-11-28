import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/nav_entry.dart';
import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../models/studio_models.dart';
import '../../services/escape_dismiss_registry.dart';
import '../../services/listen_later_controller.dart';
import '../../services/smart_playlist_service.dart';
import '../../services/streaming/streaming_manager.dart';
import '../common/bottom_player_bar_scope.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_glass_theme.dart';
import '../theme/lumina_tokens.dart';
import '../theme/responsive_layout.dart';
import '../theme/smooth_scroll.dart';

/// Viewport-clamped frosted-glass popover anchor supporting Esc dismissal,
/// bottom mini-player clearance, and window-resize reflow.
class ClampedGlassPopoverAnchor extends StatefulWidget {
  final Key barrierKey;
  final Key popoverKey;
  final double preferredWidth;
  final double preferredMaxHeight;
  final Widget Function(BuildContext context, bool isOpen, VoidCallback toggle)
  anchorBuilder;
  final Widget Function(BuildContext context, VoidCallback close)
  popoverBuilder;

  const ClampedGlassPopoverAnchor({
    super.key,
    required this.barrierKey,
    required this.popoverKey,
    this.preferredWidth = 320.0,
    this.preferredMaxHeight = 540.0,
    required this.anchorBuilder,
    required this.popoverBuilder,
  });

  @override
  State<ClampedGlassPopoverAnchor> createState() =>
      _ClampedGlassPopoverAnchorState();
}

class _ClampedGlassPopoverAnchorState extends State<ClampedGlassPopoverAnchor>
    with WidgetsBindingObserver {
  final LayerLink _layerLink = LayerLink();
  final FocusNode _focusNode = FocusNode(debugLabel: 'clamped_glass_popover');
  OverlayEntry? _entry;
  ValueListenable<double>? _bottomClearance;
  bool _metricsScheduled = false;
  late final bool Function() _escapeHandler = _handleEscape;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    if (_entry == null || _metricsScheduled) return;
    _metricsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsScheduled = false;
      if (mounted) _entry?.markNeedsBuild();
    });
  }

  @override
  void didUpdateWidget(covariant ClampedGlassPopoverAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_entry != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entry?.markNeedsBuild();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _removeOverlay();
    _focusNode.dispose();
    super.dispose();
  }

  void _removeOverlay() {
    EscapeDismissRegistry.instance.unregister(_escapeHandler);
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
  }

  bool _handleEscape() {
    if (_entry == null) {
      EscapeDismissRegistry.instance.unregister(_escapeHandler);
      return false;
    }
    _close();
    return true;
  }

  void _close() {
    if (_entry == null) return;
    _removeOverlay();
    if (mounted) setState(() {});
  }

  void _toggle() {
    if (_entry != null) {
      _close();
      return;
    }
    _bottomClearance = BottomPlayerBarScope.listenableOf(context);
    final entry = OverlayEntry(
      builder: (ctx) => _bottomClearance == null
          ? _buildClamped(ctx, 0.0)
          : ValueListenableBuilder<double>(
              valueListenable: _bottomClearance!,
              builder: (c, clearance, _) => _buildClamped(c, clearance),
            ),
    );
    Overlay.of(context, rootOverlay: true).insert(entry);
    setState(() => _entry = entry);
    EscapeDismissRegistry.instance.register(_escapeHandler);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _entry != null) _focusNode.requestFocus();
    });
  }

  Widget _buildClamped(BuildContext overlayCtx, double bottomClearance) {
    final targetRender = context.mounted ? context.findRenderObject() : null;
    final overlayRender = Overlay.of(context, rootOverlay: true).context.findRenderObject();
    final targetBox = targetRender is RenderBox && targetRender.attached && targetRender.hasSize ? targetRender : null;
    final overlayBox = overlayRender is RenderBox && overlayRender.attached && overlayRender.hasSize ? overlayRender : null;
    final clamp = LuminaResponsive.computeClampedPopover(
      overlaySize: overlayBox?.size ?? MediaQuery.sizeOf(overlayCtx),
      targetTopLeft: (targetBox != null && overlayBox != null) ? targetBox.localToGlobal(Offset.zero, ancestor: overlayBox) : null,
      targetSize: targetBox?.size,
      preferredWidth: widget.preferredWidth,
      preferredMaxHeight: widget.preferredMaxHeight,
      topInset: MediaQuery.paddingOf(overlayCtx).top,
      bottomInset: bottomClearance,
    );
    final glass = LuminaGlassTheme.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(key: widget.barrierKey, behavior: HitTestBehavior.opaque, onTap: _close),
        ),
        CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          targetAnchor: clamp.targetAnchor,
          followerAnchor: clamp.followerAnchor,
          offset: clamp.offset,
          child: FocusScope(
            autofocus: true,
            child: Focus(
              focusNode: _focusNode,
              autofocus: true,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: clamp.width, maxHeight: clamp.maxHeight),
                  child: SizedBox(
                    width: clamp.width,
                    child: FrostedGlassContainer(
                      blurSigma: glass.glassBlur,
                      color: glass.dialogBg,
                      borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
                      border: Border.all(color: glass.glassBorderStrong),
                      boxShadow: glass.glassShadow,
                      child: Material(
                        key: widget.popoverKey,
                        type: MaterialType.transparency,
                        clipBehavior: Clip.antiAlias,
                        child: widget.popoverBuilder(context, _close),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
    link: _layerLink,
    child: widget.anchorBuilder(context, _entry != null, _toggle),
  );
}

/// Shared state & navigation callbacks consumed by [LibraryOverflowDrawerButton]
/// and [LibraryOverflowDrawer].
class LibraryOverflowConfig {
  final HomeTab activeTab;
  final String? selectedSmartPlaylistId;
  final String? selectedStreamingKind;
  final SmartPlaylistService playlistService;
  final ListenLaterController listenLaterController;
  final StreamingManager streamingManager;
  final List<ProviderStatusInfo> loggedInStreamingProviders;
  final ValueChanged<HomeTab> onSelectTab;
  final ValueChanged<String> onOpenSmartPlaylist;
  final VoidCallback onCreateSmartPlaylist;
  final ValueChanged<String> onOpenStreamingProvider;
  final void Function(SmartPlaylistItem playlist, Offset globalPosition)? onSecondaryTapSmartPlaylist;

  const LibraryOverflowConfig({
    required this.activeTab,
    required this.selectedSmartPlaylistId,
    required this.selectedStreamingKind,
    required this.playlistService,
    required this.listenLaterController,
    required this.streamingManager,
    required this.loggedInStreamingProviders,
    required this.onSelectTab,
    required this.onOpenSmartPlaylist,
    required this.onCreateSmartPlaylist,
    required this.onOpenStreamingProvider,
    this.onSecondaryTapSmartPlaylist,
  });

  bool get isDrawerTabActive => const {
    HomeTab.credits, HomeTab.smartPlaylists, HomeTab.listenLater, HomeTab.tags,
    HomeTab.folders, HomeTab.audiobooks, HomeTab.podcasts, HomeTab.podcastDetail,
    HomeTab.radio, HomeTab.streamingProvider,
  }.contains(activeTab);
}

/// Compact `⋯` trigger inside the centered top navigation capsule that opens a
/// viewport-clamped frosted-glass [LibraryOverflowDrawer] popover.
class LibraryOverflowDrawerButton extends StatelessWidget {
  final LibraryOverflowConfig config;
  final bool showLabel;

  const LibraryOverflowDrawerButton({super.key, required this.config, this.showLabel = false});

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    return ClampedGlassPopoverAnchor(
      barrierKey: const Key('topbar_library_drawer_barrier'),
      popoverKey: const Key('topbar_library_drawer_popover'),
      preferredWidth: 312.0,
      preferredMaxHeight: 540.0,
      anchorBuilder: (ctx, isOpen, toggle) {
        final active = isOpen || config.isDrawerTabActive;
        return Tooltip(
          message: '更多曲庫與媒體分類',
          child: Material(
            color: active ? glass.glassBgActive : Colors.transparent,
            borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
            child: InkWell(
              key: const Key('btn_topbar_library_drawer'),
              borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
              hoverColor: glass.pillHoverBg,
              onTap: toggle,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: showLabel ? 9 : 7, vertical: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.more_horiz_rounded, size: 16, color: active ? glass.textPrimary : glass.textSecondary),
                    if (showLabel) ...[
                      const SizedBox(width: 4),
                      Text('更多', style: TextStyle(color: active ? glass.textPrimary : glass.textSecondary, fontSize: 12, fontWeight: active ? FontWeight.w600 : FontWeight.w500)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
      popoverBuilder: (ctx, close) => ListenableBuilder(
        listenable: Listenable.merge([config.playlistService, config.listenLaterController]),
        builder: (ctx, _) => LibraryOverflowDrawer(config: config, onClose: close),
      ),
    );
  }
}

typedef _DrawerEntry = ({String key, HomeTab tab, IconData icon, IconData activeIcon, String label});

/// Content body of the library overflow drawer popover.
class LibraryOverflowDrawer extends StatefulWidget {
  final LibraryOverflowConfig config;
  final VoidCallback? onClose;

  const LibraryOverflowDrawer({super.key, required this.config, this.onClose});

  @override
  State<LibraryOverflowDrawer> createState() => _LibraryOverflowDrawerState();
}

class _LibraryOverflowDrawerState extends State<LibraryOverflowDrawer> {
  final GlideScrollController _scrollController = GlideScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  LibraryOverflowConfig get config => widget.config;
  VoidCallback? get onClose => widget.onClose;

  static const List<({String title, List<_DrawerEntry> items})> _sections = [
    (
      title: '瀏覽與探索',
      items: [
        (key: 'drawer_nav_credits', tab: HomeTab.credits, icon: Icons.account_tree_outlined, activeIcon: Icons.account_tree_rounded, label: '關係圖'),
        (key: 'drawer_nav_smart_playlists', tab: HomeTab.smartPlaylists, icon: Icons.auto_awesome_outlined, activeIcon: Icons.auto_awesome_rounded, label: '智慧歌單'),
        (key: 'drawer_nav_listen_later', tab: HomeTab.listenLater, icon: Icons.watch_later_outlined, activeIcon: Icons.watch_later_rounded, label: '稍後收聽'),
        (key: 'drawer_nav_tags', tab: HomeTab.tags, icon: Icons.label_outline_rounded, activeIcon: Icons.label_rounded, label: '標籤'),
        (key: 'drawer_nav_folders', tab: HomeTab.folders, icon: Icons.folder_outlined, activeIcon: Icons.folder_rounded, label: '資料夾'),
      ],
    ),
    (
      title: '媒體',
      items: [
        (key: 'drawer_nav_audiobooks', tab: HomeTab.audiobooks, icon: Icons.menu_book_outlined, activeIcon: Icons.menu_book_rounded, label: '有聲書'),
        (key: 'drawer_nav_podcasts', tab: HomeTab.podcasts, icon: Icons.podcasts_outlined, activeIcon: Icons.podcasts_rounded, label: 'Podcast'),
        (key: 'drawer_nav_radio', tab: HomeTab.radio, icon: Icons.radio_outlined, activeIcon: Icons.radio_rounded, label: '廣播電台'),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final pinned = config.playlistService.pinnedPlaylists;
    final pendingCount = config.listenLaterController.pendingCount;

    return SmoothScrollWrapper(
      controller: _scrollController,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.all(LuminaTokens.spaceSm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              children: [
                Expanded(child: Text('曲庫抽屜', style: TextStyle(color: glass.textPrimary, fontSize: 13.5, fontWeight: FontWeight.w700))),
                if (onClose != null)
                  IconButton(
                    key: const Key('btn_drawer_close'),
                    tooltip: '關閉抽屜',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                    padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(foregroundColor: glass.textSecondary, hoverColor: glass.glassBgHover),
                    icon: const Icon(Icons.close_rounded, size: 15),
                    onPressed: onClose,
                  ),
              ],
            ),
          ),
          Divider(color: glass.glassBorder, height: 12),
          for (final sec in _sections) ...[
            _sectionLabel(glass, sec.title),
            for (final item in sec.items)
              _drawerTile(
                glass,
                key: Key(item.key),
                icon: _isSelected(item.tab) ? item.activeIcon : item.icon,
                label: item.label,
                selected: _isSelected(item.tab),
                trailing: item.tab == HomeTab.listenLater && pendingCount > 0 ? _pendingBadge(glass, pendingCount) : null,
                onTap: () { onClose?.call(); config.onSelectTab(item.tab); },
              ),
            const SizedBox(height: 6),
          ],
          if (config.loggedInStreamingProviders.isNotEmpty) ...[
            _sectionLabel(glass, '串流服務'),
            for (final p in config.loggedInStreamingProviders)
              if (StreamingProviderMeta.byKind(p.kind) case final meta?) _buildStreamingTile(glass, meta),
            const SizedBox(height: 6),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 2, 2),
            child: Row(
              children: [
                Expanded(child: Text('智慧播放清單', style: TextStyle(color: glass.textTertiary, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.4))),
                TextButton.icon(
                  key: const Key('btn_drawer_new_smart_playlist'),
                  onPressed: () { onClose?.call(); config.onCreateSmartPlaylist(); },
                  style: TextButton.styleFrom(foregroundColor: glass.textSecondary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), minimumSize: const Size(0, 26), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  icon: const Icon(Icons.add_rounded, size: 14),
                  label: const Text('新增智慧歌單', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ),
          for (final sp in pinned)
            GestureDetector(
              onSecondaryTapUp: config.onSecondaryTapSmartPlaylist != null ? (d) => config.onSecondaryTapSmartPlaylist!(sp, d.globalPosition) : null,
              child: _drawerTile(
                glass,
                key: Key('drawer_smart_playlist_${sp.id}'),
                icon: Icons.auto_awesome_rounded,
                label: sp.name,
                selected: config.activeTab == HomeTab.smartPlaylists && config.selectedSmartPlaylistId == sp.id,
                onTap: () { onClose?.call(); config.onOpenSmartPlaylist(sp.id); },
              ),
            ),
        ],
      ),
      ),
    );
  }

  bool _isSelected(HomeTab tab) => config.activeTab == tab || (tab == HomeTab.podcasts && config.activeTab == HomeTab.podcastDetail);

  Widget _pendingBadge(LuminaGlassTheme glass, int count) => Container(
    key: const Key('drawer_listen_later_badge'),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
    decoration: BoxDecoration(color: glass.accent.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(999), border: Border.all(color: glass.accent.withValues(alpha: 0.55))),
    child: Text('$count', style: TextStyle(color: glass.textPrimary, fontSize: 10.5, fontWeight: FontWeight.w700)),
  );

  Widget _sectionLabel(LuminaGlassTheme glass, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
    child: Text(title, style: TextStyle(color: glass.textTertiary, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.4)),
  );

  Widget _buildStreamingTile(LuminaGlassTheme glass, StreamingProviderMeta meta) {
    final isSelected = config.activeTab == HomeTab.streamingProvider && config.selectedStreamingKind == meta.kind;
    final provider = config.streamingManager.providerFor(meta.kind);
    final isAuthRequired = config.streamingManager.isAuthRequired(meta.kind) || provider?.authState == StreamingAuthState.authRequired;
    final isConnected = !isAuthRequired && provider?.authState == StreamingAuthState.connected;
    final dotColor = isAuthRequired ? LuminaTokens.statusError : (isConnected ? LuminaTokens.statusSuccess : glass.accent.withValues(alpha: 0.78));

    return _drawerTile(
      glass,
      key: Key('drawer_streaming_${meta.kind}'),
      leading: meta.buildBadge(boxSize: 19, borderRadius: 5),
      label: meta.name,
      selected: isSelected,
      trailing: Tooltip(
        message: isAuthRequired ? '授權已失效，請重新登入' : (isConnected ? '已連線' : '探索模式'),
        child: Container(key: Key('drawer_streaming_status_dot_${meta.kind}'), width: 6, height: 6, decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle)),
      ),
      onTap: () { onClose?.call(); config.onOpenStreamingProvider(meta.kind); },
    );
  }

  Widget _drawerTile(LuminaGlassTheme glass, {required Key key, IconData? icon, Widget? leading, required String label, required bool selected, Widget? trailing, required VoidCallback onTap}) {
    return Material(
      color: selected ? glass.glassBgActive : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(8),
        hoverColor: glass.glassBgHover,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6.5),
          child: Row(
            children: [
              leading ?? Icon(icon, size: 16, color: selected ? glass.textPrimary : glass.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: selected ? glass.textPrimary : glass.textSecondary, fontSize: 12.5, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}
