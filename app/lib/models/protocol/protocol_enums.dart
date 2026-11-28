import '../playback_state.dart';

/// Canonical repeat mode matching Rust `core_types::RepeatMode`.
enum RepeatMode {
  off('off'),
  all('all'),
  one('one');

  final String wireName;

  const RepeatMode(this.wireName);

  static RepeatMode fromWireName(String? raw) {
    return switch (raw?.trim().toLowerCase()) {
      'all' => RepeatMode.all,
      'one' => RepeatMode.one,
      _ => RepeatMode.off,
    };
  }

  RepeatMode get nextCycle => switch (this) {
        RepeatMode.off => RepeatMode.all,
        RepeatMode.all => RepeatMode.one,
        RepeatMode.one => RepeatMode.off,
      };
}

/// Canonical playback lifecycle state matching Rust `core_types::PlaybackLifecycleState`.
enum PlaybackLifecycleState {
  uninitialized(0, 'uninitialized', 'Uninitialized'),
  stopped(1, 'stopped', 'Stopped'),
  playing(2, 'playing', 'Playing'),
  paused(3, 'paused', 'Paused'),
  error(4, 'error', 'Error'),
  loading(5, 'loading', 'Loading'),
  seeking(6, 'seeking', 'Seeking'),
  buffering(7, 'buffering', 'Buffering'),
  ended(8, 'ended', 'Ended');

  final int code;
  final String wireName;
  final String legacyStateName;

  const PlaybackLifecycleState(this.code, this.wireName, this.legacyStateName);

  static PlaybackLifecycleState fromCode(int code) {
    return switch (code) {
      0 => PlaybackLifecycleState.uninitialized,
      1 => PlaybackLifecycleState.stopped,
      2 => PlaybackLifecycleState.playing,
      3 => PlaybackLifecycleState.paused,
      4 => PlaybackLifecycleState.error,
      5 => PlaybackLifecycleState.loading,
      6 => PlaybackLifecycleState.seeking,
      7 => PlaybackLifecycleState.buffering,
      8 => PlaybackLifecycleState.ended,
      _ => PlaybackLifecycleState.stopped,
    };
  }

  static PlaybackLifecycleState fromWireName(String? raw) {
    return switch (raw?.trim().toLowerCase()) {
      'uninitialized' => PlaybackLifecycleState.uninitialized,
      'stopped' => PlaybackLifecycleState.stopped,
      'playing' => PlaybackLifecycleState.playing,
      'paused' => PlaybackLifecycleState.paused,
      'error' => PlaybackLifecycleState.error,
      'loading' => PlaybackLifecycleState.loading,
      'seeking' => PlaybackLifecycleState.seeking,
      'buffering' => PlaybackLifecycleState.buffering,
      'ended' => PlaybackLifecycleState.ended,
      _ => PlaybackLifecycleState.stopped,
    };
  }

  static PlaybackLifecycleState fromPlaybackStatus(PlaybackStatus status) {
    return fromCode(status.code);
  }

  PlaybackStatus toPlaybackStatus() => PlaybackStatus.fromCode(code);
}
