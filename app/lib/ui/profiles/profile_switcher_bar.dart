import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../theme/lumina_tokens.dart';

class ProfileSwitcherBar extends StatefulWidget {
  final AudioService audioService;
  final bool compact;

  const ProfileSwitcherBar({
    super.key,
    required this.audioService,
    this.compact = false,
  });

  @override
  State<ProfileSwitcherBar> createState() => _ProfileSwitcherBarState();
}

class _ProfileSwitcherBarState extends State<ProfileSwitcherBar> {
  final TextEditingController _nameCtrl = TextEditingController();
  List<UserProfileInfo> _profiles = const [];
  UserProfileInfo? _active;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  String _displayProfileName(String raw) =>
      raw == 'Default Listener' ? '預設聆聽者' : raw;

  Future<void> _reload() async {
    final list = await widget.audioService.listProfiles();
    if (!mounted) return;
    setState(() {
      _profiles = list;
      _active ??= list.where((p) => p.isDefault).firstOrNull ?? list.firstOrNull;
    });
  }

  Future<void> _openDialog() async {
    await _reload();
    if (!mounted) return;
    _nameCtrl.clear();
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: LuminaTokens.cardElevatedBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                side: const BorderSide(color: LuminaTokens.borderControl),
              ),
              title: const Text(
                '聆聽者設定檔',
                style: TextStyle(color: LuminaTokens.textPrimary),
              ),
              content: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ..._profiles.map(
                      (p) => ListTile(
                        key: Key('profile_item_${p.id}'),
                        dense: true,
                        leading: CircleAvatar(
                          radius: 12,
                          backgroundColor: const Color(0xFF7E22CE),
                          child: Text(
                            _displayProfileName(p.name).isEmpty
                                ? '?'
                                : _displayProfileName(p.name)[0].toUpperCase(),
                            style: const TextStyle(
                              fontSize: 12,
                              color: LuminaTokens.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        title: Text(
                          _displayProfileName(p.name),
                          style: const TextStyle(
                            color: LuminaTokens.textPrimary,
                          ),
                        ),
                        trailing: _active?.id == p.id
                            ? const Icon(
                                Icons.check_circle,
                                color: LuminaTokens.statusSuccess,
                                size: 18,
                              )
                            : (!p.isDefault
                                ? IconButton(
                                    tooltip: '刪除設定檔',
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: LuminaTokens.textSecondary,
                                      size: 18,
                                    ),
                                    onPressed: () async {
                                      await widget.audioService.deleteProfile(p.id);
                                      await _reload();
                                      setDialogState(() {});
                                    },
                                  )
                                : null),
                        onTap: () async {
                          await widget.audioService.switchProfile(p.id);
                          setState(() => _active = p);
                          if (ctx.mounted) Navigator.of(ctx).pop();
                        },
                      ),
                    ),
                    const SizedBox(height: LuminaTokens.spaceSm),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('input_new_profile_name'),
                            controller: _nameCtrl,
                            style: const TextStyle(
                              color: LuminaTokens.textPrimary,
                              fontSize: 13,
                            ),
                            decoration: InputDecoration(
                              hintText: '輸入新設定檔名稱',
                              hintStyle: const TextStyle(
                                color: LuminaTokens.textMuted,
                              ),
                              enabledBorder: UnderlineInputBorder(
                                borderSide: const BorderSide(
                                  color: LuminaTokens.borderControl,
                                ),
                              ),
                              focusedBorder: const UnderlineInputBorder(
                                borderSide: BorderSide(
                                  color: LuminaTokens.accentBlue,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: LuminaTokens.spaceXs),
                        FilledButton(
                          key: const Key('btn_create_profile'),
                          style: FilledButton.styleFrom(
                            backgroundColor: LuminaTokens.accentBlue,
                            foregroundColor: LuminaTokens.onAccentDark,
                          ),
                          onPressed: () async {
                            final name = _nameCtrl.text.trim();
                            if (name.isEmpty) return;
                            final created = await widget.audioService.createProfile(name);
                            await widget.audioService.switchProfile(created.id);
                            await _reload();
                            setState(() => _active = created);
                            setDialogState(() {});
                            _nameCtrl.clear();
                          },
                          child: const Text('新增'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = _active != null ? _displayProfileName(_active!.name) : 'L';
    final initial = label.trim().isEmpty ? 'L' : label.trim()[0].toUpperCase();
    return Tooltip(
      message: _active != null ? _displayProfileName(_active!.name) : '切換聆聽者設定檔',
      child: InkWell(
        key: const Key('btn_profile_switcher'),
        onTap: _openDialog,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: widget.compact
              ? const EdgeInsets.all(LuminaTokens.space2xs)
              : const EdgeInsets.symmetric(
                  horizontal: LuminaTokens.spaceXs,
                  vertical: LuminaTokens.space2xs,
                ),
          decoration: BoxDecoration(
            color: LuminaTokens.cardElevatedBg,
            borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
            border: Border.all(color: LuminaTokens.borderControl),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: const Color(0xFFBE185D),
                child: Text(
                  initial,
                  style: const TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (!widget.compact && _active != null) ...[
                const SizedBox(width: LuminaTokens.spaceXs),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 96),
                  child: Text(
                    _displayProfileName(_active!.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: LuminaTokens.space2xs),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
