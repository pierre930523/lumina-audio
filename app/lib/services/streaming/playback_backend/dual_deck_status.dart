import 'package:flutter/foundation.dart';

import '../../../models/stream_source_spec.dart';

/// Per-deck lifecycle state matching Rust `core_types::DeckState`.
enum DeckState {
  idle,
  resolving,
  prebuffering,
  standbyReady,
  playing,
  seeking,
  recovering403,
  draining;

  String get wireValue => switch (this) {
    DeckState.idle => 'IDLE',
    DeckState.resolving => 'RESOLVING',
    DeckState.prebuffering => 'PREBUFFERING',
    DeckState.standbyReady => 'STANDBY_READY',
    DeckState.playing => 'PLAYING',
    DeckState.seeking => 'SEEKING',
    DeckState.recovering403 => 'RECOVERING_403',
    DeckState.draining => 'DRAINING',
  };
}

/// Parses wire strings (e.g. `"STANDBY_READY"`, `"standbyReady"`, `"0"`..`"7"`)
/// into [DeckState], falling back to [DeckState.idle].
DeckState parseDeckState(String? raw) {
  if (raw == null) return DeckState.idle;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return DeckState.idle;
  final numeric = int.tryParse(trimmed);
  if (numeric != null && numeric >= 0 && numeric < DeckState.values.length) {
    return DeckState.values[numeric];
  }
  final normalized = trimmed.toLowerCase().replaceAll('_', '').replaceAll('-', '');
  return switch (normalized) {
    'idle' => DeckState.idle,
    'resolving' => DeckState.resolving,
    'prebuffering' => DeckState.prebuffering,
    'standbyready' => DeckState.standbyReady,
    'playing' => DeckState.playing,
    'seeking' => DeckState.seeking,
    'recovering403' => DeckState.recovering403,
    'draining' => DeckState.draining,
    _ => DeckState.idle,
  };
}

/// Dual-Deck snapshot parsed from Rust `lumina_playback_get_state_json()`.
@immutable
class DualDeckStatus {
  final String activeDeck;
  final DeckState deckAState;
  final DeckState deckBState;
  final int standbyBufferedMs;
  final int gaplessTransitions;
  final int manualZeroLatencySwitches;
  final int formatMismatchRecoveries;
  final StreamKey? deckAKey;
  final StreamKey? deckBKey;
  final int swapGeneration;
  final Map<String, dynamic>? activeTrackJson;

  const DualDeckStatus({
    this.activeDeck = 'deck_a',
    this.deckAState = DeckState.idle,
    this.deckBState = DeckState.idle,
    this.standbyBufferedMs = 0,
    this.gaplessTransitions = 0,
    this.manualZeroLatencySwitches = 0,
    this.formatMismatchRecoveries = 0,
    this.deckAKey,
    this.deckBKey,
    this.swapGeneration = 0,
    this.activeTrackJson,
  });

  static bool _isDeckB(String deck) {
    final normalized = deck.trim().toLowerCase();
    return normalized == 'deck_b' || normalized == 'b' || normalized == '1';
  }

  static String _parseActiveDeck(dynamic raw) {
    if (raw is num) {
      return raw.toInt() == 1 ? 'deck_b' : 'deck_a';
    }
    final str = raw?.toString().trim().toLowerCase() ?? '';
    return _isDeckB(str) ? 'deck_b' : 'deck_a';
  }

  static DeckState _parseStateField(dynamic raw) {
    if (raw is num) {
      final idx = raw.toInt();
      if (idx >= 0 && idx < DeckState.values.length) {
        return DeckState.values[idx];
      }
      return DeckState.idle;
    }
    return parseDeckState(raw?.toString());
  }

  static StreamKey? _parseStreamKey(dynamic raw) {
    if (raw is Map) {
      return StreamKey.fromJson(Map<String, dynamic>.from(raw));
    }
    return null;
  }

  static Map<String, dynamic>? _parseTrackMap(dynamic raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return null;
  }

  static int _mapHash(Map<String, dynamic>? map) {
    if (map == null) return 0;
    return Object.hashAllUnordered(
      map.entries.map((e) => Object.hash(e.key, e.value)),
    );
  }

  factory DualDeckStatus.fromJson(Map<String, dynamic> json) {
    final nested = json['dual_deck'];
    final source = nested is Map
        ? Map<String, dynamic>.from(nested)
        : json;
    return DualDeckStatus(
      activeDeck: _parseActiveDeck(source['active_deck']),
      deckAState: _parseStateField(source['deck_a_state']),
      deckBState: _parseStateField(source['deck_b_state']),
      standbyBufferedMs: (source['standby_buffered_ms'] as num?)?.toInt() ?? 0,
      gaplessTransitions:
          (source['gapless_transitions'] as num?)?.toInt() ?? 0,
      manualZeroLatencySwitches:
          (source['manual_zero_latency_switches'] as num?)?.toInt() ?? 0,
      formatMismatchRecoveries:
          (source['format_mismatch_recoveries'] as num?)?.toInt() ?? 0,
      deckAKey: _parseStreamKey(source['deck_a_key']),
      deckBKey: _parseStreamKey(source['deck_b_key']),
      swapGeneration:
          (source['swap_generation'] as num?)?.toInt() ??
          (source['swapGeneration'] as num?)?.toInt() ??
          (json['swap_generation'] as num?)?.toInt() ??
          (json['swapGeneration'] as num?)?.toInt() ??
          0,
      activeTrackJson: _parseTrackMap(
        source['active_track'] ??
            source['current_track'] ??
            json['active_track'] ??
            json['current_track'],
      ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'active_deck': activeDeck,
    'deck_a_state': deckAState.wireValue,
    'deck_b_state': deckBState.wireValue,
    'standby_buffered_ms': standbyBufferedMs,
    'gapless_transitions': gaplessTransitions,
    'manual_zero_latency_switches': manualZeroLatencySwitches,
    'format_mismatch_recoveries': formatMismatchRecoveries,
    if (deckAKey != null) 'deck_a_key': deckAKey!.toJson(),
    if (deckBKey != null) 'deck_b_key': deckBKey!.toJson(),
    'swap_generation': swapGeneration,
    if (activeTrackJson != null) 'active_track': activeTrackJson,
  };

  DeckState get activeDeckState =>
      _isDeckB(activeDeck) ? deckBState : deckAState;

  DeckState get standbyDeckState =>
      _isDeckB(activeDeck) ? deckAState : deckBState;

  bool get isStandbyReady => standbyDeckState == DeckState.standbyReady;

  DualDeckStatus copyWith({
    String? activeDeck,
    DeckState? deckAState,
    DeckState? deckBState,
    int? standbyBufferedMs,
    int? gaplessTransitions,
    int? manualZeroLatencySwitches,
    int? formatMismatchRecoveries,
    StreamKey? deckAKey,
    StreamKey? deckBKey,
    int? swapGeneration,
    Map<String, dynamic>? activeTrackJson,
    bool clearActiveTrackJson = false,
  }) {
    return DualDeckStatus(
      activeDeck: activeDeck ?? this.activeDeck,
      deckAState: deckAState ?? this.deckAState,
      deckBState: deckBState ?? this.deckBState,
      standbyBufferedMs: standbyBufferedMs ?? this.standbyBufferedMs,
      gaplessTransitions: gaplessTransitions ?? this.gaplessTransitions,
      manualZeroLatencySwitches:
          manualZeroLatencySwitches ?? this.manualZeroLatencySwitches,
      formatMismatchRecoveries:
          formatMismatchRecoveries ?? this.formatMismatchRecoveries,
      deckAKey: deckAKey ?? this.deckAKey,
      deckBKey: deckBKey ?? this.deckBKey,
      swapGeneration: swapGeneration ?? this.swapGeneration,
      activeTrackJson: clearActiveTrackJson
          ? null
          : (activeTrackJson ?? this.activeTrackJson),
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is DualDeckStatus &&
            other.activeDeck == activeDeck &&
            other.deckAState == deckAState &&
            other.deckBState == deckBState &&
            other.standbyBufferedMs == standbyBufferedMs &&
            other.gaplessTransitions == gaplessTransitions &&
            other.manualZeroLatencySwitches == manualZeroLatencySwitches &&
            other.formatMismatchRecoveries == formatMismatchRecoveries &&
            other.deckAKey == deckAKey &&
            other.deckBKey == deckBKey &&
            other.swapGeneration == swapGeneration &&
            mapEquals(other.activeTrackJson, activeTrackJson));
  }

  @override
  int get hashCode => Object.hash(
    activeDeck,
    deckAState,
    deckBState,
    standbyBufferedMs,
    gaplessTransitions,
    manualZeroLatencySwitches,
    formatMismatchRecoveries,
    deckAKey,
    deckBKey,
    swapGeneration,
    _mapHash(activeTrackJson),
  );

  @override
  String toString() =>
      'DualDeckStatus(active=$activeDeck, a=${deckAState.wireValue}, b=${deckBState.wireValue}, standbyMs=$standbyBufferedMs, swapGen=$swapGeneration)';
}
