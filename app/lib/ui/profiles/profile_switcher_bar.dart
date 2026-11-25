import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../common/frosted_glass_container.dart';
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
  bool _hovered = false;

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
      barrierColor: LuminaTokens.scrimBg,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Dialog(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: FrostedGlassContainer(
                  blurSigma: LuminaTokens.glassDialogBlur,
                  color: LuminaTokens.glassDialogBg,
                  borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
                  border: Border.all(color: LuminaTokens.glassCardBorder),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x88000000),
                      blurRadius: 32,
                      offset: Offset(0, 14),
                    ),
                  ],
                  padding: const EdgeInsets.all(LuminaTokens.spaceLg),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          '聆聽者設定檔',
                          style: TextStyle(
                            color: LuminaTokens.glassTextPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: LuminaTokens.spaceSm),
                        ..._profiles.map(
                          (p) => ListTile(
                            key: Key('profile_item_${p.id}'),
                            dense: true,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                LuminaTokens.radiusSm,
                              ),
                            ),
                            hoverColor: LuminaTokens.glassRowHoverBg,
                            leading: CircleAvatar(
                              radius: 12,
                              backgroundColor: const Color(0xFF7E22CE),
                              child: Text(
                                _displayProfileName(p.name).isEmpty
                                    ? '?'
                                    : _displayProfileName(p.name)[0]
                                        .toUpperCase(),
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
                                color: LuminaTokens.glassTextPrimary,
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
                                          await widget.audioService
                                              .deleteProfile(p.id);
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
                                  color: LuminaTokens.glassTextPrimary,
                                  fontSize: 13,
                                ),
                                decoration: InputDecoration(
                                  hintText: '輸入新設定檔名稱',
                                  hintStyle: const TextStyle(
                                    color: LuminaTokens.textMuted,
                                  ),
                                  filled: true,
                                  fillColor: LuminaTokens.glassPillBg,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: LuminaTokens.spaceSm,
                                    vertical: LuminaTokens.spaceXs,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(
                                      LuminaTokens.radiusSm,
                                    ),
                                    borderSide: const BorderSide(
                                      color: LuminaTokens.glassPillBorder,
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(
                                      LuminaTokens.radiusSm,
                                    ),
                                    borderSide: const BorderSide(
                                      color: LuminaTokens.glassPillBorder,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(
                                      LuminaTokens.radiusSm,
                                    ),
                                    borderSide: const BorderSide(
                                      color: LuminaTokens.focusRing,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: LuminaTokens.spaceXs),
                            FilledButton(
                              key: const Key('btn_create_profile'),
                              style: FilledButton.styleFrom(
                                backgroundColor:
                                    LuminaTokens.glassSwitchOnTrack,
                                foregroundColor: LuminaTokens.onAccentDark,
                              ),
                              onPressed: () async {
                                final name = _nameCtrl.text.trim();
                                if (name.isEmpty) return;
                                final created = await widget.audioService
                                    .createProfile(name);
                                await widget.audioService.switchProfile(
                                  created.id,
                                );
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
    final radius = BorderRadius.circular(LuminaTokens.radiusPill);
    return Tooltip(
      message: _active != null ? _displayProfileName(_active!.name) : '切換聆聽者設定檔',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: FrostedGlassContainer(
          blurSigma: LuminaTokens.glassPillBlur,
          color: _hovered
              ? LuminaTokens.glassPillHoverBg
              : LuminaTokens.glassPillBg,
          borderRadius: radius,
          border: Border.all(color: LuminaTokens.glassPillBorder),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: const Key('btn_profile_switcher'),
              onTap: _openDialog,
              hoverColor: LuminaTokens.glassPillHoverBg,
              borderRadius: radius,
              child: Padding(
                padding: widget.compact
                    ? const EdgeInsets.all(LuminaTokens.space2xs)
                    : const EdgeInsets.symmetric(
                        horizontal: LuminaTokens.spaceXs,
                        vertical: LuminaTokens.space2xs,
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
                          color: LuminaTokens.glassTextPrimary,
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
                            color: LuminaTokens.glassTextPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: LuminaTokens.space2xs),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
