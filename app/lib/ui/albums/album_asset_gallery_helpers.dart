part of 'album_asset_gallery_lightbox.dart';

String formatAlbumAssetRoleLabel(AlbumAssetRole role) => switch (role) {
  AlbumAssetRole.front => '封面 Front',
  AlbumAssetRole.back => '封底 Back',
  AlbumAssetRole.media => '光碟 Media',
  AlbumAssetRole.booklet => '小冊子 Booklet',
  AlbumAssetRole.other => '其他 Other',
};

String formatAlbumAssetFileSize(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}

/// Wraps an album cover with click cursor + optional multi-image badge pill.
class AlbumCoverGalleryTrigger extends StatelessWidget {
  final int imageCount;
  final VoidCallback onOpenGallery;
  final Widget child;

  const AlbumCoverGalleryTrigger({
    super.key,
    required this.imageCount,
    required this.onOpenGallery,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = imageCount > 0;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onOpenGallery : null,
        child: Stack(
          children: [
            child,
            if (imageCount > 1)
              Positioned(
                right: 8,
                bottom: 8,
                child: IgnorePointer(
                  child: FrostedGlassContainer(
                    key: const Key('album_cover_gallery_badge'),
                    blurSigma: LuminaTokens.glassPillBlur,
                    color: const Color(0xB3101216),
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
                    border: Border.all(color: LuminaTokens.glassPillBorder),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.photo_library_outlined,
                          size: 12,
                          color: LuminaTokens.glassTextPrimary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '$imageCount 張圖片',
                          style: const TextStyle(
                            color: LuminaTokens.glassTextPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Frosted Glass picker dialog when an album version has multiple PDF booklets.
Future<AlbumAssetRecord?> showAlbumPdfPickerDialog(
  BuildContext context, {
  required List<AlbumAssetRecord> pdfs,
}) {
  return showDialog<AlbumAssetRecord>(
    context: context,
    barrierColor: LuminaTokens.scrimBg,
    builder: (ctx) => Dialog(
      key: const Key('album_pdf_picker_dialog'),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 420),
        child: FrostedGlassContainer(
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.menu_book_rounded,
                      size: 18,
                      color: LuminaTokens.glassTextPrimary,
                    ),
                    SizedBox(width: 8),
                    Text(
                      '選擇數位小冊子',
                      style: TextStyle(
                        color: LuminaTokens.glassTextPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: pdfs.length,
                    separatorBuilder: (_, _) => const Divider(
                      height: 1,
                      color: LuminaTokens.glassCardDivider,
                    ),
                    itemBuilder: (_, i) {
                      final pdf = pdfs[i];
                      final sizeLabel = formatAlbumAssetFileSize(pdf.fileSize);
                      final name = pdf.displayName.isNotEmpty
                          ? pdf.displayName
                          : '數位小冊子 ${i + 1}.pdf';
                      return ListTile(
                        key: Key('pdf_picker_item_${pdf.id}'),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        leading: const Icon(
                          Icons.picture_as_pdf_rounded,
                          size: 20,
                          color: LuminaTokens.accentBlue,
                        ),
                        title: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.glassTextPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: sizeLabel.isNotEmpty
                            ? Text(
                                sizeLabel,
                                style: const TextStyle(
                                  color: LuminaTokens.textMuted,
                                  fontSize: 12,
                                ),
                              )
                            : null,
                        onTap: () => Navigator.of(ctx).pop(pdf),
                      );
                    },
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceSm),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: LuminaTokens.glassTextSecondary,
                    ),
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('取消'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _NavCircleButton extends StatelessWidget {
  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _NavCircleButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return FrostedGlassContainer(
      blurSigma: LuminaTokens.glassPillBlur,
      color: LuminaTokens.glassDialogBg,
      borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
      border: Border.all(color: LuminaTokens.glassCardBorder),
      child: IconButton(
        key: buttonKey,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 26, color: LuminaTokens.glassTextPrimary),
      ),
    );
  }
}
