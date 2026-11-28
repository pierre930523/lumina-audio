import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';
import 'tag_editor_dialog.dart';
import 'tag_picker_dialog.dart';

part 'tags_view_row.dart';

class _TagTreeRow {
  final TagSummary tag;
  final int depth;

  const _TagTreeRow({required this.tag, required this.depth});
}

/// Hierarchical Custom Nested Tags management & navigation view.
class TagsView extends StatefulWidget {
  final AudioService audioService;
  final String? initialTagId;
  final void Function(FocusQuery query)? onOpenFocusQuery;

  const TagsView({
    super.key,
    required this.audioService,
    this.initialTagId,
    this.onOpenFocusQuery,
  });

  @override
  State<TagsView> createState() => _TagsViewState();
}

class _TagsViewState extends State<TagsView> {
  final TextEditingController _searchController = TextEditingController();
  final GlideScrollController _scrollController = GlideScrollController();
  final Set<String> _collapsedTagIds = <String>{};
  List<TagSummary> _tags = const <TagSummary>[];
  bool _loading = true;
  String? _statusMessage;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _setState(VoidCallback fn) => setState(fn);

  Future<void> _loadTags() async {
    try {
      final list = await widget.audioService.listTags();
      if (!mounted) return;
      setState(() {
        _tags = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '無法載入標籤列表：$e';
        _loading = false;
      });
    }
  }

  Map<String, TagSummary> get _tagsById => <String, TagSummary>{
    for (final t in _tags) t.id: t,
  };

  List<_TagTreeRow> _buildVisibleRows() {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      return _tags
          .where((t) => t.name.toLowerCase().contains(query))
          .map((t) => _TagTreeRow(tag: t, depth: 0))
          .toList(growable: false);
    }

    final byId = _tagsById;
    final rows = <_TagTreeRow>[];
    final visitedInBranch = <String>{};

    void visit(TagSummary tag, int depth) {
      rows.add(_TagTreeRow(tag: tag, depth: depth));
      if (_collapsedTagIds.contains(tag.id)) return;
      if (!visitedInBranch.add(tag.id)) return;
      final children = tag.childIds
          .map((id) => byId[id])
          .whereType<TagSummary>()
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      for (final child in children) {
        if (!visitedInBranch.contains(child.id)) {
          visit(child, depth + 1);
        }
      }
      visitedInBranch.remove(tag.id);
    }

    final roots = _tags.where((t) => t.parentIds.isEmpty).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final placed = <String>{};
    for (final root in roots) {
      visit(root, 0);
      placed.add(root.id);
    }
    for (final t in _tags) {
      if (!rows.any((r) => r.tag.id == t.id) && !placed.contains(t.id)) {
        visit(t, 0);
      }
    }
    return rows;
  }

  void _openTagFocus(TagSummary tag, FocusEntity entity) {
    widget.onOpenFocusQuery?.call(
      FocusQuery(
        entity: entity,
        predicates: <FocusPredicate>[
          FocusPredicate(
            facet: FocusFacet.tag,
            value: FocusStringValue(tag.id),
            mode: FocusPredicateMode.include,
          ),
        ],
      ),
    );
  }

  Future<void> _handleCreateTag() async {
    final res = await showTagEditorDialog(context: context);
    if (res == null || !mounted) return;
    setState(() {
      _errorMessage = null;
      _statusMessage = null;
    });
    final created = await widget.audioService.createTag(
      CreateTagRequest(name: res.name, color: res.color),
    );
    if (!mounted) return;
    if (created == null) {
      setState(() => _errorMessage = '建立標籤「${res.name}」失敗（名稱可能重複）');
      return;
    }
    await _loadTags();
    if (!mounted) return;
    setState(() => _statusMessage = '已建立標籤「${created.name}」');
  }

  Future<void> _handleEditTag(TagSummary tag) async {
    final res = await showTagEditorDialog(context: context, existingTag: tag);
    if (res == null || !mounted) return;
    setState(() {
      _errorMessage = null;
      _statusMessage = null;
    });
    final updated = await widget.audioService.updateTag(
      UpdateTagRequest(
        id: tag.id,
        name: res.name,
        color: res.color,
        clearColor: res.clearColor,
      ),
    );
    if (!mounted) return;
    if (updated == null) {
      setState(() => _errorMessage = '更新標籤「${tag.name}」失敗（名稱可能重複）');
      return;
    }
    await _loadTags();
    if (!mounted) return;
    setState(() => _statusMessage = '已更新標籤「${updated.name}」');
  }

  Future<void> _handleDeleteTag(TagSummary tag) async {
    final ok = await showConfirmDeleteTagDialog(context: context, tag: tag);
    if (!ok || !mounted) return;
    setState(() {
      _errorMessage = null;
      _statusMessage = null;
    });
    final deleted = await widget.audioService.deleteTag(tag.id);
    if (!mounted) return;
    if (!deleted) {
      setState(() => _errorMessage = '刪除標籤「${tag.name}」失敗');
      return;
    }
    await _loadTags();
    if (!mounted) return;
    setState(() => _statusMessage = '已刪除標籤「${tag.name}」');
  }

  Future<void> _handleLinkParent(TagSummary childTag) async {
    final parentId = await showLinkParentTagDialog(
      context: context,
      childTag: childTag,
      allTags: _tags,
    );
    if (parentId == null || !mounted) return;
    setState(() {
      _errorMessage = null;
      _statusMessage = null;
    });
    try {
      final linked = await widget.audioService.linkTagParent(
        TagLinkRequest(parentTagId: parentId, childTagId: childTag.id),
      );
      if (!mounted) return;
      if (!linked) {
        setState(
          () => _errorMessage = '無法建立父子連結：偵測到循環參照（不允許形成環狀階層）',
        );
        return;
      }
      await _loadTags();
      if (!mounted) return;
      final parentName = _tagsById[parentId]?.name ?? parentId;
      setState(
        () => _statusMessage = '已將「${childTag.name}」加入「$parentName」子標籤',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = '無法建立父子連結：$e');
    }
  }

  Future<void> _handleUnlinkParent(String parentId, TagSummary childTag) async {
    setState(() {
      _errorMessage = null;
      _statusMessage = null;
    });
    final ok = await widget.audioService.unlinkTagParent(
      TagLinkRequest(parentTagId: parentId, childTagId: childTag.id),
    );
    if (!mounted) return;
    if (!ok) {
      setState(() => _errorMessage = '移除父標籤連結失敗');
      return;
    }
    await _loadTags();
    if (!mounted) return;
    setState(() => _statusMessage = '已解除父標籤連結');
  }

  @override
  Widget build(BuildContext context) => _buildView(context);
}
