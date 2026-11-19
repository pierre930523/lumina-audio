import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/streaming_provider_meta.dart';
import '../../services/audio_service.dart';
import '../theme/lumina_tokens.dart';

class StreamingServiceView extends StatefulWidget {
  final AudioService audioService;
  final StreamingProviderMeta provider;
  final String? activeTrackId;
  final VoidCallback onOpenProviderSettings;
  final VoidCallback? onLibraryUpdated;

  const StreamingServiceView({
    super.key,
    required this.audioService,
    required this.provider,
    this.activeTrackId,
    required this.onOpenProviderSettings,
    this.onLibraryUpdated,
  });

  @override
  State<StreamingServiceView> createState() => _StreamingServiceViewState();
}

class _StreamingServiceViewState extends State<StreamingServiceView> {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _syncing = false;
  String? _syncNotice;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _syncCatalog() async {
    setState(() => _syncing = true);
    try {
      final result = await widget.audioService.syncProvider(
        widget.provider.kind,
      );
      widget.onLibraryUpdated?.call();
      if (!mounted) return;
      final count = (result['tracks_count'] as num?)?.toInt();
      setState(() {
        _syncNotice = count != null
            ? '已完成 ${widget.provider.name} 曲庫同步（目前共有 $count 首曲目）'
            : '已完成 ${widget.provider.name} 曲庫同步';
      });
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchCtrl.text.trim().toLowerCase();
    final serviceTracks = widget.audioService.queue.where((t) {
      if (!widget.provider.matchesTrackProvider(t.providerName)) {
        return false;
      }
      if (query.isEmpty) return true;
      return t.title.toLowerCase().contains(query) ||
          t.artist.toLowerCase().contains(query) ||
          t.album.toLowerCase().contains(query);
    }).toList();

    return Column(
      key: Key('streaming_service_view_${widget.provider.kind}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(LuminaTokens.spaceMd),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                widget.provider.badgeColor.withValues(alpha: 0.28),
                LuminaTokens.cardBg,
              ],
            ),
            border: Border.all(
              color: widget.provider.badgeColor.withValues(alpha: 0.55),
            ),
          ),
          child: Wrap(
            spacing: 14,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  widget.provider.buildBadge(boxSize: 44, borderRadius: 10),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.provider.name,
                            style: const TextStyle(
                              color: LuminaTokens.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: LuminaTokens.spaceXs,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: LuminaTokens.statusSuccess.withValues(
                                alpha: 0.16,
                              ),
                              borderRadius: BorderRadius.circular(
                                LuminaTokens.radiusPill,
                              ),
                              border: Border.all(
                                color: LuminaTokens.statusSuccess.withValues(
                                  alpha: 0.55,
                                ),
                              ),
                            ),
                            child: const Text(
                              '已登入連線',
                              style: TextStyle(
                                color: LuminaTokens.statusSuccess,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        widget.provider.subtitle,
                        style: const TextStyle(
                          color: LuminaTokens.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Wrap(
                spacing: LuminaTokens.spaceXs,
                runSpacing: LuminaTokens.spaceXs,
                children: [
                  FilledButton.icon(
                    key: const Key('btn_sync_streaming_provider'),
                    style: FilledButton.styleFrom(
                      backgroundColor: LuminaTokens.accentBlue,
                      foregroundColor: LuminaTokens.onAccentDark,
                    ),
                    onPressed: _syncing ? null : _syncCatalog,
                    icon: _syncing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: LuminaTokens.onAccentDark,
                            ),
                          )
                        : const Icon(Icons.sync_rounded, size: 17),
                    label: const Text('同步曲庫'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('btn_streaming_open_settings'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: LuminaTokens.textPrimary,
                      side: const BorderSide(color: LuminaTokens.borderControl),
                    ),
                    onPressed: widget.onOpenProviderSettings,
                    icon: const Icon(Icons.manage_accounts_outlined, size: 17),
                    label: const Text('帳號設定'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_syncNotice != null) ...[
          const SizedBox(height: LuminaTokens.spaceSm),
          Text(
            _syncNotice!,
            style: const TextStyle(
              color: LuminaTokens.statusSuccess,
              fontSize: 12,
            ),
          ),
        ],
        const SizedBox(height: LuminaTokens.spaceMd),
        TextField(
          key: const Key('streaming_search_input'),
          controller: _searchCtrl,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 13),
          decoration: InputDecoration(
            prefixIcon: const Icon(
              Icons.search_rounded,
              color: LuminaTokens.textMuted,
              size: 18,
            ),
            hintText: '在 ${widget.provider.name} 中搜尋曲目、專輯或藝術家...',
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
              borderSide: const BorderSide(
                color: LuminaTokens.focusRing,
                width: 1.5,
              ),
            ),
          ),
        ),
        const SizedBox(height: LuminaTokens.spaceSm),
        Expanded(
          child: serviceTracks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.library_music_outlined,
                        size: 42,
                        color: LuminaTokens.textMuted,
                      ),
                      const SizedBox(height: LuminaTokens.spaceSm),
                      Text(
                        '目前尚無已同步的 ${widget.provider.name} 曲目',
                        style: const TextStyle(
                          color: LuminaTokens.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: LuminaTokens.spaceXs),
                      const Text(
                        '點擊上方「同步曲庫」即可匯入您的串流收藏與高解析曲目。',
                        style: TextStyle(
                          color: LuminaTokens.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: LuminaTokens.spaceMd),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: LuminaTokens.accentBlue,
                          foregroundColor: LuminaTokens.onAccentDark,
                        ),
                        onPressed: _syncing ? null : _syncCatalog,
                        icon: const Icon(Icons.sync_rounded, size: 17),
                        label: Text('同步 ${widget.provider.name} 曲庫'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(
                    bottom: LuminaTokens.bottomScrollClearance,
                  ),
                  itemCount: serviceTracks.length,
                  itemBuilder: (context, index) {
                    final TrackInfo item = serviceTracks[index];
                    final isSelected = widget.activeTrackId == item.id;
                    return Material(
                      type: MaterialType.transparency,
                      child: ListTile(
                        key: Key('streaming_track_${item.id}'),
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
                              ? widget.provider.badgeColor
                              : LuminaTokens.textSecondary,
                        ),
                        title: Text(
                          item.title,
                          style: TextStyle(
                            color: isSelected
                                ? LuminaTokens.accentBlue
                                : LuminaTokens.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          '${item.artist} • ${item.album} • ${item.format.label}',
                          style: const TextStyle(color: LuminaTokens.textMuted),
                        ),
                        trailing: const Icon(
                          Icons.play_arrow_rounded,
                          color: LuminaTokens.textSecondary,
                        ),
                        onTap: () => widget.audioService.play(track: item),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
