part of '../home_screen.dart';

extension _HomeInputAndNotices on _HomeScreenState {
  Future<void> _openExternalUrl(String url) async {
    try {
      await openSystemBrowser(
        url,
        urlOpener: _windowController.isSupported
            ? _windowController.openUrl
            : null,
      );
    } catch (_) {}
  }

  String? _fallbackWebUrlForTrack(TrackInfo track) {
    final id = track.id;
    if (id.startsWith('apple:')) {
      return 'https://music.apple.com';
    }
    if (id.startsWith('tidal:')) {
      return 'https://listen.tidal.com/track/${id.substring(6)}';
    }
    if (id.startsWith('deezer:')) {
      return 'https://www.deezer.com/track/${id.substring(7)}';
    }
    if (id.startsWith('ytm:')) {
      return 'https://music.youtube.com/watch?v=${id.substring(4)}';
    }
    if (id.startsWith('qobuz:')) {
      return 'https://play.qobuz.com';
    }
    return null;
  }

  void _showStreamingNoticeSnackBar(
    TrackInfo track,
    ResolvedStreamResult result,
  ) {
    if (!mounted) return;
    final notice =
        result.drmNotice ?? '目前播放為官方試聽片段（${result.format.label}）';
    final webUrl = result.externalWebUrl;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(notice),
          action: webUrl != null && webUrl.isNotEmpty
              ? SnackBarAction(
                  label: '於瀏覽器開啟',
                  textColor: LuminaTokens.accentBlue,
                  onPressed: () => _openExternalUrl(webUrl),
                )
              : null,
        ),
      );
  }

  void _showStreamingErrorSnackBar(
    TrackInfo track,
    String message,
    bool isDrmRestricted,
  ) {
    if (!mounted) return;
    final provider = _streamingManager.resolveProviderForTrack(track);
    final isAuthRequired =
        (provider != null &&
            (_streamingManager.isAuthRequired(provider.kind) ||
                provider.authState == StreamingAuthState.authRequired)) ||
        RegExp(
          r'\bAUTH_REQUIRED\b|HTTP\s*401\b|\b401\s+Unauthorized\b|重新登入|授權已失效',
          caseSensitive: false,
        ).hasMatch(message);
    final webUrl = isDrmRestricted ? _fallbackWebUrlForTrack(track) : null;
    final SnackBarAction? action;
    if (isAuthRequired && provider != null) {
      action = SnackBarAction(
        key: Key('snackbar_action_relogin_${provider.kind}'),
        label: '重新登入',
        textColor: LuminaTokens.accentBlue,
        onPressed: () {
          if (!mounted) return;
          unawaited(
            StreamingLoginDialog.show(context, provider, _streamingManager),
          );
        },
      );
    } else if (webUrl != null) {
      action = SnackBarAction(
        label: '於瀏覽器開啟',
        textColor: LuminaTokens.accentBlue,
        onPressed: () => _openExternalUrl(webUrl),
      );
    } else {
      action = null;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: LuminaTokens.statusErrorBg,
          content: Text(
            message,
            style: const TextStyle(color: Color(0xFFFECACA)),
          ),
          action: action,
        ),
      );
  }

  Future<void> _playStreamingTrack(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
  }) async {
    await _playbackSession.playTrack(track, queueContext: queueContext);
  }

  bool _isTextEditingFocused() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return false;
    final context = focus.context;
    if (context == null || !context.mounted) return false;
    if (context.widget is EditableText) return true;
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _onTopSearchFocusChanged() {
    if (!mounted) return;
    if (!_topSearchFocusNode.hasFocus &&
        _topSearchExpanded &&
        _topSearchController.text.trim().isEmpty) {
      _refreshState(() {
        _topSearchExpanded = false;
      });
    } else if (_topSearchExpanded) {
      _refreshState();
    }
  }

  void _expandTopSearch() {
    if (_isNowPlayingExpanded) {
      _setNowPlayingExpanded(false);
    }
    if (!_topSearchExpanded) {
      _refreshState(() {
        _topSearchExpanded = true;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_topSearchExpanded) return;
      _topSearchFocusNode.requestFocus();
    });
  }

  void _onTopSearchChanged(String value) {
    final trimmed = value.trim();
    _searchController.updateQuery(value);
    if (trimmed.isNotEmpty && _activeTab != HomeTab.search) {
      _pushEntry(NavEntry.tab(HomeTab.search));
    }
  }

  void _onTopSearchSubmitted(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      _searchController.clear();
      return;
    }
    _searchController.updateQuery(value, immediate: true);
    if (_activeTab != HomeTab.search) {
      _pushEntry(NavEntry.tab(HomeTab.search));
    }
  }

  void _handleTopSearchClearPressed() {
    if (_topSearchController.text.isNotEmpty) {
      _topSearchController.clear();
      _searchController.clear();
      if (_activeTab == HomeTab.search && _navController.canGoBack) {
        _goBack();
      }
      _topSearchFocusNode.requestFocus();
      _refreshState();
    } else {
      _searchController.clear();
      if (_activeTab == HomeTab.search && _navController.canGoBack) {
        _goBack();
      }
      _topSearchFocusNode.unfocus();
      _refreshState(() {
        _topSearchExpanded = false;
      });
    }
  }

  KeyEventResult _handleGlobalKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed;
    final meta = keyboard.isMetaPressed;
    final alt = keyboard.isAltPressed;
    final shift = keyboard.isShiftPressed;

    if ((ctrl || meta) && !alt && event.logicalKey == LogicalKeyboardKey.keyF) {
      _expandTopSearch();
      return KeyEventResult.handled;
    }

    // Critical guard: pass all editing keys (Backspace, Delete, Space, M,
    // arrows, Ctrl+A/C/V/X/Z, IME composition) to EditableText untouched.
    if (_isTextEditingFocused()) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.space && !ctrl && !alt && !meta) {
      _effectiveAudioService.togglePlayPause();
      return KeyEventResult.handled;
    }

    if (alt &&
        !ctrl &&
        !meta &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _goBack();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace &&
        !ctrl &&
        !alt &&
        !meta &&
        !shift) {
      _goBack();
      return KeyEventResult.handled;
    }

    if (alt &&
        !ctrl &&
        !meta &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _goForward();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyM && !ctrl && !alt && !meta) {
      _effectiveAudioService.toggleMute();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (!mounted) return false;
    if (event is KeyRepeatEvent) {
      return event.logicalKey == LogicalKeyboardKey.escape;
    }
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.f11) {
      unawaited(_windowController.toggleFullScreen());
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      return _handleEscape();
    }
    return false;
  }

  bool _handleEscape() {
    // 1. Active text input focus -> unfocus only (collapse empty top search).
    if (_isTextEditingFocused()) {
      FocusManager.instance.primaryFocus?.unfocus();
      if (_topSearchExpanded && _topSearchController.text.trim().isEmpty) {
        _refreshState(() {
          _topSearchExpanded = false;
        });
      }
      return true;
    }

    // 2. Floating layers (non-Navigator popovers -> root Navigator dialogs ->
    //    Now Playing lyrics settings toolbar -> expanded top search box).
    if (EscapeDismissRegistry.instance.dismissTopmost()) {
      return true;
    }
    final rootNav = Navigator.maybeOf(context, rootNavigator: true);
    if (rootNav != null && rootNav.canPop()) {
      unawaited(rootNav.maybePop());
      return true;
    }
    if (_isNowPlayingExpanded && _nowPlayingController.lyricsSettingsExpanded) {
      _nowPlayingController.setLyricsSettingsExpanded(false);
      return true;
    }
    final isDetailRoute =
        _activeTab == HomeTab.albumDetail ||
        _activeTab == HomeTab.artistDetail ||
        _activeTab == HomeTab.podcastDetail;
    if (_topSearchExpanded && !_isNowPlayingExpanded && !isDetailRoute) {
      _refreshState(() {
        _topSearchExpanded = false;
      });
      return true;
    }

    // 3. Exit fullscreen mode.
    if (_windowController.isFullScreenNotifier.value) {
      unawaited(_windowController.setFullScreen(false));
      return true;
    }

    // 4. Collapse Now Playing overlay.
    if (_isNowPlayingExpanded) {
      _setNowPlayingExpanded(false);
      return true;
    }

    // 5. Step back in workspace navigation history.
    if (_navController.canGoBack) {
      _goBack();
      return true;
    }

    return false;
  }

  void _scheduleFallbackClearanceSync(double fallback) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _measuredMiniPlayerHeight.value != null) return;
      if ((_effectiveMiniPlayerClearance.value - fallback).abs() > 0.5) {
        _effectiveMiniPlayerClearance.value = fallback;
      }
    });
  }

  void _handleMiniPlayerHeightMeasured(double height) {
    if (_lastReportedMiniPlayerHeight != null &&
        (height - _lastReportedMiniPlayerHeight!).abs() <= 0.5) {
      return;
    }
    _lastReportedMiniPlayerHeight = height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = _measuredMiniPlayerHeight.value;
      if (current == null || (current - height).abs() > 0.5) {
        _measuredMiniPlayerHeight.value = height;
      }
      if ((_effectiveMiniPlayerClearance.value - height).abs() > 0.5) {
        _effectiveMiniPlayerClearance.value = height;
      }
    });
  }
}
