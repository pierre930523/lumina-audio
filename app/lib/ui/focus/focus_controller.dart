import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../models/audio_format.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';

/// Reactive controller managing Focus filter predicates, sorting, pagination,
/// 150ms debounced backend queries, and monotonic stale-response cancellation.
class FocusController extends ChangeNotifier {
  final AudioService audioService;
  final Duration debounceDuration;
  final int pageSize;

  FocusQuery _query;
  FocusQueryResponse? _response;
  FocusFacetsResponse? _facets;
  final Map<String, String> _tagNames = <String, String>{};
  bool _isLoading = false;
  bool _drawerOpen = false;
  String? _error;
  int _offset = 0;
  int _requestSeq = 0;
  Timer? _debounceTimer;
  bool _disposed = false;

  FocusController({
    required this.audioService,
    required FocusEntity entity,
    FocusQuery? initialQuery,
    bool includeHidden = false,
    this.debounceDuration = const Duration(milliseconds: 150),
    this.pageSize = 100,
  }) : _query = (initialQuery ?? FocusQuery(entity: entity)).copyWith(
         entity: entity,
         includeHidden: initialQuery?.includeHidden ?? includeHidden,
       );

  FocusQuery get query => _query;
  FocusQueryResponse? get response => _response;
  FocusFacetsResponse? get facets => _facets;
  bool get isLoading => _isLoading;
  bool get drawerOpen => _drawerOpen;
  String? get error => _error;
  int get offset => _offset;
  int get activePredicateCount => _query.predicates.length;
  bool get hasPredicates => _query.predicates.isNotEmpty;
  bool get isActive => _query.predicates.isNotEmpty || _query.sort != null;
  int get totalCount => _response?.totalCount ?? 0;
  bool get hasPrevPage => _offset > 0;
  bool get hasNextPage => _offset + pageSize < totalCount;

  /// Loads initial data if an initial query was supplied or facets are needed.
  void initialize() {
    if (isActive || _drawerOpen) {
      unawaited(refresh(immediate: true));
    }
  }

  void toggleDrawer([bool? open]) {
    final next = open ?? !_drawerOpen;
    if (_drawerOpen == next) return;
    _drawerOpen = next;
    notifyListeners();
    if (_drawerOpen && _facets == null) {
      unawaited(refresh(immediate: true));
    }
  }

  void applyInitialQuery(FocusQuery next, {bool immediate = true}) {
    final normalized = next.copyWith(entity: _query.entity);
    if (_query == normalized && _response != null) return;
    _query = normalized;
    _offset = 0;
    notifyListeners();
    if (immediate) {
      unawaited(refresh(immediate: true));
    } else {
      _scheduleRefresh();
    }
  }

  void setIncludeHidden(bool includeHidden) {
    if (_query.includeHidden == includeHidden) return;
    _query = _query.copyWith(includeHidden: includeHidden);
    _offset = 0;
    notifyListeners();
    if (isActive || _drawerOpen) {
      _scheduleRefresh();
    }
  }

  void addOrTogglePredicate(FocusPredicate predicate) {
    final next = List<FocusPredicate>.from(_query.predicates);
    final idx = next.indexWhere(
      (p) => p.facet == predicate.facet && p.value == predicate.value,
    );
    if (idx >= 0) {
      if (next[idx].mode == predicate.mode) {
        next.removeAt(idx);
      } else {
        next[idx] = predicate;
      }
    } else {
      next.add(predicate);
    }
    _query = _query.copyWith(predicates: next);
    _offset = 0;
    notifyListeners();
    _scheduleRefresh();
  }

  void setFacetSinglePredicate(
    FocusFacet facet,
    FocusValue? value, {
    FocusPredicateMode mode = FocusPredicateMode.include,
  }) {
    final next = _query.predicates
        .where((p) => p.facet != facet)
        .toList(growable: true);
    if (value != null) {
      next.add(FocusPredicate(facet: facet, value: value, mode: mode));
    }
    _query = _query.copyWith(predicates: next);
    _offset = 0;
    notifyListeners();
    _scheduleRefresh();
  }

  void togglePredicateMode(int index) {
    if (index < 0 || index >= _query.predicates.length) return;
    final next = List<FocusPredicate>.from(_query.predicates);
    next[index] = next[index].toggledMode();
    _query = _query.copyWith(predicates: next);
    _offset = 0;
    notifyListeners();
    _scheduleRefresh();
  }

  void removePredicate(int index) {
    if (index < 0 || index >= _query.predicates.length) return;
    final next = List<FocusPredicate>.from(_query.predicates)..removeAt(index);
    _query = _query.copyWith(predicates: next);
    _offset = 0;
    notifyListeners();
    _scheduleRefresh();
  }

  void clearAllPredicates() {
    if (_query.predicates.isEmpty) return;
    _query = _query.copyWith(predicates: const <FocusPredicate>[]);
    _offset = 0;
    notifyListeners();
    if (isActive || _drawerOpen) {
      _scheduleRefresh();
    } else {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      _response = null;
      _error = null;
      notifyListeners();
    }
  }

  void setSort(FocusSort? sort) {
    FocusSort? resolved = sort;
    if (resolved != null &&
        resolved.field == FocusSortField.random &&
        resolved.seed == null) {
      resolved = resolved.copyWith(
        seed: math.Random().nextInt(1 << 30) + 1,
      );
    }
    _query = resolved == null
        ? _query.copyWith(clearSort: true)
        : _query.copyWith(sort: resolved);
    _offset = 0;
    notifyListeners();
    if (isActive || _drawerOpen) {
      _scheduleRefresh();
    } else {
      _response = null;
      notifyListeners();
    }
  }

  void toggleSortDirection() {
    final cur = _query.sort;
    if (cur == null || cur.field == FocusSortField.random) return;
    final nextDir = cur.direction == FocusSortDirection.asc
        ? FocusSortDirection.desc
        : FocusSortDirection.asc;
    setSort(cur.copyWith(direction: nextDir));
  }

  void reshuffleRandom() {
    setSort(
      FocusSort(
        field: FocusSortField.random,
        direction: FocusSortDirection.asc,
        seed: math.Random().nextInt(1 << 30) + 1,
      ),
    );
  }

  void loadPage(int nextOffset) {
    final clamped = nextOffset < 0 ? 0 : nextOffset;
    if (clamped == _offset) return;
    _offset = clamped;
    notifyListeners();
    unawaited(refresh(immediate: true));
  }

  FocusPredicateMode? activeModeFor(FocusFacet facet, FocusValue value) {
    for (final p in _query.predicates) {
      if (p.facet == facet && p.value == value) {
        return p.mode;
      }
    }
    return null;
  }

  String labelForPredicate(FocusPredicate predicate) {
    final valLabel = _formatPredicateValue(predicate.facet, predicate.value);
    return '${predicate.facet.displayLabel}: $valLabel';
  }

  String _formatPredicateValue(FocusFacet facet, FocusValue val) {
    return switch (val) {
      FocusStringValue(:final value) => _formatStringBucket(facet, value),
      FocusIntValue(:final value) => switch (facet) {
        FocusFacet.sampleRate => AudioFormat.formatSampleRateKhz(value),
        FocusFacet.bitDepth => '$value-bit',
        FocusFacet.channels => value == 2 ? '立體聲 (2ch)' : '${value}ch',
        _ => value.toString(),
      },
      FocusIntRangeValue(:final min, :final max) =>
        min != null && max != null
            ? '$min–$max'
            : (min != null ? '≥ $min' : (max != null ? '≤ $max' : '不限')),
      FocusDateRangeValue(:final from, :final to) =>
        from != null && to != null
            ? '$from ~ $to'
            : (from != null ? '$from 起' : (to != null ? '至 $to' : '不限')),
    };
  }

  String _formatStringBucket(FocusFacet facet, String raw) {
    if (facet == FocusFacet.tag) {
      return _tagNames[raw] ?? raw;
    }
    if (facet == FocusFacet.format) {
      return raw.toUpperCase();
    }
    if (facet == FocusFacet.preference) {
      return FocusFacetBucket.preferenceBucketLabel(raw);
    }
    if (facet == FocusFacet.playStatus) {
      return switch (raw.toLowerCase()) {
        'played' => '已聽',
        'unplayed' => '未聽',
        _ => raw,
      };
    }
    if (facet == FocusFacet.inspector) {
      return switch (raw.toLowerCase()) {
        'has_duplicates' || 'multi_version' => '多版本重複',
        'missing_cover' || 'no_cover' => '缺封面',
        'has_cover' => '有封面',
        'has_manual_edits' || 'edited' => '含手動編輯',
        'hidden' => '已隱藏',
        'has_lyrics' => '有歌詞',
        'no_lyrics' => '缺歌詞',
        _ => raw,
      };
    }
    if (facet == FocusFacet.sampleRate) {
      final hz = int.tryParse(raw);
      if (hz != null && hz > 0) return AudioFormat.formatSampleRateKhz(hz);
    }
    if (facet == FocusFacet.bitDepth) {
      final bd = int.tryParse(raw);
      if (bd != null && bd > 0) return '$bd-bit';
    }
    return raw;
  }

  void _scheduleRefresh() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounceDuration, () {
      _debounceTimer = null;
      if (!_disposed) {
        unawaited(refresh(immediate: true));
      }
    });
  }

  Future<void> refresh({bool immediate = false}) async {
    if (_disposed) return;
    if (!immediate) {
      _scheduleRefresh();
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = null;

    final seq = ++_requestSeq;
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final queryFuture = audioService.focusQuery(
        FocusQueryRequest(query: _query, limit: pageSize, offset: _offset),
      );
      final facetsFuture = audioService.focusFacets(_query);
      final results = await Future.wait<Object>([queryFuture, facetsFuture]);
      if (_disposed || seq != _requestSeq) return;

      final qResp = results[0] as FocusQueryResponse;
      final fResp = results[1] as FocusFacetsResponse;
      for (final b in fResp.bucketsFor(FocusFacet.tag)) {
        _tagNames[b.value] = b.label;
      }
      _response = qResp;
      _facets = fResp;
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      if (_disposed || seq != _requestSeq) return;
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    super.dispose();
  }
}
