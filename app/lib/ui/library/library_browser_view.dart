import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../services/audio_service.dart';
import '../../services/library_settings_controller.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';

class LibraryBrowserView extends StatefulWidget {
  final AudioService audioService;
  final String? activeTrackId;
  final LibrarySettingsController? librarySettings;
  final VoidCallback? onOpenLibrarySettings;

  const LibraryBrowserView({
    super.key,
    required this.audioService,
    this.activeTrackId,
    this.librarySettings,
    this.onOpenLibrarySettings,
  });

  @override
  State<LibraryBrowserView> createState() => _LibraryBrowserViewState();
}

class _LibraryBrowserViewState extends State<LibraryBrowserView> {
  final TextEditingController _searchController = TextEditingController();
  late List<TrackInfo> _visibleTracks;
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _visibleTracks = List<TrackInfo>.from(widget.audioService.queue);
  }

  @override
  void didUpdateWidget(covariant LibraryBrowserView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_searchController.text.trim().isEmpty) {
      _visibleTracks = List<TrackInfo>.from(widget.audioService.queue);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _onSearchChanged(String query) async {
    final seq = ++_searchSeq;
    final results = await widget.audioService.searchLibrary(query);
    if (!mounted || seq != _searchSeq) return;
    setState(() {
      _visibleTracks = results;
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _onSearchChanged('');
  }

  List<TrackInfo> _filteredTracks() {
    final settings = widget.librarySettings;
    if (settings == null || settings.excludedExtensions.isEmpty) {
      return _visibleTracks;
    }
    return _visibleTracks
        .where((t) => !settings.isTrackExcluded(t.filePath, t.format.codec.name))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final searchField = TextField(
      key: const Key('library_search_input'),
      controller: _searchController,
      onChanged: _onSearchChanged,
      style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        prefixIcon: const Icon(
          Icons.search_rounded,
          color: LuminaTokens.textMuted,
          size: 18,
        ),
        suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchController,
          builder: (context, value, _) {
            if (value.text.isEmpty) {
              return const SizedBox.shrink();
            }
            return IconButton(
              key: const Key('btn_library_search_clear'),
              tooltip: '清除搜尋',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: const EdgeInsets.only(right: 4),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(
                Icons.close_rounded,
                color: LuminaTokens.textMuted,
                size: 17,
              ),
              onPressed: _clearSearch,
            );
          },
        ),
        hintText: '搜尋藝術家、專輯或曲目...',
        hintStyle: const TextStyle(color: LuminaTokens.textMuted),
        filled: true,
        fillColor: LuminaTokens.cardBg,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: LuminaTokens.spaceSm,
          vertical: LuminaTokens.spaceSm,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          borderSide: const BorderSide(color: LuminaTokens.borderControl),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          borderSide: const BorderSide(color: LuminaTokens.borderControl),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          borderSide: const BorderSide(color: LuminaTokens.focusRing, width: 1.5),
        ),
      ),
    );

    final settingsShortcut = widget.onOpenLibrarySettings != null
        ? LayoutBuilder(
            builder: (context, constraints) {
              return OutlinedButton.icon(
                key: const Key('btn_open_library_settings'),
                onPressed: widget.onOpenLibrarySettings,
                icon: const Icon(Icons.folder_open_rounded, size: 17),
                label: const Text('設定資料夾與掃描'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: LuminaTokens.textPrimary,
                  side: const BorderSide(color: LuminaTokens.borderControl),
                  padding: const EdgeInsets.symmetric(
                    horizontal: LuminaTokens.spaceMd,
                    vertical: LuminaTokens.spaceSm,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                  ),
                ),
              );
            },
          )
        : null;

    Widget buildBody(List<TrackInfo> tracks) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LuminaTokens.spaceLg,
              vertical: LuminaTokens.spaceXs,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (settingsShortcut == null) {
                  return searchField;
                }
                if (constraints.maxWidth >= 560) {
                  return Row(
                    children: [
                      Expanded(child: searchField),
                      const SizedBox(width: LuminaTokens.spaceSm),
                      settingsShortcut,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: searchField),
                    const SizedBox(width: LuminaTokens.spaceXs),
                    IconButton.outlined(
                      key: const Key('btn_open_library_settings'),
                      tooltip: '資料夾與掃描設定',
                      onPressed: widget.onOpenLibrarySettings,
                      icon: const Icon(Icons.folder_open_rounded, size: 18),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: LuminaTokens.textPrimary,
                        side: const BorderSide(color: LuminaTokens.borderControl),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          Expanded(
            child: tracks.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(LuminaTokens.spaceLg),
                      child: Text(
                        '找不到符合條件的曲目，您可在「設定 → 音樂庫」掃描更多資料夾',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    key: const Key('track_queue_list'),
                    padding: const EdgeInsets.fromLTRB(
                      LuminaTokens.spaceLg,
                      0,
                      LuminaTokens.spaceLg,
                      LuminaTokens.bottomScrollClearance,
                    ),
                    itemCount: tracks.length,
                    itemBuilder: (context, index) {
                      final item = tracks[index];
                      final isSelected = widget.activeTrackId == item.id;
                      return TrackHoverPrefetch(
                        track: item,
                        child: Material(
                          type: MaterialType.transparency,
                          child: ListTile(
                            key: Key('queue_track_${item.id}'),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                LuminaTokens.radiusSm,
                              ),
                            ),
                            hoverColor: LuminaTokens.cardHoverBg.withValues(
                              alpha: 0.6,
                            ),
                            leading: Icon(
                              isSelected
                                  ? Icons.equalizer_rounded
                                  : Icons.music_note_rounded,
                              color: isSelected
                                  ? LuminaTokens.accentPurpleText
                                  : LuminaTokens.textSecondary,
                            ),
                            title: Text(
                              item.title,
                              style: TextStyle(
                                color: isSelected
                                    ? LuminaTokens.accentPurpleText
                                    : LuminaTokens.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              '${item.artist} • ${item.album} • ${item.format.label}',
                              style: const TextStyle(
                                color: LuminaTokens.textMuted,
                              ),
                            ),
                            onTap: () => widget.audioService.play(track: item),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
    }

    if (widget.librarySettings == null) {
      return buildBody(_filteredTracks());
    }

    return ListenableBuilder(
      listenable: widget.librarySettings!,
      builder: (context, _) => buildBody(_filteredTracks()),
    );
  }
}
