part of 'album_collection_card.dart';

extension _AlbumCollectionCardGlow on _AlbumCollectionCardState {
  Widget _buildFallbackGlowBox(double side) {
    return Container(
      width: side,
      height: side,
      decoration: const BoxDecoration(
        borderRadius: _AlbumCollectionCardState._coverRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF285E8E),
            Color(0xFF5B52F2),
            Color(0xFF1A2542),
          ],
        ),
      ),
    );
  }

  Widget _buildGlowSource(double side) {
    final cachePath = _resolvedCachePath;
    if (cachePath != null && cachePath.isNotEmpty) {
      return Image.file(
        File(cachePath),
        width: side,
        height: side,
        fit: BoxFit.cover,
        cacheWidth: 32,
        cacheHeight: 32,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _buildFallbackGlowBox(side),
      );
    }
    final coverUrl = _resolvedCoverUrl;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      return Image.network(
        coverUrl,
        width: side,
        height: side,
        fit: BoxFit.cover,
        cacheWidth: 32,
        cacheHeight: 32,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _buildFallbackGlowBox(side),
      );
    }
    return _buildFallbackGlowBox(side);
  }

  Widget _buildActionEntrance({required Widget child}) {
    return FadeTransition(
      opacity: _hoverCurve,
      child: AnimatedBuilder(
        animation: _buttonSlideAnimation,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, _buttonSlideAnimation.value),
            child: child,
          );
        },
        child: child,
      ),
    );
  }
}
