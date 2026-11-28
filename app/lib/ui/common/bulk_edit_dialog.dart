import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../settings/settings_styles.dart';
import '../tags/tag_picker_dialog.dart';
import '../theme/lumina_tokens.dart';
import 'frosted_glass_container.dart';

part 'bulk_edit_dialog_sections.dart';

enum _BulkFieldEditMode { untouched, setValue, clear }

class _BulkFieldSpec {
  final String key;
  final String label;
  final bool isInt;
  final bool multiline;

  const _BulkFieldSpec({
    required this.key,
    required this.label,
    this.isInt = false,
    this.multiline = false,
  });
}

const List<_BulkFieldSpec> _kAlbumBulkFieldSpecs = <_BulkFieldSpec>[
  _BulkFieldSpec(key: 'title', label: '專輯名稱'),
  _BulkFieldSpec(key: 'sort_title', label: '排序標題'),
  _BulkFieldSpec(key: 'album_artist', label: '專輯演出者'),
  _BulkFieldSpec(key: 'release_year', label: '發行年份', isInt: true),
  _BulkFieldSpec(key: 'upc', label: 'UPC 條碼'),
  _BulkFieldSpec(key: 'editorial_bio', label: '專輯簡介', multiline: true),
];

const List<_BulkFieldSpec> _kTrackBulkFieldSpecs = <_BulkFieldSpec>[
  _BulkFieldSpec(key: 'title', label: '曲目標題'),
  _BulkFieldSpec(key: 'artist_name', label: '演出者'),
  _BulkFieldSpec(key: 'album_artist', label: '專輯演出者'),
  _BulkFieldSpec(key: 'album_title', label: '所屬專輯'),
  _BulkFieldSpec(key: 'disc_number', label: '碟片編號', isInt: true),
  _BulkFieldSpec(key: 'track_number', label: '曲目編號', isInt: true),
  _BulkFieldSpec(key: 'genre', label: '音樂風格'),
  _BulkFieldSpec(key: 'composer', label: '作曲家'),
  _BulkFieldSpec(key: 'isrc', label: 'ISRC 編號'),
];

/// Opens the Frosted Glass non-destructive Tri-State Bulk Editor dialog.
///
/// Returns the [BulkEditResult] when changes or a revert are applied, or `null`
/// if cancelled.
Future<BulkEditResult?> showBulkEditDialog({
  required BuildContext context,
  required AudioService audioService,
  required BulkEditEntityType entityType,
  required List<String> entityIds,
  String? title,
}) {
  return showDialog<BulkEditResult>(
    context: context,
    barrierColor: LuminaTokens.scrimBg,
    builder: (_) => BulkEditDialog(
      audioService: audioService,
      entityType: entityType,
      entityIds: entityIds,
      title: title,
    ),
  );
}

/// Frosted Glass dialog for non-destructive tri-state bulk editing of albums
/// or tracks with strict `<Mixed>` field protection.
class BulkEditDialog extends StatefulWidget {
  final AudioService audioService;
  final BulkEditEntityType entityType;
  final List<String> entityIds;
  final String? title;

  const BulkEditDialog({
    super.key,
    required this.audioService,
    required this.entityType,
    required this.entityIds,
    this.title,
  });

  @override
  State<BulkEditDialog> createState() => _BulkEditDialogState();
}

class _BulkEditDialogState extends State<BulkEditDialog> {
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};
  final Map<String, String> _initialTexts = <String, String>{};
  final Map<String, _BulkFieldEditMode> _fieldModes =
      <String, _BulkFieldEditMode>{};
  final Map<String, bool?> _initialTagStates = <String, bool?>{};
  final Map<String, bool?> _currentTagStates = <String, bool?>{};

  BulkEditSummary? _summary;
  String? _selectedMetaPolicy; // null = keep unchanged
  bool _loading = true;
  bool _submitting = false;
  String? _errorMessage;

  List<_BulkFieldSpec> get _fieldSpecs =>
      widget.entityType == BulkEditEntityType.album
      ? _kAlbumBulkFieldSpecs
      : _kTrackBulkFieldSpecs;

  @override
  void initState() {
    super.initState();
    for (final spec in _fieldSpecs) {
      _controllers[spec.key] = TextEditingController();
      _fieldModes[spec.key] = _BulkFieldEditMode.untouched;
    }
    _loadSummary();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _setState(VoidCallback fn) => setState(fn);

  Future<void> _loadSummary() async {
    try {
      final summary = await widget.audioService.getBulkEditSummary(
        widget.entityType,
        widget.entityIds,
      );
      if (!mounted) return;
      if (summary == null) {
        setState(() {
          _errorMessage = '無法載入批量編輯摘要';
          _loading = false;
        });
        return;
      }
      setState(() {
        _summary = summary;
        for (final spec in _fieldSpecs) {
          final tri = summary.fields[spec.key] ?? const TriStateEmpty<Object?>();
          final initText = switch (tri) {
            TriStateCommon<Object?>(:final value) => value?.toString() ?? '',
            _ => '',
          };
          _initialTexts[spec.key] = initText;
          _controllers[spec.key]!.text = initText;
          _fieldModes[spec.key] = _BulkFieldEditMode.untouched;
        }
        _initialTagStates.clear();
        _currentTagStates.clear();
        for (final tag in summary.tags) {
          final triBool = switch (tag.state) {
            TagSelectionState.none => false,
            TagSelectionState.some => null,
            TagSelectionState.all => true,
          };
          _initialTagStates[tag.tagId] = triBool;
          _currentTagStates[tag.tagId] = triBool;
        }
        _selectedMetaPolicy = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '載入摘要失敗：$e';
        _loading = false;
      });
    }
  }

  TriStateFieldValue<Object?> _triStateFor(String fieldKey) =>
      _summary?.fields[fieldKey] ?? const TriStateEmpty<Object?>();

  void _onFieldTextChanged(String key, String rawText) {
    final tri = _triStateFor(key);
    final initial = _initialTexts[key] ?? '';
    final trimmed = rawText.trim();

    setState(() {
      _errorMessage = null;
      if (tri is TriStateMixed<Object?>) {
        // Strict <Mixed> protection: erasing input reverts to untouched so
        // <Mixed> values are NEVER accidentally cleared.
        _fieldModes[key] = trimmed.isEmpty
            ? _BulkFieldEditMode.untouched
            : _BulkFieldEditMode.setValue;
      } else if (tri is TriStateEmpty<Object?>) {
        _fieldModes[key] = trimmed.isEmpty
            ? _BulkFieldEditMode.untouched
            : _BulkFieldEditMode.setValue;
      } else {
        if (rawText == initial) {
          _fieldModes[key] = _BulkFieldEditMode.untouched;
        } else if (trimmed.isEmpty) {
          _fieldModes[key] = _BulkFieldEditMode.clear;
        } else {
          _fieldModes[key] = _BulkFieldEditMode.setValue;
        }
      }
    });
  }

  void _toggleClearField(String key) {
    setState(() {
      _errorMessage = null;
      if (_fieldModes[key] == _BulkFieldEditMode.clear) {
        _fieldModes[key] = _BulkFieldEditMode.untouched;
        _controllers[key]!.text = _initialTexts[key] ?? '';
      } else {
        _fieldModes[key] = _BulkFieldEditMode.clear;
        _controllers[key]!.clear();
      }
    });
  }

  void _onTagCheckboxChanged(String tagId, bool? next) {
    final init = _initialTagStates[tagId];
    setState(() {
      if (init != null && next == null) {
        // Tags that were not originally mixed toggle cleanly between false/true.
        _currentTagStates[tagId] = false;
      } else {
        _currentTagStates[tagId] = next;
      }
    });
  }

  bool get _hasPendingChanges {
    if (_selectedMetaPolicy != null) return true;
    if (_fieldModes.values.any((m) => m != _BulkFieldEditMode.untouched)) {
      return true;
    }
    for (final entry in _currentTagStates.entries) {
      if (entry.value != _initialTagStates[entry.key]) return true;
    }
    return false;
  }

  BulkEditPatch? _buildPatchOrError() {
    final fields = <String, FieldPatchOp<Object?>>{};
    for (final spec in _fieldSpecs) {
      final mode = _fieldModes[spec.key] ?? _BulkFieldEditMode.untouched;
      switch (mode) {
        case _BulkFieldEditMode.untouched:
          // Never emit untouched fields so <Mixed> values are 100% preserved.
          break;
        case _BulkFieldEditMode.clear:
          fields[spec.key] = const FieldPatchClear<Object?>();
        case _BulkFieldEditMode.setValue:
          final text = _controllers[spec.key]!.text.trim();
          if (spec.isInt) {
            final parsed = int.tryParse(text);
            if (parsed == null) {
              setState(() => _errorMessage = '「${spec.label}」必須輸入有效的整數');
              return null;
            }
            fields[spec.key] = FieldPatchSet<Object?>(parsed);
          } else {
            fields[spec.key] = FieldPatchSet<Object?>(text);
          }
      }
    }

    final metaPolicyOp = _selectedMetaPolicy == null
        ? const FieldPatchKeep<String>()
        : FieldPatchSet<String>(_selectedMetaPolicy!);

    final addTags = <String>[];
    final removeTags = <String>[];
    for (final entry in _currentTagStates.entries) {
      final init = _initialTagStates[entry.key];
      if (entry.value == init) continue;
      if (entry.value == true) {
        addTags.add(entry.key);
      } else if (entry.value == false) {
        removeTags.add(entry.key);
      }
    }

    return BulkEditPatch(
      fields: fields,
      metaPolicy: metaPolicyOp,
      addTagIds: addTags,
      removeTagIds: removeTags,
    );
  }

  Future<void> _submitPatch() async {
    if (_submitting || _loading) return;
    final patch = _buildPatchOrError();
    if (patch == null) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final result = await widget.audioService.applyBulkEdit(
        widget.entityType,
        widget.entityIds,
        patch,
      );
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _errorMessage = '套用批量編輯失敗';
          _submitting = false;
        });
        return;
      }
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '套用批量編輯失敗：$e';
        _submitting = false;
      });
    }
  }

  Future<void> _confirmAndRevertToFileMeta() async {
    if (_submitting || _loading) return;
    final count = _summary?.selectedCount ?? widget.entityIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (ctx) => _buildRevertConfirmDialog(ctx, count),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final result = await widget.audioService.applyBulkEdit(
        widget.entityType,
        widget.entityIds,
        const BulkEditPatch(revertToFileMeta: true),
      );
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _errorMessage = '還原原始檔案標籤失敗';
          _submitting = false;
        });
        return;
      }
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '還原原始檔案標籤失敗：$e';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => _buildDialog(context);
}
