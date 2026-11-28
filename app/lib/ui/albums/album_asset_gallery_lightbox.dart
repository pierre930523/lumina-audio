import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';

part 'album_asset_gallery_helpers.dart';

/// Fullscreen Frosted Glass multi-image gallery lightbox with lazy loading,
/// pan/zoom (`InteractiveViewer`), keyboard navigation, and thumbnail strip.
class AlbumAssetGalleryLightbox extends StatefulWidget {
  final AudioService audioService;
  final List<AlbumAssetRecord> images;
  final int initialIndex;

  const AlbumAssetGalleryLightbox({
    super.key,
    required this.audioService,
    required this.images,
    this.initialIndex = 0,
  });

  static Future<void> show(
    BuildContext context, {
    required AudioService audioService,
    required List<AlbumAssetRecord> images,
    int initialIndex = 0,
  }) {
    if (images.isEmpty) return Future<void>.value();
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '關閉圖片檢視器',
      barrierColor: LuminaTokens.scrimBg,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, _) => AlbumAssetGalleryLightbox(
        key: const Key('album_asset_gallery_lightbox'),
        audioService: audioService,
        images: images,
        initialIndex: initialIndex.clamp(0, images.length - 1),
      ),
      transitionBuilder: (_, anim, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: LuminaTokens.motionCurve),
        child: child,
      ),
    );
  }

  @override
  State<AlbumAssetGalleryLightbox> createState() =>
      _AlbumAssetGalleryLightboxState();
}

class _AlbumAssetGalleryLightboxState extends State<AlbumAssetGalleryLightbox> {
  final TransformationController _transformCtrl = TransformationController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'album_gallery_lightbox');
  final Map<String, Uint8List?> _byteCache = <String, Uint8List?>{};
  final Set<String> _loadingIds = <String>{};
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.images.length - 1);
    _ensureLoaded(widget.images[_index].id);
    for (final img in widget.images.take(8)) {
      _ensureLoaded(img.id);
    }
  }

  @override
  void dispose() {
    _transformCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _ensureLoaded(String assetId) async {
    if (_byteCache.containsKey(assetId) || _loadingIds.contains(assetId)) {
      return;
    }
    _loadingIds.add(assetId);
    try {
      final bytes = await widget.audioService.readAlbumAssetBytes(assetId);
      if (!mounted) return;
      setState(() {
        _byteCache[assetId] = bytes;
        _loadingIds.remove(assetId);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _byteCache[assetId] = null;
        _loadingIds.remove(assetId);
      });
    }
  }

  void _selectIndex(int next) {
    if (widget.images.isEmpty) return;
    final clamped = next.clamp(0, widget.images.length - 1);
    if (clamped == _index) return;
    _resetZoom();
    setState(() => _index = clamped);
    _ensureLoaded(widget.images[clamped].id);
  }

  void _step(int delta) {
    if (widget.images.length <= 1) return;
    final next = (_index + delta) % widget.images.length;
    _selectIndex(next < 0 ? next + widget.images.length : next);
  }

  void _zoomBy(double factor) {
    final current = _transformCtrl.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(0.5, 5.0);
    _transformCtrl.value = Matrix4.diagonal3Values(target, target, 1.0);
  }

  void _resetZoom() {
    _transformCtrl.value = Matrix4.identity();
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      _step(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _step(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      _zoomBy(1.25);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      _zoomBy(0.8);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.images[_index];
    final bytes = _byteCache[asset.id];
    final isLoading = !_byteCache.containsKey(asset.id);
    final resLabel = (asset.width != null &&
            asset.height != null &&
            asset.width! > 0 &&
            asset.height! > 0)
        ? '${asset.width} × ${asset.height}'
        : null;
    final sizeLabel = formatAlbumAssetFileSize(asset.fileSize);

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(LuminaTokens.spaceMd),
            child: Column(
              children: [
                _buildTopBar(asset, resLabel, sizeLabel),
                const SizedBox(height: LuminaTokens.spaceSm),
                Expanded(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: _buildViewport(asset, bytes, isLoading),
                      ),
                      if (widget.images.length > 1) ...[
                        Positioned(
                          left: 12,
                          child: _NavCircleButton(
                            buttonKey: const Key('btn_lightbox_prev'),
                            icon: Icons.chevron_left_rounded,
                            tooltip: '上一張 (←)',
                            onPressed: () => _step(-1),
                          ),
                        ),
                        Positioned(
                          right: 12,
                          child: _NavCircleButton(
                            buttonKey: const Key('btn_lightbox_next'),
                            icon: Icons.chevron_right_rounded,
                            tooltip: '下一張 (→)',
                            onPressed: () => _step(1),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.images.length > 1) ...[
                  const SizedBox(height: LuminaTokens.spaceSm),
                  _buildThumbnailStrip(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(
    AlbumAssetRecord asset,
    String? resLabel,
    String sizeLabel,
  ) {
    return FrostedGlassContainer(
      blurSigma: LuminaTokens.glassDialogBlur,
      color: LuminaTokens.glassDialogBg,
      borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
      border: Border.all(color: LuminaTokens.glassCardBorder),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Container(
            key: const Key('lightbox_role_badge'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: LuminaTokens.accentBlue.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
              border: Border.all(
                color: LuminaTokens.accentBlue.withValues(alpha: 0.45),
              ),
            ),
            child: Text(
              formatAlbumAssetRoleLabel(asset.role),
              style: const TextStyle(
                color: LuminaTokens.glassTextPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (asset.displayName.isNotEmpty)
                  Text(
                    asset.displayName,
                    key: const Key('lightbox_display_name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.glassTextPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (resLabel != null)
                  Text(
                    resLabel,
                    key: const Key('lightbox_resolution'),
                    style: const TextStyle(
                      color: LuminaTokens.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                if (sizeLabel.isNotEmpty)
                  Text(
                    sizeLabel,
                    style: const TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            '${_index + 1} / ${widget.images.length}',
            key: const Key('lightbox_counter'),
            style: const TextStyle(
              color: LuminaTokens.glassTextSecondary,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const Key('btn_lightbox_zoom_out'),
            tooltip: '縮小 (-)',
            onPressed: () => _zoomBy(0.8),
            icon: const Icon(Icons.zoom_out_rounded, size: 18),
            color: LuminaTokens.glassTextPrimary,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            key: const Key('btn_lightbox_zoom_in'),
            tooltip: '放大 (+)',
            onPressed: () => _zoomBy(1.25),
            icon: const Icon(Icons.zoom_in_rounded, size: 18),
            color: LuminaTokens.glassTextPrimary,
            visualDensity: VisualDensity.compact,
          ),
          TextButton(
            key: const Key('btn_lightbox_zoom_reset'),
            onPressed: _resetZoom,
            style: TextButton.styleFrom(
              foregroundColor: LuminaTokens.glassTextSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('重設縮放', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const Key('btn_lightbox_close'),
            tooltip: '關閉 (Esc)',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, size: 20),
            color: LuminaTokens.glassTextPrimary,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildViewport(
    AlbumAssetRecord asset,
    Uint8List? bytes,
    bool isLoading,
  ) {
    if (isLoading) {
      return const Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: LuminaTokens.glassTextPrimary,
        ),
      );
    }
    if (bytes == null || bytes.isEmpty) {
      return const Center(
        child: Text(
          '無法載入此圖片',
          style: TextStyle(color: LuminaTokens.textSecondary, fontSize: 13),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
      child: InteractiveViewer(
        key: Key('lightbox_interactive_viewer_${asset.id}'),
        transformationController: _transformCtrl,
        minScale: 0.5,
        maxScale: 5.0,
        child: Center(
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const Text(
              '圖片格式無效',
              style: TextStyle(color: LuminaTokens.textSecondary),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnailStrip() {
    return FrostedGlassContainer(
      key: const Key('lightbox_thumbnail_strip'),
      blurSigma: LuminaTokens.glassPillBlur,
      color: LuminaTokens.glassDialogBg,
      borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
      border: Border.all(color: LuminaTokens.glassCardBorder),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: SizedBox(
        height: 56,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          shrinkWrap: true,
          itemCount: widget.images.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final item = widget.images[i];
            _ensureLoaded(item.id);
            final thumbBytes = _byteCache[item.id];
            final selected = i == _index;
            return GestureDetector(
              key: Key('lightbox_thumb_$i'),
              onTap: () => _selectIndex(i),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: AnimatedContainer(
                  duration: LuminaTokens.hoverDuration,
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: LuminaTokens.glassPillBg,
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                    border: Border.all(
                      color: selected
                          ? LuminaTokens.accentBlue
                          : LuminaTokens.glassPillBorder,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: thumbBytes != null && thumbBytes.isNotEmpty
                      ? Image.memory(thumbBytes, fit: BoxFit.cover)
                      : const Icon(
                          Icons.image_outlined,
                          size: 18,
                          color: LuminaTokens.textMuted,
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
