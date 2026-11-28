part of '../ffi_audio_service.dart';

mixin _FfiNativeBindingMixin on _FfiAudioServiceBase {
  void _onNativeScanProgress(ffi.Pointer<ffi.Uint8> jsonPtr) {
    // Ownership contract: ALWAYS free jsonPtr via lumina_string_free inside
    // _takeRustString before any early return.
    String? rawJson;
    try {
      rawJson = _takeRustString(jsonPtr);
    } catch (_) {
      rawJson = null;
    }
    if (_disposed || rawJson == null || rawJson.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map) {
        final ev = ScanProgressEvent.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        if (ev.state == ScanLifecycleState.completed) {
          // Await native track reload BEFORE dispatching the terminal completed
          // event so UI listeners (e.g. LibraryIndexCache.refresh) never read
          // a stale audioService.queue.
          unawaited(
            _reloadTracksFromNativeAsync(scanId: ev.scanId).whenComplete(() {
              if (_disposed) return;
              _emitState(_state);
              if (!_scanProgressController.isClosed) {
                _scanProgressController.add(ev);
              }
            }),
          );
          return;
        }
        if (!_scanProgressController.isClosed) {
          _scanProgressController.add(ev);
        }
      }
    } catch (_) {}
  }

  void _registerNativeScanProgressCallback() {
    final setCb = _libSetScanProgressCbFn;
    if (setCb == null || !isNativeBound || _disposed) return;
    try {
      final callable =
          ffi.NativeCallable<_LuminaScanProgressCbNative>.listener(
        _onNativeScanProgress,
      );
      _scanProgressCallable = callable;
      setCb(callable.nativeFunction);
    } catch (_) {
      _scanProgressCallable?.close();
      _scanProgressCallable = null;
    }
  }

  void _syncNativeDevicesAndZones() {
    if (!isNativeBound) return;
    if (_audioListDevicesFn != null) {
      final raw = _takeRustString(_audioListDevicesFn!());
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _tracker.syncActiveFromDevices(
            decoded
                .whereType<Map<String, dynamic>>()
                .map(AudioDeviceInfo.fromJson)
                .toList(),
          );
        }
      }
    }
    if (_zoneListFn != null) {
      final raw = _takeRustString(_zoneListFn!());
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _tracker.syncZones(
            decoded
                .whereType<Map<String, dynamic>>()
                .map(AudioZoneInfo.fromJson)
                .toList(),
            activeLocalState: _state,
          );
        }
      }
    }
  }

  void _tryLoadNativeLibrary({required bool headless, String? databasePath}) {
    try {
      final libName = Platform.isWindows
          ? 'core_ffi.dll'
          : (Platform.isMacOS ? 'libcore_ffi.dylib' : 'libcore_ffi.so');
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final candidates = [
        '$exeDir${Platform.pathSeparator}$libName',
        libName,
        '../target/debug/$libName',
        '../target/release/$libName',
        'target/debug/$libName',
        'target/release/$libName',
      ];
      for (final path in candidates) {
        if (File(path).existsSync()) {
          final resolvedPath = File(path).absolute.path;
          _dylib = ffi.DynamicLibrary.open(resolvedPath);
          _dylibPath = resolvedPath;
          break;
        }
      }
      final dylib = _dylib;
      if (dylib == null) {
        return;
      }

      _initFn = dylib.lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_init',
      );
      _initHeadlessFn = dylib
          .lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_init_headless',
      );
      _shutdownFn = dylib
          .lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_shutdown',
      );
      _bytesAllocFn = dylib
          .lookupFunction<_LuminaBytesAllocNative, _LuminaBytesAllocDart>(
        'lumina_bytes_alloc',
      );
      _bytesFreeFn = dylib
          .lookupFunction<_LuminaBytesFreeNative, _LuminaBytesFreeDart>(
        'lumina_bytes_free',
      );
      _stringFreeFn = dylib
          .lookupFunction<_LuminaStringFreeNative, _LuminaStringFreeDart>(
        'lumina_string_free',
      );
      _libInitFn = dylib
          .lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
        'lumina_library_init',
      );
      dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_scan_dir',
      );
      _libGetTracksFn = dylib
          .lookupFunction<_LuminaLimitPtrNative, _LuminaLimitPtrDart>(
        'lumina_library_get_tracks',
      );
      dylib.lookupFunction<_LuminaSearchNative, _LuminaSearchDart>(
        'lumina_library_search',
      );
      _playFn = dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
        'lumina_playback_play',
      );
      _pauseFn = dylib
          .lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_playback_pause',
      );
      _stopFn = dylib.lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_playback_stop',
      );
      _seekFn = dylib.lookupFunction<_LuminaSeekNative, _LuminaSeekDart>(
        'lumina_playback_seek',
      );
      _setVolumeFn = dylib
          .lookupFunction<_LuminaSetVolumeNative, _LuminaSetVolumeDart>(
        'lumina_playback_set_volume',
      );
      _getStateFn = dylib
          .lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_playback_get_state',
      );
      _getPositionFn = dylib
          .lookupFunction<_LuminaVoidU64Native, _LuminaVoidU64Dart>(
        'lumina_playback_get_position_ms',
      );
      _getDurationFn = dylib
          .lookupFunction<_LuminaVoidU64Native, _LuminaVoidU64Dart>(
        'lumina_playback_get_duration_ms',
      );
      _signalPathGetFn = dylib
          .lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
        'lumina_signal_path_get',
      );
      _toggleBypassFn = dylib
          .lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_signal_path_toggle_dsp_bypass',
      );

      F? tryLookup<F>(F Function() lookup) {
        try {
          return lookup();
        } catch (_) {
          return null;
        }
      }

      _lastErrorMsgFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_last_error_message'));

      _getAlbumsFn = tryLookup(() => dylib.lookupFunction<_LuminaLimitPtrNative, _LuminaLimitPtrDart>('lumina_library_get_albums'));
      _getAlbumDetailFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_library_get_album_detail'));
      _getArtistDetailFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_library_get_artist_detail'));
      _enrichCreditsFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_library_enrich_credits'));
      _deduplicateFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_library_deduplicate'));
      _profileListFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_profile_list'));
      _profileCreateFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_profile_create'));
      _profileUpdateFn = tryLookup(() => dylib.lookupFunction<_LuminaStrStrIntNative, _LuminaStrStrIntDart>('lumina_profile_update'));
      _profileDeleteFn = tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_profile_delete'));
      _profileSwitchFn = tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_profile_switch'));
      _audioListDevicesFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_audio_list_devices'));
      _audioSelectDeviceFn = tryLookup(() => dylib.lookupFunction<_LuminaStrI32IntNative, _LuminaStrI32IntDart>('lumina_audio_select_device'));
      _audioGetOutputInfoFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_audio_get_output_info'));
      _audioListDeviceCapsFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_audio_list_device_capabilities'));
      _audioSetStrictModeFn = tryLookup(() => dylib.lookupFunction<_LuminaIntToIntNative, _LuminaIntToIntDart>('lumina_audio_set_strict_mode'));
      _audioSetDsdModeFn = tryLookup(() => dylib.lookupFunction<_LuminaIntToIntNative, _LuminaIntToIntDart>('lumina_audio_set_dsd_mode'));
      _audioSetBufferFramesFn = tryLookup(() => dylib.lookupFunction<_LuminaU32ToIntNative, _LuminaU32ToIntDart>('lumina_audio_set_buffer_frames'));
      _dspGetConfigFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_dsp_get_config'));
      _dspSetConfigFn = tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_dsp_set_config'));
      _dspImportAutoeqFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_dsp_import_autoeq'));
      _providerConfigureFn = tryLookup(() => dylib.lookupFunction<_LuminaStrStrIntNative, _LuminaStrStrIntDart>('lumina_provider_configure'));
      _providerSyncFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_provider_sync'));
      _tidalPkceStartFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_provider_tidal_pkce_start'));
      _tidalPkceCompleteFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_provider_tidal_pkce_complete'));
      _zoneListFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_zone_list'));
      _zoneDiscoverFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_zone_discover'));
      _zoneGroupFn = tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_zone_group'));
      _zoneSetVolumeFn = tryLookup(() => dylib.lookupFunction<_LuminaStrFloatIntNative, _LuminaStrFloatIntDart>('lumina_zone_set_volume'));
      _zoneSyncStatusFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_zone_sync_status'));
      _serverStartFn = tryLookup(() => dylib.lookupFunction<_LuminaServerStartNative, _LuminaServerStartDart>('lumina_server_start'));
      _serverGetPortFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidU16Native, _LuminaVoidU16Dart>('lumina_server_get_port'));

      _playbackResumeFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>('lumina_playback_resume'));
      _playbackGetStateJsonFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_playback_get_state_json'));
      _playbackReconnectDeviceFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>('lumina_playback_reconnect_device'));
      _playbackPlayAsyncFn = tryLookup(() => dylib.lookupFunction<_LuminaPlayAsyncNative, _LuminaPlayAsyncDart>('lumina_playback_play_async'));
      _playbackCancelPendingFn = tryLookup(() => dylib.lookupFunction<_LuminaCancelPendingNative, _LuminaCancelPendingDart>('lumina_playback_cancel_pending'));
      _playbackGetActiveRequestIdFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidU64Native, _LuminaVoidU64Dart>('lumina_playback_get_active_request_id'));
      _playbackDispatchCommandFn = tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_playback_dispatch_command'));
      _protocolSnapshotJsonFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_protocol_snapshot_json'));
      _queueGetStateJsonFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_queue_get_state_json'));
      _lastErrorJsonFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_last_error_json'));
      _artworkGetFn = tryLookup(() => dylib.lookupFunction<_LuminaArtworkGetNative, _LuminaArtworkGetDart>('lumina_artwork_get'));
      _artworkSetUserCoverFn = tryLookup(() => dylib.lookupFunction<_LuminaStrStrIntNative, _LuminaStrStrIntDart>('lumina_artwork_set_user_cover'));
      _artworkClearUserCoverFn = tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_artwork_clear_user_cover'));
      _libraryRescanTagsFn = tryLookup(() => dylib.lookupFunction<_LuminaLibraryRescanTagsNative, _LuminaLibraryRescanTagsDart>('lumina_library_rescan_tags'));
      _lyricsGetFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_lyrics_get'));
      _lyricsSetUserFileFn = tryLookup(() => dylib.lookupFunction<_LuminaStrStrIntNative, _LuminaStrStrIntDart>('lumina_lyrics_set_user_file'));
      _lyricsClearUserFileFn = tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_lyrics_clear_user_file'));

      _visualizerSetEnabledFn = tryLookup(() => dylib.lookupFunction<
          LuminaVisualizerSetEnabledNative,
          LuminaVisualizerSetEnabledDart>('lumina_visualizer_set_enabled'));
      _visualizerIsEnabledFn = tryLookup(() => dylib.lookupFunction<
          LuminaVisualizerIsEnabledNative,
          LuminaVisualizerIsEnabledDart>('lumina_visualizer_is_enabled'));
      _visualizerGetBandsFn = tryLookup(() => dylib.lookupFunction<
          LuminaVisualizerGetBandsNative,
          LuminaVisualizerGetBandsDart>('lumina_visualizer_get_bands'));
      _streamingWarmupH2Fn = tryLookup(() => dylib.lookupFunction<
          _LuminaVoidIntNative,
          _LuminaVoidIntDart>('lumina_streaming_warmup_h2'));
      _streamSetRefreshCbFn = tryLookup(() => dylib.lookupFunction<
          _LuminaStreamSetRefreshCbNative,
          _LuminaStreamSetRefreshCbDart>('lumina_stream_set_refresh_callback'));
      _streamCompleteRefreshFn = tryLookup(() => dylib.lookupFunction<
          _LuminaStreamCompleteRefreshNative,
          _LuminaStreamCompleteRefreshDart>('lumina_stream_complete_refresh'));
      _networkGetEpochFn = tryLookup(() => dylib.lookupFunction<
          _LuminaVoidU64Native,
          _LuminaVoidU64Dart>('lumina_network_get_epoch'));
      _networkSetEpochCbFn = tryLookup(() => dylib.lookupFunction<
          _LuminaNetworkSetEpochCbNative,
          _LuminaNetworkSetEpochCbDart>('lumina_network_set_epoch_callback'));
      _streamingCancelProviderFn = tryLookup(() => dylib.lookupFunction<
          _LuminaStrIntNative,
          _LuminaStrIntDart>('lumina_streaming_cancel_provider'));
      _l1CacheClearProviderFn = tryLookup(() => dylib.lookupFunction<
          _LuminaStrIntNative,
          _LuminaStrIntDart>('lumina_l1_cache_clear_provider'));

      // Phase 4 Dual-Deck & L2 Head Cache optional bindings
      _playbackPrepareStandbyAsyncFn = tryLookup(() => dylib.lookupFunction<
          _LuminaPlayAsyncNative,
          _LuminaPlayAsyncDart>('lumina_playback_prepare_standby_async'));
      _playbackSkipToStandbyFn = tryLookup(() => dylib.lookupFunction<
          _LuminaVoidIntNative,
          _LuminaVoidIntDart>('lumina_playback_skip_to_standby'));
      _playbackSkipToStandbyAtEpochFn = tryLookup(() => dylib.lookupFunction<
          _LuminaSkipToStandbyAtEpochNative,
          _LuminaSkipToStandbyAtEpochDart>('lumina_playback_skip_to_standby_at_epoch'));
      _playbackSeekAtEpochFn = tryLookup(() => dylib.lookupFunction<
          _LuminaSeekAtEpochNative,
          _LuminaSeekAtEpochDart>('lumina_playback_seek_at_epoch'));
      _l2CacheInitFn = tryLookup(() => dylib.lookupFunction<
          _LuminaL2CacheInitNative,
          _LuminaL2CacheInitDart>('lumina_l2_cache_init'));
      _l2CacheTotalBytesFn = tryLookup(() => dylib.lookupFunction<
          _LuminaL2TotalBytesNative,
          _LuminaL2TotalBytesDart>('lumina_l2_cache_total_bytes'));
      _l2CacheEvictNowFn = tryLookup(() => dylib.lookupFunction<
          _LuminaVoidIntNative,
          _LuminaVoidIntDart>('lumina_l2_cache_evict_now'));
      _l2CacheFlushAccessFn = tryLookup(() => dylib.lookupFunction<
          _LuminaVoidIntNative,
          _LuminaVoidIntDart>('lumina_l2_cache_flush_access'));
      _l2CacheRunOrphanSweepFn = tryLookup(() => dylib.lookupFunction<
          _LuminaVoidIntNative,
          _LuminaVoidIntDart>('lumina_l2_cache_run_orphan_sweep'));

      // Layer 1 Ingestion optional bindings (gracefully null on older DLLs)
      _libSetScanProgressCbFn = tryLookup(() => dylib.lookupFunction<
          _LuminaSetScanProgressCbNative,
          _LuminaSetScanProgressCbDart>('lumina_library_set_scan_progress_callback'));
      _libScanStartFn = tryLookup(() => dylib.lookupFunction<
          _LuminaLibraryRescanTagsNative,
          _LuminaLibraryRescanTagsDart>('lumina_library_scan_start'));
      _libRescanStartFn = tryLookup(() => dylib.lookupFunction<
          _LuminaLibraryRescanTagsNative,
          _LuminaLibraryRescanTagsDart>('lumina_library_rescan_start'));
      _libForceRebuildStartFn = tryLookup(() => dylib.lookupFunction<
          _LuminaLibraryRescanTagsNative,
          _LuminaLibraryRescanTagsDart>('lumina_library_force_rebuild_start'));
      _libWatchAddFn = tryLookup(() => dylib.lookupFunction<
          _LuminaWatchAddNative,
          _LuminaWatchAddDart>('lumina_library_watch_add'));
      _libWatchRemoveFn = tryLookup(() => dylib.lookupFunction<
          _LuminaStrIntNative,
          _LuminaStrIntDart>('lumina_library_watch_remove'));
      _libWatchListFn = tryLookup(() => dylib.lookupFunction<
          _LuminaVoidPtrNative,
          _LuminaVoidPtrDart>('lumina_library_watch_list'));
      _libGetSkippedFilesFn = tryLookup(() => dylib.lookupFunction<
          _LuminaIntToPtrNative,
          _LuminaIntToPtrDart>('lumina_library_get_skipped_files'));
      _libDismissSkippedFileFn = tryLookup(() => dylib.lookupFunction<
          _LuminaStrIntNative,
          _LuminaStrIntDart>('lumina_library_dismiss_skipped_file'));
      _libRetrySkippedFileFn = tryLookup(() => dylib.lookupFunction<
          _LuminaStrPtrNative,
          _LuminaStrPtrDart>('lumina_library_retry_skipped_file'));
      _libSetMetadataOverrideFn = tryLookup(() => dylib.lookupFunction<
          _LuminaStr4IntNative,
          _LuminaStr4IntDart>('lumina_library_set_metadata_override'));
      _libClearMetadataOverrideFn = tryLookup(() => dylib.lookupFunction<
          _LuminaStr3IntNative,
          _LuminaStr3IntDart>('lumina_library_clear_metadata_override'));
      _libGetMetadataOverridesFn = tryLookup(() => dylib.lookupFunction<
          _LuminaStr2PtrNative,
          _LuminaStr2PtrDart>('lumina_library_get_metadata_overrides'));
      _libIngestExternalCatalogFn = tryLookup(() => dylib.lookupFunction<
          _LuminaStrPtrNative,
          _LuminaStrPtrDart>('lumina_library_ingest_external_catalog'));
      _providerListFn = tryLookup(() => dylib.lookupFunction<
          _LuminaVoidPtrNative,
          _LuminaVoidPtrDart>('lumina_provider_list'));
      _bindLibraryMaintenanceSymbols(dylib);
      _bindAlbumGroupingSymbols(dylib);
      _bindFocusTagsFoldersSymbols(dylib);
      _bindStep4Symbols(dylib);
      _bindStep5Symbols(dylib);

      final initRc = headless ? _initHeadlessFn!() : _initFn!();
      if (initRc != 0) {
        _dylib = null;
        _dylibPath = null;
        return;
      }

      if (_dylibPath != null) {
        _readWorker = _FfiWorkerClient(
          _dylibPath!,
          lane: FfiWorkerLane.read,
          debugName: 'LuminaFfiReadWorker',
        );
        _writeWorker = _FfiWorkerClient(
          _dylibPath!,
          lane: FfiWorkerLane.write,
          debugName: 'LuminaFfiWriteWorker',
        );
      }

      final dbPath = _resolveFfiDatabasePath(databasePathOverride: databasePath);
      final l2Dir = _l2CacheInitFn != null
          ? _resolveFfiL2CacheRootDir(databasePathOverride: databasePath)
          : null;
      _registerNativeScanProgressCallback();
      _setVolumeFn?.call(_state.volume);

      if (headless || _writeWorker == null) {
        _withNativeUtf8(dbPath, (ptr) => _libInitFn!(ptr));
        if (_l2CacheInitFn != null && l2Dir != null) {
          try {
            _withNativeUtf8(
              l2Dir,
              (ptr) => _l2CacheInitFn!(
                ptr,
                1024 * 1024 * 1024,
                800 * 1024 * 1024,
              ),
            );
          } catch (_) {}
        }
        _reloadTracksFromNative();
        _refreshSignalPath();
        _syncNativeDevicesAndZones();
      } else {
        _refreshSignalPath();
        _syncNativeDevicesAndZones();
        unawaited(_initDatabaseAndTracksAsync(dbPath: dbPath, l2Dir: l2Dir));
        return;
      }
    } catch (_) {
      _dylib = null;
      _dylibPath = null;
      _readWorker?.dispose();
      _readWorker = null;
      _writeWorker?.dispose();
      _writeWorker = null;
    } finally {
      _delegateScanProgressSub ??= _delegate.scanProgressStream.listen((ev) {
        if (!isNativeBound &&
            _remoteClient == null &&
            !_disposed &&
            !_scanProgressController.isClosed) {
          _scanProgressController.add(ev);
        }
      });
      _delegateLibraryReloadedSub ??= _delegate.libraryReloadedStream.listen((_) {
        if (!isNativeBound &&
            _remoteClient == null &&
            !_disposed &&
            !_libraryReloadedController.isClosed) {
          _libraryReloadedController.add(null);
        }
      });
      if ((headless || !isNativeBound || _writeWorker == null) &&
          !_dbReadyCompleter.isCompleted) {
        _dbReadyCompleter.complete();
      }
    }
  }

  Future<void> _initDatabaseAndTracksAsync({
    required String dbPath,
    String? l2Dir,
  }) async {
    try {
      await _callWriteWorker<int>(
        'library_init',
        {'dbPath': dbPath},
        false,
      );
      if (!_disposed && l2Dir != null && _l2CacheInitFn != null) {
        try {
          await _callWriteWorker<int>(
            'l2_cache_init',
            {
              'dir': l2Dir,
              'maxBytes': 1024 * 1024 * 1024,
              'targetBytes': 800 * 1024 * 1024,
            },
            false,
          );
        } catch (_) {}
      }
    } catch (_) {
    } finally {
      if (!_dbReadyCompleter.isCompleted) {
        _dbReadyCompleter.complete();
      }
    }
    if (_disposed) return;
    await _reloadTracksFromNativeAsync();
    if (!_disposed) {
      _emitState(_state);
    }
  }
}
