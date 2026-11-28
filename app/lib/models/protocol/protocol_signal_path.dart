import 'package:flutter/foundation.dart';

import '../signal_path.dart';
import 'json_reader.dart';

/// SignalPath JSON parser/serializer matching Rust `core_types::SignalPath`.
@immutable
class ProtocolSignalPathNode {
  final String stage;
  final String detail;
  final SignalQuality quality;

  const ProtocolSignalPathNode({
    required this.stage,
    required this.detail,
    required this.quality,
  });

  factory ProtocolSignalPathNode.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return ProtocolSignalPathNode(
      stage: r.requiredString('stage', fallback: r.requiredString('title')),
      detail: r.requiredString('detail', fallback: r.requiredString('subtitle')),
      quality: _parseSignalQuality(r.optionalString('quality')),
    );
  }

  factory ProtocolSignalPathNode.fromLegacy(SignalPathNode node) {
    return ProtocolSignalPathNode(
      stage: node.title,
      detail: node.detail.isNotEmpty ? node.detail : node.subtitle,
      quality: node.quality,
    );
  }

  SignalPathNode toLegacy() {
    return SignalPathNode(
      title: stage,
      subtitle: detail,
      detail: detail,
      quality: quality,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'stage': stage,
      'detail': detail,
      'quality': _signalQualityToWire(quality),
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProtocolSignalPathNode &&
          other.stage == stage &&
          other.detail == detail &&
          other.quality == quality);

  @override
  int get hashCode => Object.hash(stage, detail, quality);
}

@immutable
class ProtocolSignalPath {
  final SignalQuality overall;
  final List<ProtocolSignalPathNode> nodes;

  const ProtocolSignalPath({
    required this.overall,
    this.nodes = const <ProtocolSignalPathNode>[],
  });

  factory ProtocolSignalPath.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final rawQuality = r.optionalString('overall') ??
        r.optionalString('overall_quality') ??
        r.optionalString('quality');
    return ProtocolSignalPath(
      overall: _parseSignalQuality(rawQuality),
      nodes: r.mapList('nodes', ProtocolSignalPathNode.fromJson),
    );
  }

  factory ProtocolSignalPath.fromLegacy(SignalPath legacy) {
    return ProtocolSignalPath(
      overall: legacy.overallQuality,
      nodes: List<ProtocolSignalPathNode>.unmodifiable(
        legacy.nodes.map(ProtocolSignalPathNode.fromLegacy),
      ),
    );
  }

  SignalPath toLegacy({bool? dspBypassed}) {
    final inferredBypass = dspBypassed ?? overall == SignalQuality.lossless;
    return SignalPath(
      overallQuality: overall,
      description: overall.description,
      nodes: List<SignalPathNode>.unmodifiable(
        nodes.map((n) => n.toLegacy()),
      ),
      dspBypassed: inferredBypass,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'overall': _signalQualityToWire(overall),
      'nodes': nodes.map((n) => n.toJson()).toList(growable: false),
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProtocolSignalPath &&
          other.overall == overall &&
          listEquals(other.nodes, nodes));

  @override
  int get hashCode => Object.hash(overall, Object.hashAll(nodes));
}

SignalQuality _parseSignalQuality(String? raw) {
  return switch (raw?.trim().toLowerCase()) {
    'lossless' => SignalQuality.lossless,
    'enhanced' => SignalQuality.enhanced,
    _ => SignalQuality.highQuality,
  };
}

String _signalQualityToWire(SignalQuality quality) {
  return switch (quality) {
    SignalQuality.lossless => 'lossless',
    SignalQuality.enhanced => 'enhanced',
    SignalQuality.highQuality => 'high_quality',
  };
}
