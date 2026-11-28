part of 'album_detail_page.dart';

class _EditAlbumMetadataDialog extends StatefulWidget {
  final String initialTitle;
  final String initialArtist;
  final MetadataPolicy initialPolicy;
  final bool isStreamingAlbum;

  const _EditAlbumMetadataDialog({
    required this.initialTitle,
    required this.initialArtist,
    this.initialPolicy = MetadataPolicy.inherit,
    this.isStreamingAlbum = false,
  });

  @override
  State<_EditAlbumMetadataDialog> createState() =>
      _EditAlbumMetadataDialogState();
}

class _EditAlbumMetadataDialogState extends State<_EditAlbumMetadataDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _artistCtrl;
  late MetadataPolicy _selectedPolicy;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.initialTitle);
    _artistCtrl = TextEditingController(text: widget.initialArtist);
    _selectedPolicy = widget.initialPolicy;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: FrostedGlassContainer(
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '編輯專輯詮釋資料（非破壞性覆寫）',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '手動編輯永遠優先於檔案標籤與雲端補全，重新掃描時不會被覆蓋。',
                  style: TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                TextField(
                  key: const Key('input_override_album_title'),
                  controller: _titleCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: '專輯名稱',
                    labelStyle: TextStyle(color: LuminaTokens.textSecondary),
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceSm),
                TextField(
                  key: const Key('input_override_album_artist'),
                  controller: _artistCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: '藝術家名稱',
                    labelStyle: TextStyle(color: LuminaTokens.textSecondary),
                  ),
                ),
                if (!widget.isStreamingAlbum) ...[
                  const SizedBox(height: LuminaTokens.spaceMd),
                  const Text(
                    '詮釋資料來源策略',
                    style: TextStyle(
                      color: LuminaTokens.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: LuminaTokens.spaceXs),
                  DecoratedBox(
                    key: const Key('album_meta_policy_selector'),
                    decoration: LuminaSettingsStyles.segmentedCapsuleDecoration(),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final policy in const [
                            MetadataPolicy.file,
                            MetadataPolicy.cloud,
                            MetadataPolicy.inherit,
                          ])
                            LuminaSettingsStyles.frostedSegmentChip(
                              key: Key(
                                'chip_album_meta_policy_${policy.toJson()}',
                              ),
                              label: policy.displayLabel,
                              selected: _selectedPolicy == policy,
                              fontSize: 12,
                              onSelected: (_) =>
                                  setState(() => _selectedPolicy = policy),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: LuminaTokens.spaceMd),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('btn_clear_album_metadata'),
                    style: TextButton.styleFrom(
                      foregroundColor: LuminaTokens.statusWarning,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop((
                      action: 'clear',
                      title: '',
                      artist: '',
                      policy: _selectedPolicy,
                    )),
                    icon: const Icon(Icons.restore_rounded, size: 16),
                    label: const Text(
                      '還原為原始檔案標籤（清除手動編輯）',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceXs),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: LuminaTokens.glassTextSecondary,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: LuminaTokens.spaceXs),
                    FilledButton(
                      key: const Key('btn_save_album_metadata'),
                      style: FilledButton.styleFrom(
                        backgroundColor: LuminaTokens.glassSwitchOnTrack,
                        foregroundColor: LuminaTokens.onAccentDark,
                      ),
                      onPressed: () => Navigator.of(context).pop((
                        action: 'save',
                        title: _titleCtrl.text.trim(),
                        artist: _artistCtrl.text.trim(),
                        policy: _selectedPolicy,
                      )),
                      child: const Text('儲存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Hover-Isolated Clickable Artist Link ─────────────────────────────────────

class _ClickableArtistLink extends StatefulWidget {
  final String artistName;
  final double fontSize;
  final FontWeight fontWeight;
  final Color defaultColor;
  final Color hoverColor;
  final VoidCallback onTap;

  const _ClickableArtistLink({
    super.key,
    required this.artistName,
    required this.fontSize,
    required this.fontWeight,
    required this.defaultColor,
    required this.hoverColor,
    required this.onTap,
  });

  @override
  State<_ClickableArtistLink> createState() => _ClickableArtistLinkState();
}

class _ClickableArtistLinkState extends State<_ClickableArtistLink> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final activeColor = _isHovered ? widget.hoverColor : widget.defaultColor;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_isHovered) setState(() => _isHovered = true);
      },
      onExit: (_) {
        if (_isHovered) setState(() => _isHovered = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Text(
          widget.artistName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: activeColor,
            fontSize: widget.fontSize,
            fontWeight: widget.fontWeight,
            decoration: _isHovered
                ? TextDecoration.underline
                : TextDecoration.none,
            decorationColor: activeColor,
          ),
        ),
      ),
    );
  }
}

// ─── Credit Chip ──────────────────────────────────────────────────────────────

class _CreditChip extends StatelessWidget {
  final AlbumCreditInfo credit;
  final VoidCallback? onTap;

  const _CreditChip({required this.credit, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key('detail_credit_${credit.artistId}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: LuminaTokens.glassPillBg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: LuminaTokens.glassPillBorder),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              credit.artistName,
              style: const TextStyle(
                color: LuminaTokens.glassTextPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              credit.role,
              style: const TextStyle(
                color: LuminaTokens.glassTextSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
