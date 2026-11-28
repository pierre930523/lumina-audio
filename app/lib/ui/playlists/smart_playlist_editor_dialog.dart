part of 'smart_playlists_view.dart';

class _SmartPlaylistEditorDialog extends StatefulWidget {
  final SmartPlaylistService service;
  final SmartPlaylistItem? editing;
  final FocusQuery? initialFocusQuery;

  const _SmartPlaylistEditorDialog({
    required this.service,
    this.editing,
    this.initialFocusQuery,
  });

  @override
  State<_SmartPlaylistEditorDialog> createState() =>
      _SmartPlaylistEditorDialogState();
}

class _SmartPlaylistEditorDialogState
    extends State<_SmartPlaylistEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _limitCtrl;
  bool _losslessOnly = false;
  bool _dsdOnly = false;
  bool _favoritesOnly = false;
  int _minSampleRate = 0;
  bool _excludeBanned = true;
  bool _isPinned = true;
  bool _saving = false;
  FocusQuery? _customBaseQuery;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _descCtrl = TextEditingController(text: e?.description ?? '');
    _limitCtrl = TextEditingController(
      text: e?.limitCount != null ? '${e!.limitCount}' : '',
    );
    _excludeBanned = e?.excludeBanned ?? true;
    _isPinned = e?.isPinned ?? true;

    final parsed = widget.initialFocusQuery ?? e?.parseFocusQuery();
    if (parsed != null) {
      _customBaseQuery = parsed;
      for (final p in parsed.predicates) {
        if (p.facet == FocusFacet.format &&
            p.mode == FocusPredicateMode.include &&
            p.value is FocusStringValue) {
          final v = (p.value as FocusStringValue).value;
          if (v == 'lossless') _losslessOnly = true;
          if (v == 'dsd') _dsdOnly = true;
        } else if (p.facet == FocusFacet.sampleRate &&
            p.mode == FocusPredicateMode.include &&
            p.value is FocusIntRangeValue) {
          _minSampleRate = (p.value as FocusIntRangeValue).min ?? 0;
        } else if (p.facet == FocusFacet.preference &&
            p.mode == FocusPredicateMode.include &&
            p.value is FocusStringValue &&
            (p.value as FocusStringValue).value == 'favorite') {
          _favoritesOnly = true;
        }
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _limitCtrl.dispose();
    super.dispose();
  }

  String _buildFocusQueryJson() {
    if (widget.initialFocusQuery != null) {
      return jsonEncode(
        widget.initialFocusQuery!.copyWith(entity: FocusEntity.tracks).toJson(),
      );
    }
    final existing = _customBaseQuery;
    final preserved = <FocusPredicate>[];
    if (existing != null) {
      for (final p in existing.predicates) {
        final isManagedFormat =
            p.facet == FocusFacet.format &&
            p.mode == FocusPredicateMode.include &&
            p.value is FocusStringValue &&
            ((p.value as FocusStringValue).value == 'lossless' ||
                (p.value as FocusStringValue).value == 'dsd');
        final isManagedSr =
            p.facet == FocusFacet.sampleRate &&
            p.mode == FocusPredicateMode.include &&
            p.value is FocusIntRangeValue;
        final isManagedPref =
            p.facet == FocusFacet.preference &&
            p.mode == FocusPredicateMode.include &&
            p.value is FocusStringValue &&
            (p.value as FocusStringValue).value == 'favorite';
        if (!isManagedFormat && !isManagedSr && !isManagedPref) {
          preserved.add(p);
        }
      }
    }
    if (_dsdOnly) {
      preserved.add(
        const FocusPredicate(
          facet: FocusFacet.format,
          value: FocusValue.string('dsd'),
        ),
      );
    } else if (_losslessOnly) {
      preserved.add(
        const FocusPredicate(
          facet: FocusFacet.format,
          value: FocusValue.string('lossless'),
        ),
      );
    }
    if (_minSampleRate > 0) {
      preserved.add(
        FocusPredicate(
          facet: FocusFacet.sampleRate,
          value: FocusValue.intRange(min: _minSampleRate),
        ),
      );
    }
    if (_favoritesOnly) {
      preserved.add(
        const FocusPredicate(
          facet: FocusFacet.preference,
          value: FocusValue.string('favorite'),
        ),
      );
    }
    final query = FocusQuery(
      entity: FocusEntity.tracks,
      predicates: preserved,
      sort: existing?.sort,
      includeHidden: existing?.includeHidden ?? false,
      profileId: existing?.profileId,
    );
    return jsonEncode(query.toJson());
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final name =
        _nameCtrl.text.trim().isEmpty ? '自訂智慧歌單' : _nameCtrl.text.trim();
    final desc = _descCtrl.text.trim();
    final parsedLimit = int.tryParse(_limitCtrl.text.trim());
    final limit =
        (parsedLimit != null && parsedLimit > 0) ? parsedLimit : null;
    final focusJson = _buildFocusQueryJson();

    SmartPlaylistItem? result;
    if (widget.editing == null) {
      result = await widget.service.createPlaylist(
        name: name,
        description: desc,
        focusQueryJson: focusJson,
        excludeBanned: _excludeBanned,
        limitCount: limit,
        isPinned: _isPinned,
      );
    } else {
      result = await widget.service.updatePlaylist(
        widget.editing!.id,
        name: name,
        description: desc,
        focusQueryJson: focusJson,
        excludeBanned: _excludeBanned,
        limitCount: limit,
        clearLimitCount: limit == null,
        isPinned: _isPinned,
      );
    }
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final fromFocus = widget.initialFocusQuery != null;

    InputDecoration fieldDecoration({
      required String labelText,
      required String hintText,
    }) => InputDecoration(
      labelText: labelText,
      hintText: hintText,
      labelStyle: const TextStyle(color: LuminaTokens.glassTextSecondary),
      hintStyle: const TextStyle(color: LuminaTokens.textMuted),
      filled: true,
      fillColor: LuminaTokens.glassPillBg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        borderSide: const BorderSide(color: LuminaTokens.glassPillBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        borderSide: const BorderSide(color: LuminaTokens.glassPillBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        borderSide: const BorderSide(
          color: LuminaTokens.focusRing,
          width: 1.5,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceSm,
        vertical: LuminaTokens.spaceSm,
      ),
    );

    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 520),
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
                Text(
                  fromFocus
                      ? '儲存 Focus 條件為智慧歌單'
                      : (widget.editing == null ? '新增智慧播放清單' : '編輯智慧播放清單'),
                  style: const TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceSm),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          key: const Key('input_smart_playlist_name'),
                          controller: _nameCtrl,
                          style: const TextStyle(
                            color: LuminaTokens.glassTextPrimary,
                            fontSize: 13.5,
                          ),
                          decoration: fieldDecoration(
                            labelText: '歌單名稱',
                            hintText: '例如：96kHz 搖滾精選',
                          ),
                        ),
                        const SizedBox(height: LuminaTokens.spaceSm),
                        TextField(
                          key: const Key('input_smart_playlist_description'),
                          controller: _descCtrl,
                          style: const TextStyle(
                            color: LuminaTokens.glassTextPrimary,
                            fontSize: 13.5,
                          ),
                          decoration: fieldDecoration(
                            labelText: '描述（選填）',
                            hintText: '補充說明篩選目的',
                          ),
                        ),
                        const SizedBox(height: LuminaTokens.spaceSm),
                        TextField(
                          key: const Key('input_smart_playlist_limit'),
                          controller: _limitCtrl,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(
                            color: LuminaTokens.glassTextPrimary,
                            fontSize: 13.5,
                          ),
                          decoration: fieldDecoration(
                            labelText: '曲目數量上限（留白不限）',
                            hintText: '例如：50',
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (!fromFocus) ...[
                          SwitchListTile(
                            key: const Key('switch_smart_lossless'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              '僅納入無損格式（FLAC / ALAC / WAV / DSD）',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                            value: _losslessOnly,
                            onChanged: (v) => setState(() => _losslessOnly = v),
                          ),
                          SwitchListTile(
                            key: const Key('switch_smart_dsd'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              '僅限 DSD 位元流',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                            value: _dsdOnly,
                            onChanged: (v) => setState(() => _dsdOnly = v),
                          ),
                          SwitchListTile(
                            key: const Key('switch_smart_favorites_only'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              '僅限喜愛（Favorite）曲目',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                            value: _favoritesOnly,
                            onChanged: (v) =>
                                setState(() => _favoritesOnly = v),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                '最低取樣率：',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                              DropdownButton<int>(
                                key: const Key('dropdown_smart_sample_rate'),
                                value: _minSampleRate,
                                dropdownColor: LuminaTokens.glassMenuBg,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 0,
                                    child: Text('不限'),
                                  ),
                                  DropdownMenuItem(
                                    value: 44100,
                                    child: Text('44.1 kHz+'),
                                  ),
                                  DropdownMenuItem(
                                    value: 96000,
                                    child: Text('96 kHz+'),
                                  ),
                                  DropdownMenuItem(
                                    value: 192000,
                                    child: Text('192 kHz+'),
                                  ),
                                ],
                                onChanged: (v) {
                                  if (v != null) {
                                    setState(() => _minSampleRate = v);
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                        SwitchListTile(
                          key: const Key('switch_smart_exclude_banned'),
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            '自動略過已封鎖曲目',
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                          value: _excludeBanned,
                          onChanged: (v) => setState(() => _excludeBanned = v),
                        ),
                        SwitchListTile(
                          key: const Key('switch_smart_pin_sidebar'),
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            '釘選至左側導覽欄',
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                          value: _isPinned,
                          onChanged: (v) => setState(() => _isPinned = v),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceSm),
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
                      key: const Key('btn_save_smart_playlist'),
                      style: FilledButton.styleFrom(
                        backgroundColor: LuminaTokens.glassSwitchOnTrack,
                        foregroundColor: LuminaTokens.onAccentDark,
                      ),
                      onPressed: _saving ? null : _save,
                      child: const Text('儲存歌單'),
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
