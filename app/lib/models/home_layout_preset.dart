/// Presets controlling the Home workspace layout, navigation shell, and
/// bottom player presentation across Lumina Audio.
enum HomeLayoutPreset {
  topbarMinimal('topbar-minimal', '無側欄極簡', 'AI'),
  auraQuickResume('aura-quick-resume', '光暈快速續播', 'AJ'),
  classic('classic', '經典排版', 'Classic');

  final String storageKey;
  final String label;
  final String badgeCode;

  const HomeLayoutPreset(this.storageKey, this.label, this.badgeCode);

  /// Whether this preset shows the left navigation sidebar on desktop widths.
  bool get usesSidebar => this == HomeLayoutPreset.classic;

  /// Whether this preset collapses the sidebar into the top floating capsule.
  bool get isSidebarless => !usesSidebar;

  /// Whether the bottom player renders as an inset floating glass pill.
  bool get usesFloatingPlayerPill => this != HomeLayoutPreset.classic;

  /// Parses [raw] into a supported [HomeLayoutPreset], or `null` when
  /// missing, deprecated (e.g. legacy `'frosted-minimal'`), or unrecognized.
  static HomeLayoutPreset? tryParseStorageKey(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    for (final preset in HomeLayoutPreset.values) {
      if (preset.storageKey == trimmed || preset.name == trimmed) {
        return preset;
      }
    }
    final normalized = trimmed.toLowerCase().replaceAll('_', '-');
    for (final preset in HomeLayoutPreset.values) {
      if (preset.storageKey.toLowerCase() == normalized ||
          preset.name.toLowerCase() == normalized) {
        return preset;
      }
    }
    return null;
  }

  /// Parses a persisted preset from [storageKey] or enum [name], defaulting
  /// to [HomeLayoutPreset.auraQuickResume].
  static HomeLayoutPreset fromStorageKey(String? raw) =>
      tryParseStorageKey(raw) ?? HomeLayoutPreset.auraQuickResume;
}
