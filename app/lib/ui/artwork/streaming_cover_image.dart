import 'package:material_ui/material_ui.dart';

import '../../models/streaming_models.dart';
import '../../services/streaming/streaming_provider.dart';

/// Scene-tiered streaming network cover widget with automatic URL resolution
/// upgrading and 404 fallback to the original URL or `hqdefault.jpg`.
class StreamingCoverImage extends StatefulWidget {
  final String? url;
  final int targetSize;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget Function(BuildContext context) fallbackBuilder;

  const StreamingCoverImage({
    super.key,
    this.url,
    this.targetSize = 1200,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    required this.fallbackBuilder,
  });

  @override
  State<StreamingCoverImage> createState() => _StreamingCoverImageState();
}

class _StreamingCoverImageState extends State<StreamingCoverImage> {
  bool _fallbackActive = false;

  @override
  void didUpdateWidget(covariant StreamingCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.targetSize != widget.targetSize) {
      _fallbackActive = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final normalized = normalizeStreamingCoverUrl(widget.url);
    if (normalized == null) {
      return widget.fallbackBuilder(context);
    }

    final primaryUrl =
        upgradeStreamingCoverUrl(normalized, targetSize: widget.targetSize) ??
            normalized;
    final fallbackUrl = fallbackStreamingCoverUrl(
      primaryUrl,
      originalUrl: normalized,
    );
    final effectiveUrl =
        (_fallbackActive && fallbackUrl != null) ? fallbackUrl : primaryUrl;
    final rawUrl = widget.url;
    final reqSize = widget.targetSize;

    return Image.network(
      effectiveUrl,
      key: ValueKey('streaming_cover_$effectiveUrl'),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      headers: BaseStreamingProvider.defaultImageHttpHeaders,
      filterQuality: FilterQuality.high,
      isAntiAlias: true,
      gaplessPlayback: true,
      errorBuilder: (context, error, _) {
        debugPrint('[CoverLoadError] $effectiveUrl -> $error');
        if (!_fallbackActive &&
            fallbackUrl != null &&
            fallbackUrl != effectiveUrl) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted ||
                _fallbackActive ||
                widget.url != rawUrl ||
                widget.targetSize != reqSize) {
              return;
            }
            setState(() => _fallbackActive = true);
          });
        }
        return widget.fallbackBuilder(context);
      },
    );
  }
}
