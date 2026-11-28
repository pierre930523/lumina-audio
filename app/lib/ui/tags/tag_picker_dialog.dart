import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';

part 'tag_picker_dialog_content.dart';

/// Curated WCAG-friendly tag color swatches for Liquid Glass dark surfaces.
const List<String> kLuminaTagColorSwatches = <String>[
  '#7B92F8',
  '#A855F7',
  '#E5C158',
  '#34D399',
  '#F87171',
  '#38BDF8',
  '#FB923C',
  '#F472B6',
];

/// Parses a `#RRGGBB` or `#AARRGGBB` hex color string safely.
Color parseLuminaTagColor(
  String? hex, {
  Color fallback = LuminaTokens.accentBlue,
}) {
  if (hex == null) return fallback;
  final cleaned = hex.trim().replaceFirst('#', '');
  if (cleaned.length == 6) {
    final parsed = int.tryParse('FF$cleaned', radix: 16);
    if (parsed != null) return Color(parsed);
  } else if (cleaned.length == 8) {
    final parsed = int.tryParse(cleaned, radix: 16);
    if (parsed != null) return Color(parsed);
  }
  return fallback;
}

/// Opens the Liquid Glass Quick Tag Picker dialog for one or more entities.
///
/// Returns `true` if tags were created or assignments were modified.
Future<bool> showTagPickerDialog({
  required BuildContext context,
  required AudioService audioService,
  required TagEntityType entityType,
  required List<String> entityIds,
  String? title,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierColor: LuminaTokens.scrimBg,
    builder: (_) => _TagPickerDialog(
      audioService: audioService,
      entityType: entityType,
      entityIds: entityIds,
      title: title,
    ),
  );
  return result == true;
}

class _TagPickerDialog extends StatefulWidget {
  final AudioService audioService;
  final TagEntityType entityType;
  final List<String> entityIds;
  final String? title;

  const _TagPickerDialog({
    required this.audioService,
    required this.entityType,
    required this.entityIds,
    this.title,
  });

  @override
  State<_TagPickerDialog> createState() => _TagPickerDialogState();
}

class _TagPickerDialogState extends State<_TagPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  List<TagSummary> _allTags = const <TagSummary>[];
  final Set<String> _initialSelectedIds = <String>{};
  final Set<String> _selectedIds = <String>{};
  String _selectedNewColor = kLuminaTagColorSwatches.first;
  bool _loading = true;
  bool _submitting = false;
  bool _createdAny = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _setState(VoidCallback fn) => setState(fn);

  Future<void> _loadTags() async {
    try {
      final tags = await widget.audioService.listTags();
      final existing = widget.entityIds.length == 1
          ? await widget.audioService.getEntityTags(
              widget.entityType,
              widget.entityIds.first,
            )
          : const <TagSummary>[];
      if (!mounted) return;
      setState(() {
        _allTags = tags;
        _initialSelectedIds
          ..clear()
          ..addAll(existing.map((t) => t.id));
        _selectedIds
          ..clear()
          ..addAll(_initialSelectedIds);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '載入標籤失敗：$e';
        _loading = false;
      });
    }
  }

  String get _query => _searchController.text.trim();

  bool get _hasExactMatch {
    final norm = _query.toLowerCase();
    if (norm.isEmpty) return true;
    return _allTags.any((t) => t.name.trim().toLowerCase() == norm);
  }

  List<TagSummary> get _filteredTags {
    final norm = _query.toLowerCase();
    if (norm.isEmpty) return _allTags;
    return _allTags
        .where((t) => t.name.toLowerCase().contains(norm))
        .toList(growable: false);
  }

  Future<void> _createAndSelectTag() async {
    final name = _query;
    if (name.isEmpty || _hasExactMatch || _submitting) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final created = await widget.audioService.createTag(
        CreateTagRequest(name: name, color: _selectedNewColor),
      );
      if (!mounted) return;
      if (created == null) {
        setState(() {
          _errorMessage = '建立標籤「$name」失敗（名稱可能已存在）';
          _submitting = false;
        });
        return;
      }
      setState(() {
        _allTags = <TagSummary>[..._allTags, created]
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
        _selectedIds.add(created.id);
        _createdAny = true;
        _searchController.clear();
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '建立標籤失敗：$e';
        _submitting = false;
      });
    }
  }

  Future<void> _applyChanges() async {
    if (_submitting || widget.entityIds.isEmpty) {
      if (mounted) Navigator.of(context).pop(_createdAny);
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final toAdd = widget.entityIds.length == 1
          ? _selectedIds.difference(_initialSelectedIds).toList(growable: false)
          : _selectedIds.toList(growable: false);
      final toRemove = widget.entityIds.length == 1
          ? _initialSelectedIds.difference(_selectedIds).toList(growable: false)
          : const <String>[];

      var modified = _createdAny;
      if (toAdd.isNotEmpty) {
        await widget.audioService.batchTagItems(
          BatchTagItemsRequest(
            tagIds: toAdd,
            entityType: widget.entityType,
            entityIds: widget.entityIds,
            op: TagBatchOp.add,
          ),
        );
        modified = true;
      }
      if (toRemove.isNotEmpty) {
        await widget.audioService.batchTagItems(
          BatchTagItemsRequest(
            tagIds: toRemove,
            entityType: widget.entityType,
            entityIds: widget.entityIds,
            op: TagBatchOp.remove,
          ),
        );
        modified = true;
      }
      if (!mounted) return;
      Navigator.of(context).pop(modified);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '更新標籤失敗：$e';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => _buildDialog(context);
}
