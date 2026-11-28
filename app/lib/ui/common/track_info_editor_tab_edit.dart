part of 'track_info_editor_dialog.dart';

extension _TrackInfoEditorEditTab on _TrackInfoEditorDialogState {
  Widget _buildEditTrackTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: LuminaTokens.cardElevatedBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: LuminaTokens.borderSubtle),
          ),
          child: const Row(
            children: [
              Icon(
                Icons.shield_outlined,
                color: LuminaTokens.statusSuccess,
                size: 15,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '所有編輯僅儲存於曲庫手動覆寫層（user_edits_json），絕不會更動或回寫原始音訊檔案。',
                  style: TextStyle(
                    color: LuminaTokens.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(right: 4),
            child: Column(
              children: [
                _fieldRow('曲目標題', _titleCtrl, const Key('field_edit_track_title')),
                _fieldRow('藝術家', _artistCtrl, const Key('field_edit_track_artist')),
                _fieldRow(
                  '專輯藝術家',
                  _albumArtistCtrl,
                  const Key('field_edit_track_album_artist'),
                ),
                _fieldRow('作曲家', _composerCtrl, const Key('field_edit_track_composer')),
                Row(
                  children: [
                    Expanded(
                      child: _fieldRow(
                        '曲目編號',
                        _trackNumberCtrl,
                        const Key('field_edit_track_number'),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _fieldRow(
                        '光碟編號',
                        _discNumberCtrl,
                        const Key('field_edit_track_disc'),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _fieldRow(
                        '年份',
                        _yearCtrl,
                        const Key('field_edit_track_year'),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                _fieldRow('曲風', _genreCtrl, const Key('field_edit_track_genre')),
                _fieldRow(
                  '歌詞',
                  _lyricsCtrl,
                  const Key('field_edit_track_lyrics'),
                  maxLines: 5,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              key: const Key('btn_restore_original_tags'),
              onPressed: _busy ? null : _restoreOriginalFileTags,
              icon: const Icon(Icons.restore_rounded, size: 16),
              label: const Text('還原原始檔案標籤'),
            ),
            const Spacer(),
            FilledButton(
              key: const Key('btn_save_track_edits'),
              onPressed: _busy ? null : _saveUserEdits,
              style: FilledButton.styleFrom(
                backgroundColor: LuminaTokens.accentBlue,
                foregroundColor: LuminaTokens.onAccentDark,
              ),
              child: const Text('儲存曲目設定'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _fieldRow(
    String label,
    TextEditingController controller,
    Key fieldKey, {
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        key: fieldKey,
        controller: controller,
        enabled: !_busy,
        keyboardType: keyboardType,
        maxLines: maxLines,
        style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(
            color: LuminaTokens.textMuted,
            fontSize: 12,
          ),
          filled: true,
          fillColor: LuminaTokens.cardElevatedBg,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: LuminaTokens.borderSubtle),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
        ),
      ),
    );
  }

  FieldPatchOp<Object?> _stringFieldOp(String rawText, String? prevUserVal) {
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) {
      return prevUserVal != null
          ? const FieldPatchOp<Object?>.clear()
          : const FieldPatchOp<Object?>.keep();
    }
    if (trimmed == prevUserVal) return const FieldPatchOp<Object?>.keep();
    return FieldPatchOp<Object?>.set(trimmed);
  }

  FieldPatchOp<Object?> _intFieldOp(String rawText, int? prevUserVal) {
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) {
      return prevUserVal != null
          ? const FieldPatchOp<Object?>.clear()
          : const FieldPatchOp<Object?>.keep();
    }
    final parsed = int.tryParse(trimmed);
    if (parsed == null || parsed <= 0) {
      return const FieldPatchOp<Object?>.keep();
    }
    if (parsed == prevUserVal) return const FieldPatchOp<Object?>.keep();
    return FieldPatchOp<Object?>.set(parsed);
  }

  Future<void> _saveUserEdits() async {
    if (_busy) return;
    final prevUser = _fileInfo?.userEditsLayer;
    final eff = _fileInfo?.effectiveLayer;

    FieldPatchOp<Object?> strOpFor(
      TextEditingController ctrl,
      String? userVal,
      String? effVal,
    ) {
      final text = ctrl.text.trim();
      final baseline = effVal?.trim() ?? '';
      if (text == baseline && userVal == null) {
        return const FieldPatchOp<Object?>.keep();
      }
      return _stringFieldOp(ctrl.text, userVal);
    }

    FieldPatchOp<Object?> intOpFor(
      TextEditingController ctrl,
      int? userVal,
      int? effVal,
    ) {
      final parsed = int.tryParse(ctrl.text.trim());
      if (parsed == effVal && userVal == null) {
        return const FieldPatchOp<Object?>.keep();
      }
      return _intFieldOp(ctrl.text, userVal);
    }

    final fields = <String, FieldPatchOp<Object?>>{
      'title': strOpFor(_titleCtrl, prevUser?.title, eff?.title ?? widget.track.title),
      'artist_name': strOpFor(
        _artistCtrl,
        prevUser?.artistName,
        eff?.artistName ?? widget.track.artist,
      ),
      'album_artist': strOpFor(
        _albumArtistCtrl,
        prevUser?.albumArtist,
        eff?.albumArtist ?? widget.track.albumArtist,
      ),
      'composer': strOpFor(
        _composerCtrl,
        prevUser?.composer,
        eff?.composer ?? widget.track.composer,
      ),
      'track_number': intOpFor(
        _trackNumberCtrl,
        prevUser?.trackNumber,
        eff?.trackNumber ?? widget.track.trackNumber,
      ),
      'disc_number': intOpFor(
        _discNumberCtrl,
        prevUser?.discNumber,
        eff?.discNumber ?? widget.track.discNumber,
      ),
      'release_year': intOpFor(
        _yearCtrl,
        prevUser?.releaseYear,
        eff?.releaseYear ?? widget.track.year,
      ),
      'genre': strOpFor(_genreCtrl, prevUser?.genre, eff?.genre ?? widget.track.genre),
      'lyrics': strOpFor(_lyricsCtrl, prevUser?.lyrics, eff?.lyrics),
    }..removeWhere((_, op) => op is FieldPatchKeep<Object?>);

    if (fields.isEmpty) {
      _setBusyAndStatus(status: '沒有需要儲存的欄位變更');
      return;
    }

    _setBusyAndStatus(busy: true);
    try {
      final res = await widget.audioService.applyBulkEdit(
        BulkEditEntityType.track,
        <String>[widget.track.id],
        BulkEditPatch(fields: fields),
      );
      final updated = await widget.audioService.getTrackFileInfo(
        widget.track.id,
      );
      if (!mounted) return;
      _setBusyAndStatus(
        busy: false,
        fileInfo: updated,
        syncForm: true,
        status: res != null ? '已儲存至手動編輯層（未更動原始檔案）' : '儲存曲目設定失敗',
        isError: res == null,
      );
      if (res != null) _emitTrackUpdated(updated);
    } catch (e) {
      _setBusyAndStatus(busy: false, status: '儲存曲目設定失敗：$e', isError: true);
    }
  }

  Future<void> _restoreOriginalFileTags() async {
    if (_busy) return;
    _setBusyAndStatus(busy: true);
    try {
      final res = await widget.audioService.applyBulkEdit(
        BulkEditEntityType.track,
        <String>[widget.track.id],
        BulkEditPatch(
          metaPolicy: FieldPatchOp<String>.set(MetadataPolicy.file.toJson()),
          revertToFileMeta: true,
        ),
      );
      final updated = await widget.audioService.getTrackFileInfo(
        widget.track.id,
      );
      if (!mounted) return;
      _setBusyAndStatus(
        busy: false,
        fileInfo: updated,
        syncForm: true,
        status: res != null ? '已還原為原始音訊檔案標籤' : '還原原始檔案標籤失敗',
        isError: res == null,
      );
      if (res != null) _emitTrackUpdated(updated);
    } catch (e) {
      _setBusyAndStatus(busy: false, status: '還原原始檔案標籤失敗：$e', isError: true);
    }
  }
}
