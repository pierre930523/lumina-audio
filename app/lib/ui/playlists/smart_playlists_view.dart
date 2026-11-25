import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/smart_playlist.dart';
import '../../services/audio_service.dart';
import '../../services/smart_playlist_service.dart';
import '../common/frosted_glass_container.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';

class SmartPlaylistsView extends StatefulWidget {
  final AudioService audioService;
  final SmartPlaylistService playlistService;
  final String? selectedPlaylistId;
  final ValueChanged<String>? onSelectPlaylist;

  const SmartPlaylistsView({
    super.key,
    required this.audioService,
    required this.playlistService,
    this.selectedPlaylistId,
    this.onSelectPlaylist,
  });

  static Future<SmartPlaylist?> showCreateDialog({
    required BuildContext context,
    required SmartPlaylistService service,
    required List<TrackInfo> libraryTracks,
    SmartPlaylist? editing,
  }) {
    return showDialog<SmartPlaylist>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (ctx) => _SmartPlaylistEditorDialog(
        service: service,
        libraryTracks: libraryTracks,
        editing: editing,
      ),
    );
  }

  @override
  State<SmartPlaylistsView> createState() => _SmartPlaylistsViewState();
}

class _SmartPlaylistsViewState extends State<SmartPlaylistsView> {
  late String _activeId;

  @override
  void initState() {
    super.initState();
    final all = widget.playlistService.playlists;
    _activeId =
        widget.selectedPlaylistId ?? (all.isNotEmpty ? all.first.id : '');
  }

  @override
  void didUpdateWidget(covariant SmartPlaylistsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedPlaylistId != null &&
        widget.selectedPlaylistId != _activeId) {
      _activeId = widget.selectedPlaylistId!;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.playlistService,
      builder: (context, _) {
        final playlists = widget.playlistService.playlists;
        final active = playlists.where((p) => p.id == _activeId).firstOrNull ??
            (playlists.isNotEmpty ? playlists.first : null);
        final allTracks = widget.audioService.queue;
        final matchedTracks =
            active != null ? active.evaluate(allTracks) : const <TrackInfo>[];

        return LayoutBuilder(
          key: const Key('smart_playlists_view'),
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 720;

            final headerRow = Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        color: LuminaTokens.glassTextPrimary,
                        size: 20,
                      ),
                      SizedBox(width: 8),
                      Text(
                        '智慧播放清單',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  FilledButton.icon(
                    key: const Key('btn_create_smart_playlist'),
                    style: FilledButton.styleFrom(
                      backgroundColor: LuminaTokens.glassSwitchOnTrack,
                      foregroundColor: LuminaTokens.onAccentDark,
                    ),
                    onPressed: () async {
                      final created =
                          await SmartPlaylistsView.showCreateDialog(
                        context: context,
                        service: widget.playlistService,
                        libraryTracks: allTracks,
                      );
                      if (created != null && mounted) {
                        setState(() => _activeId = created.id);
                        widget.onSelectPlaylist?.call(created.id);
                      }
                    },
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('新增智慧歌單'),
                  ),
                ],
              ),
            );

            final playlistRail = Container(
              width: isWide ? 248 : double.infinity,
              decoration: BoxDecoration(
                color: LuminaTokens.glassCardBg,
                borderRadius: BorderRadius.circular(
                  LuminaTokens.glassCardRadius,
                ),
                border: Border.all(color: LuminaTokens.glassCardBorder),
              ),
              child: isWide
                  ? ListView.builder(
                      padding: const EdgeInsets.only(
                        top: LuminaTokens.spaceXs,
                        bottom: LuminaTokens.bottomScrollClearance,
                      ),
                      itemCount: playlists.length,
                      itemBuilder: (context, index) => _buildPlaylistTile(
                        playlists[index],
                        allTracks,
                        active?.id == playlists[index].id,
                      ),
                    )
                  : SizedBox(
                      height: 46,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: LuminaTokens.spaceSm,
                          vertical: LuminaTokens.spaceXs,
                        ),
                        itemCount: playlists.length,
                        itemBuilder: (context, index) {
                          final sp = playlists[index];
                          final selected = active?.id == sp.id;
                          return Padding(
                            padding: const EdgeInsets.only(
                              right: LuminaTokens.spaceXs,
                            ),
                            child: ChoiceChip(
                              key: Key('smart_playlist_item_${sp.id}'),
                              selected: selected,
                              showCheckmark: false,
                              surfaceTintColor: Colors.transparent,
                              backgroundColor: LuminaTokens.glassPillBg,
                              selectedColor:
                                  LuminaTokens.glassSegmentSelectedBg,
                              side: BorderSide(
                                color: selected
                                    ? LuminaTokens.glassSegmentSelectedBorder
                                    : LuminaTokens.glassPillBorder,
                              ),
                              onSelected: (_) {
                                setState(() => _activeId = sp.id);
                                widget.onSelectPlaylist?.call(sp.id);
                              },
                              label: Text(
                                '${sp.name} (${sp.evaluate(allTracks).length})',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: selected
                                      ? Colors.white
                                      : LuminaTokens.glassTextSecondary,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            );

            final detailPane = active == null
                ? const Center(
                    child: Text(
                      '尚未建立智慧歌單',
                      style: TextStyle(color: LuminaTokens.textMuted),
                    ),
                  )
                : Container(
                    padding: const EdgeInsets.all(LuminaTokens.spaceMd),
                    decoration: BoxDecoration(
                      color: LuminaTokens.glassCardBg,
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.glassCardRadius,
                      ),
                      border: Border.all(color: LuminaTokens.glassCardBorder),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  active.name,
                                  style: const TextStyle(
                                    color: LuminaTokens.textPrimary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (active.description.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      active.description,
                                      style: const TextStyle(
                                        color: LuminaTokens.textMuted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                FilledButton.icon(
                                  key: const Key('btn_play_smart_playlist'),
                                  style: FilledButton.styleFrom(
                                    backgroundColor:
                                        LuminaTokens.glassSwitchOnTrack,
                                    foregroundColor: LuminaTokens.onAccentDark,
                                  ),
                                  onPressed: matchedTracks.isEmpty
                                      ? null
                                      : () => widget.audioService.play(
                                          track: matchedTracks.first,
                                        ),
                                  icon: const Icon(
                                    Icons.play_arrow_rounded,
                                    size: 18,
                                  ),
                                  label: Text('播放 (${matchedTracks.length})'),
                                ),
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    backgroundColor: LuminaTokens.glassPillBg,
                                    foregroundColor:
                                        LuminaTokens.glassTextPrimary,
                                    side: const BorderSide(
                                      color: LuminaTokens.glassPillBorder,
                                    ),
                                  ),
                                  onPressed: () async {
                                    await SmartPlaylistsView.showCreateDialog(
                                      context: context,
                                      service: widget.playlistService,
                                      libraryTracks: allTracks,
                                      editing: active,
                                    );
                                  },
                                  icon: const Icon(Icons.edit_outlined, size: 16),
                                  label: const Text('編輯條件'),
                                ),
                                if (!active.isBuiltIn)
                                  IconButton(
                                    key: Key(
                                      'btn_delete_smart_playlist_${active.id}',
                                    ),
                                    tooltip: '刪除智慧歌單',
                                    onPressed: () {
                                      widget.playlistService.deletePlaylist(
                                        active.id,
                                      );
                                      setState(() {
                                        final rem =
                                            widget.playlistService.playlists;
                                        _activeId =
                                            rem.isNotEmpty ? rem.first.id : '';
                                      });
                                    },
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                      color: LuminaTokens.textSecondary,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: LuminaTokens.spaceSm),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: active.ruleTags
                              .map(
                                (tag) => Chip(
                                  visualDensity: VisualDensity.compact,
                                  surfaceTintColor: Colors.transparent,
                                  backgroundColor: LuminaTokens.glassPillBg,
                                  side: const BorderSide(
                                    color: LuminaTokens.glassPillBorder,
                                  ),
                                  label: Text(
                                    tag,
                                    style: const TextStyle(
                                      color: LuminaTokens.glassTextPrimary,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                        const Divider(
                          color: LuminaTokens.glassCardDivider,
                          height: 22,
                        ),
                        Expanded(
                          child: matchedTracks.isEmpty
                              ? const Center(
                                  child: Text(
                                    '目前曲庫內沒有符合此篩選條件的曲目',
                                    style: TextStyle(
                                      color: LuminaTokens.textMuted,
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.only(
                                    bottom: LuminaTokens.bottomScrollClearance,
                                  ),
                                  itemCount: matchedTracks.length,
                                  itemBuilder: (context, index) {
                                    final t = matchedTracks[index];
                                    return TrackHoverPrefetch(
                                      track: t,
                                      child: Material(
                                        type: MaterialType.transparency,
                                        child: ListTile(
                                          key: Key('smart_playlist_track_${t.id}'),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              LuminaTokens.radiusSm,
                                            ),
                                          ),
                                          hoverColor:
                                              LuminaTokens.glassRowHoverBg,
                                          leading: const Icon(
                                            Icons.music_note_rounded,
                                            color: LuminaTokens.textSecondary,
                                          ),
                                          title: Text(
                                            t.title,
                                            style: const TextStyle(
                                              color: LuminaTokens.textPrimary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          subtitle: Text(
                                            '${t.artist} • ${t.album} • ${t.format.label}',
                                            style: const TextStyle(
                                              color: LuminaTokens.textMuted,
                                              fontSize: 12,
                                            ),
                                          ),
                                          trailing: const Icon(
                                            Icons.play_arrow_rounded,
                                            color: LuminaTokens.textSecondary,
                                          ),
                                          onTap: () => widget.audioService.play(
                                            track: t,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                headerRow,
                Expanded(
                  child: isWide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            playlistRail,
                            const SizedBox(width: 14),
                            Expanded(child: detailPane),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            playlistRail,
                            const SizedBox(height: 10),
                            Expanded(child: detailPane),
                          ],
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildPlaylistTile(
    SmartPlaylist sp,
    List<TrackInfo> allTracks,
    bool selected,
  ) {
    final count = sp.evaluate(allTracks).length;
    final radius = BorderRadius.circular(LuminaTokens.radiusSm);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? LuminaTokens.glassNavActiveBg : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          key: Key('smart_playlist_item_${sp.id}'),
          borderRadius: radius,
          hoverColor: LuminaTokens.glassRowHoverBg,
          onTap: () {
            setState(() => _activeId = sp.id);
            widget.onSelectPlaylist?.call(sp.id);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 16,
                  color: selected
                      ? Colors.white
                      : LuminaTokens.glassTextSecondary,
                ),
                const SizedBox(width: LuminaTokens.spaceSm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sp.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? Colors.white
                              : LuminaTokens.glassTextSecondary,
                          fontSize: 13.5,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      Text(
                        '$count 首符合',
                        style: const TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SmartPlaylistEditorDialog extends StatefulWidget {
  final SmartPlaylistService service;
  final List<TrackInfo> libraryTracks;
  final SmartPlaylist? editing;

  const _SmartPlaylistEditorDialog({
    required this.service,
    required this.libraryTracks,
    this.editing,
  });

  @override
  State<_SmartPlaylistEditorDialog> createState() =>
      _SmartPlaylistEditorDialogState();
}

class _SmartPlaylistEditorDialogState
    extends State<_SmartPlaylistEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _keywordCtrl;
  bool _losslessOnly = true;
  bool _dsdOnly = false;
  int _minSampleRate = 0;
  int _minBitDepth = 0;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _keywordCtrl = TextEditingController(text: e?.keyword ?? '');
    if (e != null) {
      _losslessOnly = e.losslessOnly;
      _dsdOnly = e.dsdOnly;
      _minSampleRate = e.minSampleRateHz;
      _minBitDepth = e.minBitDepth;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _keywordCtrl.dispose();
    super.dispose();
  }

  SmartPlaylist _buildDraft() => SmartPlaylist(
    id: widget.editing?.id ?? 'draft',
    name: _nameCtrl.text.trim().isEmpty ? '自訂智慧歌單' : _nameCtrl.text.trim(),
    isBuiltIn: widget.editing?.isBuiltIn ?? false,
    losslessOnly: _losslessOnly,
    dsdOnly: _dsdOnly,
    minSampleRateHz: _minSampleRate,
    minBitDepth: _minBitDepth,
    keyword: _keywordCtrl.text.trim(),
  );

  @override
  Widget build(BuildContext context) {
    final previewCount = _buildDraft().evaluate(widget.libraryTracks).length;

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
        constraints: const BoxConstraints(maxWidth: 440),
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
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.editing == null ? '新增智慧播放清單' : '編輯智慧播放清單條件',
                    style: const TextStyle(
                      color: LuminaTokens.glassTextPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: LuminaTokens.spaceMd),
                  TextField(
                    key: const Key('input_smart_playlist_name'),
                    controller: _nameCtrl,
                    onChanged: (_) => setState(() {}),
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
                    key: const Key('input_smart_playlist_keyword'),
                    controller: _keywordCtrl,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(
                      color: LuminaTokens.glassTextPrimary,
                      fontSize: 13.5,
                    ),
                    decoration: fieldDecoration(
                      labelText: '關鍵字過濾（藝術家 / 專輯 / 曲名）',
                      hintText: '留白代表全部',
                    ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    key: const Key('switch_smart_lossless'),
                    contentPadding: EdgeInsets.zero,
                    hoverColor: LuminaTokens.glassRowHoverBg,
                    title: const Text(
                      '僅納入無損格式（FLAC / ALAC / WAV / DSD）',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    value: _losslessOnly,
                    onChanged: (v) => setState(() => _losslessOnly = v),
                  ),
                  SwitchListTile(
                    key: const Key('switch_smart_dsd'),
                    contentPadding: EdgeInsets.zero,
                    hoverColor: LuminaTokens.glassRowHoverBg,
                    title: const Text(
                      '僅限 DSD 位元流',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    value: _dsdOnly,
                    onChanged: (v) => setState(() => _dsdOnly = v),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '最低取樣率：',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
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
                          DropdownMenuItem(value: 0, child: Text('不限')),
                          DropdownMenuItem(value: 44100, child: Text('44.1 kHz+')),
                          DropdownMenuItem(value: 96000, child: Text('96 kHz+')),
                          DropdownMenuItem(value: 192000, child: Text('192 kHz+')),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _minSampleRate = v);
                        },
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '最低位元深度：',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      DropdownButton<int>(
                        key: const Key('dropdown_smart_bit_depth'),
                        value: _minBitDepth,
                        dropdownColor: LuminaTokens.glassMenuBg,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('不限')),
                          DropdownMenuItem(value: 16, child: Text('16-bit+')),
                          DropdownMenuItem(value: 24, child: Text('24-bit+')),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _minBitDepth = v);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '即時預覽：目前曲庫有 $previewCount 首符合條件',
                    style: const TextStyle(
                      color: LuminaTokens.glassTextSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: LuminaTokens.spaceLg),
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
                        onPressed: () {
                          final draft = _buildDraft();
                          if (widget.editing == null) {
                            final created = widget.service.createPlaylist(
                              name: draft.name,
                              losslessOnly: draft.losslessOnly,
                              dsdOnly: draft.dsdOnly,
                              minSampleRateHz: draft.minSampleRateHz,
                              minBitDepth: draft.minBitDepth,
                              keyword: draft.keyword,
                            );
                            Navigator.of(context).pop(created);
                          } else {
                            widget.service.updatePlaylist(draft);
                            Navigator.of(context).pop(draft);
                          }
                        },
                        child: const Text('儲存歌單'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
