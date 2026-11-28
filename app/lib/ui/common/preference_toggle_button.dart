import 'package:material_ui/material_ui.dart';

import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../theme/lumina_tokens.dart';
import 'lumina_context_menu.dart';

/// Cycles `-1 / 0 / 1` preference on left click (`0 -> 1 -> -1 -> 0`) or lets
/// the user pick Favorite (`1`), Neutral (`0`), or Banned (`-1`) via right-click.
class PreferenceToggleButton extends StatefulWidget {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final String entityType;
  final String entityId;
  final int preference;
  final ValueChanged<int>? onChanged;
  final bool compact;
  final bool showLabel;
  final Key? buttonKey;

  const PreferenceToggleButton({
    super.key,
    required this.audioService,
    this.libraryCache,
    required this.entityType,
    required this.entityId,
    required this.preference,
    this.onChanged,
    this.compact = true,
    this.showLabel = false,
    this.buttonKey,
  });

  static int nextCycleValue(int current) => switch (current) {
    1 => -1,
    -1 => 0,
    _ => 1,
  };

  static String labelFor(int pref) => switch (pref) {
    1 => '喜愛',
    -1 => '已封鎖',
    _ => '普通',
  };

  static IconData iconFor(int pref) => switch (pref) {
    1 => Icons.favorite_rounded,
    -1 => Icons.block_rounded,
    _ => Icons.favorite_border_rounded,
  };

  static Color colorFor(int pref) => switch (pref) {
    1 => const Color(0xFFFB7185),
    -1 => LuminaTokens.statusError,
    _ => LuminaTokens.textMuted,
  };

  @override
  State<PreferenceToggleButton> createState() => _PreferenceToggleButtonState();
}

class _PreferenceToggleButtonState extends State<PreferenceToggleButton> {
  late int _pref;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _pref = widget.preference;
  }

  @override
  void didUpdateWidget(covariant PreferenceToggleButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preference != widget.preference && !_saving) {
      _pref = widget.preference;
    }
  }

  Future<void> _applyPreference(int nextPref) async {
    if (_saving || widget.entityId.trim().isEmpty || nextPref == _pref) return;
    final prev = _pref;
    setState(() {
      _pref = nextPref;
      _saving = true;
    });
    widget.libraryCache?.updateEntityPreferenceSync(
      widget.entityType,
      widget.entityId,
      nextPref,
    );
    try {
      final res = await widget.audioService.setEntityPreference(
        widget.entityType,
        widget.entityId,
        nextPref,
      );
      if (!mounted) return;
      if (res == null) {
        setState(() => _pref = prev);
        widget.libraryCache?.updateEntityPreferenceSync(
          widget.entityType,
          widget.entityId,
          prev,
        );
      } else {
        setState(() => _pref = res.preference);
        widget.onChanged?.call(res.preference);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _pref = prev);
      widget.libraryCache?.updateEntityPreferenceSync(
        widget.entityType,
        widget.entityId,
        prev,
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _openPickerMenu(Offset globalPosition) async {
    final chosen = await showLuminaContextMenu<int>(
      context: context,
      globalPosition: globalPosition,
      minWidth: 184.0,
      menuKey: const Key('preference_picker_menu'),
      entries: [
        LuminaContextMenuAction<int>(
          value: 1,
          icon: Icons.favorite_rounded,
          iconColor: const Color(0xFFFB7185),
          label: '喜愛',
          selected: _pref == 1,
        ),
        LuminaContextMenuAction<int>(
          value: 0,
          icon: Icons.favorite_border_rounded,
          iconColor: LuminaTokens.textSecondary,
          label: '普通（預設）',
          selected: _pref == 0,
        ),
        LuminaContextMenuAction<int>(
          value: -1,
          icon: Icons.block_rounded,
          iconColor: LuminaTokens.statusError,
          label: '封鎖（略過自動播放）',
          selected: _pref == -1,
        ),
      ],
    );
    if (chosen != null) {
      await _applyPreference(chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconData = PreferenceToggleButton.iconFor(_pref);
    final color = PreferenceToggleButton.colorFor(_pref);
    final label = PreferenceToggleButton.labelFor(_pref);
    final tooltip = '偏好：$label（點擊切換，右鍵指定狀態）';

    if (widget.showLabel) {
      return GestureDetector(
        onSecondaryTapUp: (d) => _openPickerMenu(d.globalPosition),
        child: Tooltip(
          message: tooltip,
          child: OutlinedButton.icon(
            key: widget.buttonKey,
            onPressed: () =>
                _applyPreference(PreferenceToggleButton.nextCycleValue(_pref)),
            style: OutlinedButton.styleFrom(
              backgroundColor: _pref == 0
                  ? LuminaTokens.glassPillBg
                  : color.withValues(alpha: 0.14),
              foregroundColor: _pref == 0
                  ? LuminaTokens.glassTextPrimary
                  : color,
              side: BorderSide(
                color: _pref == 0
                    ? LuminaTokens.glassPillBorder
                    : color.withValues(alpha: 0.55),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            icon: Icon(iconData, size: 16, color: color),
            label: Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onSecondaryTapUp: (d) => _openPickerMenu(d.globalPosition),
      child: IconButton(
        key: widget.buttonKey,
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints(
          minWidth: widget.compact ? 28 : 34,
          minHeight: widget.compact ? 28 : 34,
        ),
        icon: Icon(
          iconData,
          size: widget.compact ? 16 : 18,
          color: color,
        ),
        onPressed: () =>
            _applyPreference(PreferenceToggleButton.nextCycleValue(_pref)),
      ),
    );
  }
}

/// Compact pill indicating a banned track or album (`preference == -1`).
class BannedStatusPill extends StatelessWidget {
  const BannedStatusPill({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: LuminaTokens.statusError.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(
          color: LuminaTokens.statusError.withValues(alpha: 0.45),
        ),
      ),
      child: const Text(
        '已封鎖',
        style: TextStyle(
          color: LuminaTokens.statusError,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
