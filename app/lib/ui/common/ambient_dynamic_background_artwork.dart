part of 'ambient_dynamic_background.dart';

extension _AmbientArtworkLoader on _AmbientDynamicBackgroundState {
  static bool _isLikelyLocalFilePath(String raw) {
    return !raw.startsWith('/api/') &&
        !raw.startsWith('http://') &&
        !raw.startsWith('https://') &&
        !raw.startsWith('//');
  }

  bool _tryHydrateCachedCoverSync(TrackInfo? track) {
    final candidates = <String>[];
    final extPath = widget.externalArtworkCachePath?.trim();
    if (extPath != null && extPath.isNotEmpty) {
      candidates.add('file:$extPath');
    }
    final extUrl = widget.externalArtworkUrl?.trim();
    if (extUrl != null && extUrl.isNotEmpty) {
      final normalized = BaseStreamingProvider.normalizeCoverUrl(extUrl);
      if (normalized != null) {
        candidates.add('url:$normalized');
      } else if (_isLikelyLocalFilePath(extUrl)) {
        candidates.add('file:$extUrl');
      }
    }
    if (track != null) {
      final cache = widget.libraryCache;
      if (cache != null) {
        if (track.id.isNotEmpty) {
          final p = cache.getArtworkPathSync(track.id)?.trim();
          if (p != null && p.isNotEmpty) candidates.add('file:$p');
        }
        final canonicalAlbumId = cache.resolveAlbumIdForTrack(track);
        if (canonicalAlbumId != null && canonicalAlbumId.isNotEmpty) {
          final p = cache.getArtworkPathSync(canonicalAlbumId)?.trim();
          if (p != null && p.isNotEmpty) candidates.add('file:$p');
        }
      }
      final trackArtUrl = track.artworkUrl?.trim();
      if (trackArtUrl != null && trackArtUrl.isNotEmpty) {
        final normalized = BaseStreamingProvider.normalizeCoverUrl(trackArtUrl);
        if (normalized != null) {
          candidates.add('url:$normalized');
        } else if (_isLikelyLocalFilePath(trackArtUrl)) {
          candidates.add('file:$trackArtUrl');
        }
      }
    }

    for (final key in candidates) {
      final cached = _AmbientDecodedCoverCache.getClone(key);
      if (cached != null) {
        _currArtworkSourceKey = key;
        _coverFadeController.value = 1.0;
        _coverModel.setImmediate(cached);
        return true;
      }
    }
    return false;
  }

  bool _tryApplyFromCache(String sourceKey) {
    final cached = _AmbientDecodedCoverCache.getClone(sourceKey);
    if (cached == null) return false;
    _applyDecodedCover(cached, sourceKey, alreadyCached: true);
    return true;
  }

  void _cancelActiveImageStream() {
    final stream = _activeImageStream;
    final listener = _activeImageListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _activeImageStream = null;
    _activeImageListener = null;
    final completer = _activeImageCompleter;
    _activeImageCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }
  }

  Future<void> _resolveAndLoadArtwork(TrackInfo? track) async {
    final seq = ++_artworkRequestSeq;
    _cancelActiveImageStream();

    // 1. Explicit external local cache path.
    final extPath = widget.externalArtworkCachePath?.trim();
    if (extPath != null && extPath.isNotEmpty) {
      final sourceKey = 'file:$extPath';
      if (sourceKey == _currArtworkSourceKey && _coverModel.currImage != null) {
        return;
      }
      if (_tryApplyFromCache(sourceKey)) return;
      final img = await _decodeFileImage(extPath);
      if (!mounted || seq != _artworkRequestSeq) {
        img?.dispose();
        return;
      }
      if (img != null) {
        _applyDecodedCover(img, sourceKey);
        return;
      }
    }

    // 2. Explicit external URL or file path.
    final extUrl = widget.externalArtworkUrl?.trim();
    if (extUrl != null && extUrl.isNotEmpty) {
      final normalizedUrl = BaseStreamingProvider.normalizeCoverUrl(extUrl);
      if (normalizedUrl != null) {
        final sourceKey = 'url:$normalizedUrl';
        if (sourceKey == _currArtworkSourceKey &&
            _coverModel.currImage != null) {
          return;
        }
        if (_tryApplyFromCache(sourceKey)) return;
        final img = await _resolveNetworkImage(normalizedUrl, seq);
        if (!mounted || seq != _artworkRequestSeq) {
          img?.dispose();
          return;
        }
        if (img != null) {
          _applyDecodedCover(img, sourceKey);
          return;
        }
      } else if (_isLikelyLocalFilePath(extUrl)) {
        final sourceKey = 'file:$extUrl';
        if (sourceKey == _currArtworkSourceKey &&
            _coverModel.currImage != null) {
          return;
        }
        if (_tryApplyFromCache(sourceKey)) return;
        final img = await _decodeFileImage(extUrl);
        if (!mounted || seq != _artworkRequestSeq) {
          img?.dispose();
          return;
        }
        if (img != null) {
          _applyDecodedCover(img, sourceKey);
          return;
        }
      }
    }

    if (track == null) {
      _clearCoverIfPresent();
      return;
    }

    // 3. Synchronous LibraryIndexCache lookup.
    final cache = widget.libraryCache;
    if (cache != null) {
      final canonicalAlbumId = cache.resolveAlbumIdForTrack(track);
      final syncCandidates = <String?>[
        if (track.id.isNotEmpty) cache.getArtworkPathSync(track.id),
        if (canonicalAlbumId != null && canonicalAlbumId.isNotEmpty)
          cache.getArtworkPathSync(canonicalAlbumId),
      ];
      for (final candidate in syncCandidates) {
        final p = candidate?.trim();
        if (p != null && p.isNotEmpty) {
          final sourceKey = 'file:$p';
          if (sourceKey == _currArtworkSourceKey &&
              _coverModel.currImage != null) {
            return;
          }
          if (_tryApplyFromCache(sourceKey)) return;
          final img = await _decodeFileImage(p);
          if (!mounted || seq != _artworkRequestSeq) {
            img?.dispose();
            return;
          }
          if (img != null) {
            _applyDecodedCover(img, sourceKey);
            return;
          }
        }
      }
    }

    // 4. Track artworkUrl (network URL via ImageStream or local file path).
    final trackArtUrl = track.artworkUrl?.trim();
    if (trackArtUrl != null && trackArtUrl.isNotEmpty) {
      final normalizedUrl = BaseStreamingProvider.normalizeCoverUrl(
        trackArtUrl,
      );
      if (normalizedUrl != null) {
        final sourceKey = 'url:$normalizedUrl';
        if (sourceKey == _currArtworkSourceKey &&
            _coverModel.currImage != null) {
          return;
        }
        if (_tryApplyFromCache(sourceKey)) return;
        final img = await _resolveNetworkImage(normalizedUrl, seq);
        if (!mounted || seq != _artworkRequestSeq) {
          img?.dispose();
          return;
        }
        if (img != null) {
          _applyDecodedCover(img, sourceKey);
          return;
        }
      } else if (_isLikelyLocalFilePath(trackArtUrl)) {
        final sourceKey = 'file:$trackArtUrl';
        if (sourceKey == _currArtworkSourceKey &&
            _coverModel.currImage != null) {
          return;
        }
        if (_tryApplyFromCache(sourceKey)) return;
        final img = await _decodeFileImage(trackArtUrl);
        if (!mounted || seq != _artworkRequestSeq) {
          img?.dispose();
          return;
        }
        if (img != null) {
          _applyDecodedCover(img, sourceKey);
          return;
        }
      }
    }

    // 5. Async resolution via LibraryIndexCache or AudioService.getArtwork.
    String? fetchedPath;
    if (cache != null) {
      final canonicalAlbumId = cache.resolveAlbumIdForTrack(track);
      if (canonicalAlbumId != null &&
          canonicalAlbumId.isNotEmpty &&
          !cache.hasArtworkCached(canonicalAlbumId)) {
        try {
          fetchedPath = await cache.resolveArtworkPath(
            widget.audioService,
            canonicalAlbumId,
            maxDim: 0,
          );
        } catch (_) {}
      }
      if (!mounted || seq != _artworkRequestSeq) return;
      if ((fetchedPath == null || fetchedPath.isEmpty) &&
          track.id.isNotEmpty &&
          !cache.hasArtworkCached(track.id)) {
        try {
          fetchedPath = await cache.resolveArtworkPath(
            widget.audioService,
            track.id,
            path: track.filePath,
            maxDim: 0,
          );
        } catch (_) {}
      }
    } else if (track.id.isNotEmpty) {
      try {
        final res = await widget.audioService.getArtwork(
          track.id,
          path: track.filePath,
          maxDim: 0,
        );
        if (res != null && res['found'] == true) {
          final candidate = res['cache_path']?.toString().trim();
          if (candidate != null && candidate.isNotEmpty) {
            fetchedPath = candidate;
          }
        }
      } catch (_) {}
    }

    if (!mounted || seq != _artworkRequestSeq) return;
    if (fetchedPath != null && fetchedPath.isNotEmpty) {
      final sourceKey = 'file:$fetchedPath';
      if (sourceKey == _currArtworkSourceKey && _coverModel.currImage != null) {
        return;
      }
      if (_tryApplyFromCache(sourceKey)) return;
      final img = await _decodeFileImage(fetchedPath);
      if (!mounted || seq != _artworkRequestSeq) {
        img?.dispose();
        return;
      }
      if (img != null) {
        _applyDecodedCover(img, sourceKey);
        return;
      }
    }

    _clearCoverIfPresent();
  }

  static const int _coverBakedBlurMaxDim = 64;

  /// Pre-blurs [raw] once onto an offscreen <=64px texture so
  /// [_AmbientCoverPainter] paints smooth ambient haze via GPU bilinear
  /// upscaling without per-frame full-screen ImageFilter.blur passes.
  ui.Image _bakeBlurredLowResCover(ui.Image raw) {
    final srcW = raw.width.toDouble();
    final srcH = raw.height.toDouble();
    if (srcW <= 0 || srcH <= 0) return raw;
    final maxSide = math.max(srcW, srcH);
    final scale = _coverBakedBlurMaxDim / maxSide;
    final dstW = math.max(1, (srcW * scale).round());
    final dstH = math.max(1, (srcH * scale).round());
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final srcRect = Rect.fromLTWH(0.0, 0.0, srcW, srcH);
      final dstRect = Rect.fromLTWH(0.0, 0.0, dstW * 1.0, dstH * 1.0);
      canvas.clipRect(dstRect);
      canvas.drawImageRect(
        raw,
        srcRect,
        dstRect,
        Paint()..filterQuality = FilterQuality.low,
      );
      canvas.drawImageRect(
        raw,
        srcRect,
        dstRect,
        Paint()
          ..blendMode = BlendMode.src
          ..filterQuality = FilterQuality.medium
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: 9.0,
            sigmaY: 9.0,
            tileMode: ui.TileMode.mirror,
          ),
      );
      final picture = recorder.endRecording();
      try {
        final baked = picture.toImageSync(dstW, dstH);
        raw.dispose();
        return baked;
      } finally {
        picture.dispose();
      }
    } catch (_) {
      return raw;
    }
  }

  Future<ui.Image?> _decodeFileImage(String filePath) async {
    ui.Codec? codec;
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _AmbientDynamicBackgroundState._coverDecodeTargetWidth,
      );
      final frame = await codec.getNextFrame();
      return _bakeBlurredLowResCover(frame.image);
    } catch (_) {
      return null;
    } finally {
      codec?.dispose();
    }
  }

  Future<ui.Image?> _resolveNetworkImage(String url, int seq) async {
    if (!mounted || seq != _artworkRequestSeq) return null;
    try {
      final provider = ResizeImage(
        NetworkImage(
          url,
          headers: BaseStreamingProvider.defaultImageHttpHeaders,
        ),
        width: _AmbientDynamicBackgroundState._coverDecodeTargetWidth,
      );
      final stream = provider.resolve(
        const ImageConfiguration(
          size: Size(
            _AmbientDynamicBackgroundState._coverDecodeTargetWidth * 1.0,
            _AmbientDynamicBackgroundState._coverDecodeTargetWidth * 1.0,
          ),
        ),
      );
      final completer = Completer<ui.Image?>();
      late final ImageStreamListener listener;

      void finish(ui.Image? image) {
        if (identical(_activeImageStream, stream)) {
          _activeImageStream = null;
          _activeImageListener = null;
          _activeImageCompleter = null;
        }
        stream.removeListener(listener);
        if (!completer.isCompleted) {
          completer.complete(image);
        } else {
          image?.dispose();
        }
      }

      listener = ImageStreamListener(
        (ImageInfo info, bool synchronousCall) {
          ui.Image? cloned;
          try {
            cloned = info.image.clone();
          } catch (_) {
            cloned = null;
          } finally {
            info.dispose();
          }
          finish(cloned != null ? _bakeBlurredLowResCover(cloned) : null);
        },
        onError: (Object error, StackTrace? stackTrace) {
          // Safely ignore network errors (including mock HTTP 400 in FLUTTER_TEST).
          finish(null);
        },
      );

      _activeImageStream = stream;
      _activeImageListener = listener;
      _activeImageCompleter = completer;
      stream.addListener(listener);
      return await completer.future;
    } catch (_) {
      return null;
    }
  }

  void _applyDecodedCover(
    ui.Image nextImage,
    String sourceKey, {
    bool alreadyCached = false,
  }) {
    if (!mounted) {
      nextImage.dispose();
      return;
    }
    if (!alreadyCached) {
      _AmbientDecodedCoverCache.put(sourceKey, nextImage);
    }
    _currArtworkSourceKey = sourceKey;
    if (!widget.enabled || _coverModel.currImage == null) {
      _coverFadeController.stop();
      _coverFadeController.value = 1.0;
      _coverModel.setImmediate(nextImage);
      return;
    }
    _coverModel.beginTransition(nextImage);
    _coverFadeController.forward(from: 0.0);
  }

  void _clearCoverIfPresent() {
    _currArtworkSourceKey = null;
    if (_coverModel.currImage == null && _coverModel.prevImage == null) {
      return;
    }
    if (!widget.enabled) {
      _coverFadeController.stop();
      _coverFadeController.value = 1.0;
      _coverModel.setImmediate(null);
      return;
    }
    if (_coverModel.currImage != null) {
      _coverModel.beginTransition(null);
      _coverFadeController.forward(from: 0.0);
    }
  }
}
