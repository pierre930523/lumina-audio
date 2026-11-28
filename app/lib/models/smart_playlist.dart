import 'audio_format.dart';
import 'studio/focus_models.dart';
import 'studio/step4_models.dart';

export 'studio/step4_models.dart'
    show SmartPlaylistEvaluation, SmartPlaylistItem;

/// Formats a [SmartPlaylistItem]'s [FocusQuery] predicates, banned-track
/// policy, sort rule, and limit into human-readable rule tags.
List<String> describeSmartPlaylistRules(SmartPlaylistItem item) {
  final query = item.parseFocusQuery();
  final tags = <String>[];
  if (query != null) {
    for (final p in query.predicates) {
      final prefix = p.mode == FocusPredicateMode.exclude ? '排除 ' : '';
      final valLabel = _formatValue(p.facet, p.value);
      tags.add('$prefix${p.facet.displayLabel}: $valLabel');
    }
    if (query.sort != null) {
      final dir = query.sort!.direction == FocusSortDirection.desc ? '↓' : '↑';
      tags.add('排序: ${query.sort!.field.displayLabel} $dir');
    }
  }
  if (tags.isEmpty) {
    tags.add('全部曲庫曲目');
  }
  if (item.excludeBanned) {
    tags.add('自動略過已封鎖');
  }
  if (item.limitCount != null && item.limitCount! > 0) {
    tags.add('上限 ${item.limitCount} 首');
  }
  return tags;
}

String _formatValue(FocusFacet facet, FocusValue value) {
  return switch (value) {
    FocusStringValue(:final value) => switch (facet) {
      FocusFacet.preference => FocusFacetBucket.preferenceBucketLabel(value),
      FocusFacet.format => value.toUpperCase(),
      FocusFacet.playStatus =>
        value == 'played' ? '已聽' : (value == 'unplayed' ? '未聽' : value),
      _ => value,
    },
    FocusIntValue(:final value) => switch (facet) {
      FocusFacet.sampleRate => AudioFormat.formatSampleRateKhz(value),
      FocusFacet.bitDepth => '$value-bit',
      FocusFacet.channels => '${value}ch',
      _ => value.toString(),
    },
    FocusIntRangeValue(:final min, :final max) => switch ((min, max)) {
      (final lo?, final hi?) =>
        facet == FocusFacet.sampleRate
            ? '${AudioFormat.formatSampleRateKhz(lo)}–${AudioFormat.formatSampleRateKhz(hi)}'
            : '$lo–$hi',
      (final lo?, null) =>
        facet == FocusFacet.sampleRate
            ? '≥ ${AudioFormat.formatSampleRateKhz(lo)}'
            : '≥ $lo',
      (null, final hi?) =>
        facet == FocusFacet.sampleRate
            ? '≤ ${AudioFormat.formatSampleRateKhz(hi)}'
            : '≤ $hi',
      _ => '不限',
    },
    FocusDateRangeValue(:final from, :final to) =>
      from != null && to != null
          ? '$from ~ $to'
          : (from != null ? '$from 起' : (to != null ? '至 $to' : '不限')),
  };
}
