part of 'streaming_service_view.dart';

extension _StreamingNotices on _StreamingServiceViewState {
  Widget _buildScrollableBody({
    required double availW,
    required StreamingProvider? liveProvider,
    required StreamingAccountInfo? accountInfo,
  }) {
    final slivers = <Widget>[
      ..._buildTopNoticeSlivers(accountInfo),
      ...switch (_selectedTab) {
        0 => _buildExploreSlivers(availW: availW),
        1 => _buildTracksSlivers(availW: availW, liveProvider: liveProvider),
        2 => _buildPlaylistsSlivers(availW: availW, liveProvider: liveProvider),
        _ => _buildAlbumsSlivers(availW: availW, liveProvider: liveProvider),
      },
      const SliverToBoxAdapter(
        child: SizedBox(height: LuminaTokens.floatingPlayerClearance),
      ),
    ];

    return SmoothScrollWrapper(
      controller: _scrollController,
      child: CustomScrollView(
        controller: _scrollController,
        slivers: slivers,
      ),
    );
  }

  List<Widget> _buildTopNoticeSlivers(StreamingAccountInfo? accountInfo) {
    final notices = <Widget>[];
    final sm = widget.streamingManager;
    final kind = widget.provider.kind;
    final liveProvider = _liveProvider;
    final isAuthRequired =
        (sm?.isAuthRequired(kind) ?? false) ||
        liveProvider?.authState == StreamingAuthState.authRequired;
    if (isAuthRequired) {
      final reason =
          sm?.authErrorFor(kind) ??
          liveProvider?.lastError ??
          '${widget.provider.name} 授權已失效，請重新登入以繼續播放';
      notices.add(_buildAuthRequiredBanner(reason, liveProvider: liveProvider));
    }
    final drm = accountInfo?.drmNotice?.trim();
    if (drm != null && drm.isNotEmpty) {
      notices.add(_buildDrmNoticeBanner(drm));
    }
    if (_syncNotice != null) {
      notices.add(_buildSyncNoticeBanner(_syncNotice!));
    }
    if (_errorMessage != null) {
      notices.add(_buildErrorBanner(_errorMessage!));
    }
    if (notices.isEmpty) return const <Widget>[];
    return <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < notices.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                notices[i],
              ],
            ],
          ),
        ),
      ),
    ];
  }

  Widget _buildAuthRequiredBanner(
    String message, {
    required StreamingProvider? liveProvider,
  }) {
    final kind = widget.provider.kind;
    final sm = widget.streamingManager;
    return Container(
      key: Key('streaming_auth_required_banner_$kind'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
            Icons.lock_reset_rounded,
            size: 16,
            color: LuminaTokens.statusError,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFFECACA),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: Key('btn_streaming_relogin_$kind'),
            onPressed: () async {
              if (sm != null && liveProvider != null) {
                final ok = await StreamingLoginDialog.show(
                  context,
                  liveProvider,
                  sm,
                );
                if (ok == true && mounted) {
                  _setState(() {});
                }
              } else {
                widget.onOpenProviderSettings();
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: LuminaTokens.statusError,
              foregroundColor: LuminaTokens.onAccentDark,
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text('重新登入'),
          ),
        ],
      ),
    );
  }

  Widget _buildDrmNoticeBanner(String notice) {
    return Container(
      key: const Key('streaming_drm_notice_banner'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: LuminaTokens.statusWarning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusWarning.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: LuminaTokens.statusWarning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              notice,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFFDE68A),
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncNoticeBanner(String message) {
    return Container(
      key: const Key('streaming_sync_notice_banner'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: LuminaTokens.statusSuccess.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusSuccess.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_outline_rounded,
            size: 15,
            color: LuminaTokens.statusSuccess,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: LuminaTokens.statusSuccess,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            tooltip: '關閉同步通知',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.close_rounded,
              size: 14,
              color: LuminaTokens.textSecondary,
            ),
            onPressed: () => _setState(() => _syncNotice = null),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      key: const Key('streaming_error_banner'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
            Icons.error_outline_rounded,
            size: 16,
            color: LuminaTokens.statusError,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFFECACA),
                fontSize: 12,
              ),
            ),
          ),
          IconButton(
            tooltip: '關閉錯誤訊息',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.close_rounded,
              size: 14,
              color: LuminaTokens.textSecondary,
            ),
            onPressed: () => _setState(() => _errorMessage = null),
          ),
        ],
      ),
    );
  }
}
