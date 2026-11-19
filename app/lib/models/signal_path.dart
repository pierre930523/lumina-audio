enum SignalQuality {
  lossless,
  enhanced,
  highQuality;

  String get label => switch (this) {
    SignalQuality.lossless => '無損音質',
    SignalQuality.enhanced => '音質強化',
    SignalQuality.highQuality => '標準高音質',
  };

  String get description => switch (this) {
    SignalQuality.lossless => '位元精準無損音訊串流',
    SignalQuality.enhanced => '已啟用 64 位元浮點 DSP 處理',
    SignalQuality.highQuality => '經由系統混音或有損轉換輸出',
  };
}

class SignalPathNode {
  final String title;
  final String subtitle;
  final String detail;
  final SignalQuality quality;

  const SignalPathNode({
    required this.title,
    required this.subtitle,
    required this.detail,
    required this.quality,
  });
}

class SignalPath {
  final SignalQuality overallQuality;
  final String description;
  final List<SignalPathNode> nodes;
  final bool dspBypassed;

  const SignalPath({
    required this.overallQuality,
    required this.description,
    required this.nodes,
    required this.dspBypassed,
  });
}
