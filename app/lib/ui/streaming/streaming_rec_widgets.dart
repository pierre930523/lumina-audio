part of 'streaming_service_view.dart';

extension _StreamingRecWidgets on _StreamingServiceViewState {
  Widget? _buildRefreshRecButton({
    required Key buttonKey,
    required bool isLoading,
  }) {
    if (widget.streamingManager == null) return null;
    return TextButton.icon(
      key: buttonKey,
      onPressed: isLoading ? null : _handleRefreshRecommendations,
      style: TextButton.styleFrom(
        foregroundColor: LuminaTokens.textSecondary,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: const Size(0, 28),
      ),
      icon: isLoading
          ? const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: LuminaTokens.glassTextPrimary,
              ),
            )
          : const Icon(Icons.refresh_rounded, size: 15),
      label: const Text(
        '換一批',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildRecErrorBanner(String kind, String recError) {
    final sm = widget.streamingManager;
    final msg = recError.trim();
    final isExpired =
        (sm?.isRecommendationTokenExpired(kind) ?? false) ||
        msg.contains('401') ||
        msg.contains('過期') ||
        msg.contains('失效');
    return Container(
      key: Key('rec_error_banner_$kind'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: LuminaTokens.statusError.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusError.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 17,
            color: LuminaTokens.statusError,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '${widget.provider.name}：'
              '${isExpired ? "授權權杖已過期或失效（$msg），請重新登入或重試。" : msg}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFFECDD3),
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: Key('btn_retry_rec_$kind'),
            onPressed: sm != null ? _handleRefreshRecommendations : null,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: const Size(0, 28),
            ),
            child: const Text(
              '重試',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (isExpired)
            TextButton(
              key: Key('btn_rec_open_settings_$kind'),
              onPressed: widget.onOpenProviderSettings,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                minimumSize: const Size(0, 28),
              ),
              child: const Text(
                '帳號設定',
                style: TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRecommendedAlbumsSkeleton(double availW) {
    final cols = _stripColumnCount(availW);
    return Row(
      key: const Key('rec_albums_skeleton'),
      children: [
        for (var i = 0; i < cols; i++) ...[
          if (i > 0) const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  height: 12,
                  width: 90,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 5),
                Container(
                  height: 10,
                  width: 60,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRecommendedTracksSkeleton() {
    return Column(
      key: const Key('rec_tracks_skeleton'),
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 12,
                        width: 160,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        height: 10,
                        width: 110,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
