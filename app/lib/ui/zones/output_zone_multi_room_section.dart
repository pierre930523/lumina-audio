part of 'output_zone_panel.dart';

class _MultiRoomZonesSection extends StatelessWidget {
  final List<AudioZoneInfo> zones;
  final Set<String> selectedGroupZones;
  final AudioService audioService;
  final String Function(AudioZoneInfo) zoneStatusText;
  final VoidCallback onDiscoverZones;
  final VoidCallback onGroupSelected;
  final VoidCallback onSyncAllZones;
  final void Function(String zoneId, bool selected) onToggleZoneSelection;
  final ValueChanged<AudioZoneInfo> onToggleZone;
  final ValueChanged<AudioZoneInfo> onCastZone;
  final Future<void> Function(AudioZoneInfo zone, double volume)
  onVolumeChanged;

  const _MultiRoomZonesSection({
    required this.zones,
    required this.selectedGroupZones,
    required this.audioService,
    required this.zoneStatusText,
    required this.onDiscoverZones,
    required this.onGroupSelected,
    required this.onSyncAllZones,
    required this.onToggleZoneSelection,
    required this.onToggleZone,
    required this.onCastZone,
    required this.onVolumeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '多房間與網路音區',
          style: TextStyle(
            color: LuminaTokens.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: LuminaTokens.spaceSm),
        Wrap(
          spacing: LuminaTokens.spaceXs,
          runSpacing: LuminaTokens.spaceXs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Tooltip(
              message: '探索區域網路內的 DLNA 與 AirPlay 播放音區',
              child: FilledButton.icon(
                key: const Key('btn_discover_zones'),
                onPressed: onDiscoverZones,
                style: LuminaSettingsStyles.filledButtonStyle(),
                icon: const Icon(Icons.radar_rounded, size: 18),
                label: const Text('搜尋 DLNA / AirPlay 設備'),
              ),
            ),
            Tooltip(
              message: '將勾選的多個音區組成同步播放群組',
              child: OutlinedButton.icon(
                key: const Key('btn_group_zones'),
                onPressed: onGroupSelected,
                style: LuminaSettingsStyles.outlinedButtonStyle(),
                icon: const Icon(Icons.speaker_group_rounded, size: 18),
                label: const Text('群組同步播放'),
              ),
            ),
            Tooltip(
              message: '對所有網路音區執行精準時脈校準',
              child: OutlinedButton.icon(
                key: const Key('btn_sync_zones'),
                onPressed: onSyncAllZones,
                style: LuminaSettingsStyles.outlinedButtonStyle(),
                icon: const Icon(Icons.sync_rounded, size: 18),
                label: const Text('校準時脈同步'),
              ),
            ),
          ],
        ),
        const SizedBox(height: LuminaTokens.spaceSm),
        ...zones.map((z) {
          final checked = selectedGroupZones.contains(z.id) || z.groupId != null;
          final zState = audioService.zonePlaybackStates[z.id];
          final zPlaying = zState?.status == PlaybackStatus.playing;
          return _MultiRoomZoneCard(
            zone: z,
            checked: checked,
            isPlaying: zPlaying,
            statusText: zoneStatusText(z),
            onSelectionChanged: (v) => onToggleZoneSelection(z.id, v),
            onTogglePlay: () => onToggleZone(z),
            onCast: () => onCastZone(z),
            onVolumeChanged: (v) => onVolumeChanged(z, v),
          );
        }),
      ],
    );
  }
}

class _MultiRoomZoneCard extends StatelessWidget {
  final AudioZoneInfo zone;
  final bool checked;
  final bool isPlaying;
  final String statusText;
  final ValueChanged<bool> onSelectionChanged;
  final VoidCallback onTogglePlay;
  final VoidCallback onCast;
  final ValueChanged<double> onVolumeChanged;

  const _MultiRoomZoneCard({
    required this.zone,
    required this.checked,
    required this.isPlaying,
    required this.statusText,
    required this.onSelectionChanged,
    required this.onTogglePlay,
    required this.onCast,
    required this.onVolumeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final z = zone;
    return Padding(
      padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
      child: Container(
        key: Key('zone_card_${z.id}'),
        padding: const EdgeInsets.all(LuminaTokens.spaceSm),
        decoration: BoxDecoration(
          color: _OutputZonePanelState._inactiveCardBg,
          borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
          border: Border.all(color: _OutputZonePanelState._inactiveCardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Tooltip(
                  message: '選取「${z.name}」加入多房間群組',
                  child: Semantics(
                    label: '選取 ${z.name}',
                    child: Checkbox(
                      value: checked,
                      activeColor: LuminaTokens.glassSwitchOnTrack,
                      checkColor: LuminaTokens.onAccentDark,
                      side: const BorderSide(
                        color: LuminaTokens.glassPillBorder,
                        width: 1.5,
                      ),
                      onChanged: (v) => onSelectionChanged(v == true),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        z.name,
                        style: const TextStyle(
                          color: LuminaTokens.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$statusText • ${z.backend} • 偏移 ${z.clockOffsetUs} µs • 往返延遲 ${z.rttUs} µs • 時脈漂移 ${z.driftPpm.toStringAsFixed(1)} ppm${z.groupId != null ? ' • 群組：${z.groupId}' : ''}',
                        style: const TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: Key('btn_zone_play_${z.id}'),
                  tooltip: isPlaying ? '暫停此音區' : '播放此音區',
                  style: LuminaSettingsStyles.iconButtonStyle(
                    foregroundColor: isPlaying
                        ? Colors.white
                        : LuminaTokens.glassTextSecondary,
                  ),
                  icon: Icon(
                    isPlaying
                        ? Icons.pause_circle_outline_rounded
                        : Icons.play_circle_outline_rounded,
                    color: isPlaying
                        ? Colors.white
                        : LuminaTokens.glassTextSecondary,
                  ),
                  onPressed: onTogglePlay,
                ),
                if (z.backend.startsWith('network_'))
                  IconButton(
                    key: Key('btn_cast_zone_${z.id}'),
                    tooltip: '投放至 ${z.name}',
                    style: LuminaSettingsStyles.iconButtonStyle(
                      foregroundColor: LuminaTokens.glassTextPrimary,
                    ),
                    icon: const Icon(
                      Icons.cast_rounded,
                      color: LuminaTokens.glassTextPrimary,
                    ),
                    onPressed: onCast,
                  ),
              ],
            ),
            Row(
              children: [
                const Icon(
                  Icons.volume_up_rounded,
                  color: LuminaTokens.textMuted,
                  size: 16,
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: LuminaTokens.glassTextPrimary,
                      inactiveTrackColor: LuminaTokens.glassTrackUnplayed,
                      thumbColor: Colors.white,
                      overlayColor: LuminaTokens.glassPillHoverBg,
                    ),
                    child: Semantics(
                      label: '${z.name} 音量',
                      child: Slider(
                        key: Key('zone_volume_${z.id}'),
                        min: 0.0,
                        max: 1.0,
                        value: z.volume.clamp(0.0, 1.0),
                        onChanged: onVolumeChanged,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${(z.volume * 100).round()}%',
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      color: LuminaTokens.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
