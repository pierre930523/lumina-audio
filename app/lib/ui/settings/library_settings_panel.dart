import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/ingestion_models.dart';
import '../../services/album_layout_settings_controller.dart';
import '../../services/audio_service.dart';
import '../../services/library_settings_controller.dart';
import '../theme/lumina_tokens.dart';
import 'library_album_visibility_card.dart';
import 'library_backup_card.dart';
import 'library_cleanup_card.dart';
import 'library_metadata_policy_card.dart';
import 'settings_widgets.dart';

part 'library_settings_folders_card.dart';
part 'library_settings_analysis_card.dart';
part 'library_settings_quarantine_widgets.dart';

class LibrarySettingsPanel extends StatefulWidget {
  final AudioService audioService;
  final LibrarySettingsController settingsController;
  final AlbumLayoutSettingsController? albumLayoutController;
  final VoidCallback? onLibraryChanged;

  const LibrarySettingsPanel({
    super.key,
    required this.audioService,
    required this.settingsController,
    this.albumLayoutController,
    this.onLibraryChanged,
  });

  /// Normalizes local/NAS folder paths for cross-platform lookup against
  /// Rust's forward-slash canonical `root_path` keys (handles Windows `\` vs `/`,
  /// trailing separators, and case-insensitivity).
  static String normalizeFolderPathKey(String rawPath) {
    var normalized = rawPath.trim().replaceAll('\\', '/');
    while (normalized.length > 1 &&
        normalized.endsWith('/') &&
        !(normalized.length == 3 && normalized[1] == ':')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized.toLowerCase();
  }

  @override
  State<LibrarySettingsPanel> createState() => _LibrarySettingsPanelState();
}

class _LibrarySettingsPanelState extends State<LibrarySettingsPanel> {
  static const _dividerColor = LuminaTokens.glassCardDivider;

  final TextEditingController _scanController = TextEditingController();
  late Set<String> _draftExcluded;
  bool _isScanning = false;
  String? _scanStatus;
  String? _actionStatus;
  final ValueNotifier<ScanProgressEvent?> _scanProgressNotifier =
      ValueNotifier<ScanProgressEvent?>(null);
  Timer? _progressThrottleTimer;
  ScanProgressEvent? _pendingThrottledProgress;
  DateTime? _lastProgressNotifiedAt;
  final Map<String, Completer<ScanProgressEvent?>> _activeScanCompleters =
      <String, Completer<ScanProgressEvent?>>{};
  final Map<String, ScanProgressEvent> _terminalScanEvents =
      <String, ScanProgressEvent>{};
  final Set<String> _handledCompletedScanIds = <String>{};
  StreamSubscription<ScanProgressEvent>? _scanProgressSub;
  Map<String, WatchedRootRecord> _watchedRootsByPath =
      const <String, WatchedRootRecord>{};
  List<SkippedFileRecord> _skippedFiles = const <SkippedFileRecord>[];
  bool _loadingSkipped = false;
  bool _rescanningSkipped = false;

  void _updateState(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    _draftExcluded = Set<String>.from(
      widget.settingsController.excludedExtensions,
    );
    _scanProgressSub = widget.audioService.scanProgressStream.listen(
      _onScanProgressEvent,
    );
    unawaited(_refreshIngestionState());
  }

  @override
  void dispose() {
    _progressThrottleTimer?.cancel();
    _progressThrottleTimer = null;
    _scanProgressSub?.cancel();
    _scanProgressSub = null;
    for (final c in _activeScanCompleters.values) {
      if (!c.isCompleted) {
        c.complete(null);
      }
    }
    _activeScanCompleters.clear();
    _terminalScanEvents.clear();
    _scanProgressNotifier.dispose();
    _scanController.dispose();
    super.dispose();
  }

  void _onScanProgressEvent(ScanProgressEvent event) {
    if (!mounted) return;
    final isTerminal = event.state == ScanLifecycleState.completed ||
        event.state == ScanLifecycleState.failed;
    if (isTerminal) {
      _progressThrottleTimer?.cancel();
      _progressThrottleTimer = null;
      _pendingThrottledProgress = null;
      _scanProgressNotifier.value = event;
      _lastProgressNotifiedAt = DateTime.now();

      final sid = event.scanId.trim();
      if (sid.isNotEmpty) {
        final completer = _activeScanCompleters.remove(sid);
        if (completer != null && !completer.isCompleted) {
          completer.complete(event);
        } else {
          if (_terminalScanEvents.length >= 64) {
            _terminalScanEvents.remove(_terminalScanEvents.keys.first);
          }
          _terminalScanEvents[sid] = event;
        }
      }

      if (event.state == ScanLifecycleState.completed) {
        final shouldNotify = sid.isEmpty || _handledCompletedScanIds.add(sid);
        if (_handledCompletedScanIds.length > 64) {
          _handledCompletedScanIds.remove(_handledCompletedScanIds.first);
        }
        if (shouldNotify) {
          widget.onLibraryChanged?.call();
          unawaited(_refreshIngestionState());
        }
      }
      return;
    }

    const throttleWindow = Duration(milliseconds: 200);
    final lastAt = _lastProgressNotifiedAt;
    if (lastAt == null) {
      _scanProgressNotifier.value = event;
      _lastProgressNotifiedAt = DateTime.now();
      return;
    }
    final elapsed = DateTime.now().difference(lastAt);
    if (elapsed >= throttleWindow) {
      _progressThrottleTimer?.cancel();
      _progressThrottleTimer = null;
      _pendingThrottledProgress = null;
      _scanProgressNotifier.value = event;
      _lastProgressNotifiedAt = DateTime.now();
      return;
    }
    _pendingThrottledProgress = event;
    _progressThrottleTimer ??= Timer(throttleWindow - elapsed, () {
      _progressThrottleTimer = null;
      if (!mounted) return;
      final pending = _pendingThrottledProgress;
      _pendingThrottledProgress = null;
      if (pending != null) {
        _scanProgressNotifier.value = pending;
        _lastProgressNotifiedAt = DateTime.now();
      }
    });
  }

  Future<ScanProgressEvent?> _waitForScanCompletion(String scanId) {
    final existing = _terminalScanEvents.remove(scanId);
    if (existing != null) {
      return Future<ScanProgressEvent?>.value(existing);
    }
    final completer = _activeScanCompleters.putIfAbsent(
      scanId,
      () => Completer<ScanProgressEvent?>(),
    );
    return completer.future;
  }

  Future<void> _refreshIngestionState() async {
    await Future.wait(<Future<void>>[
      _loadWatchedRoots(),
      _loadSkippedFiles(),
    ]);
  }

  Future<void> _loadWatchedRoots() async {
    try {
      final roots = await widget.audioService.listWatchedRoots();
      if (!mounted) return;
      setState(() {
        _watchedRootsByPath = <String, WatchedRootRecord>{
          for (final r in roots)
            LibrarySettingsPanel.normalizeFolderPathKey(r.rootPath): r,
        };
      });
    } catch (_) {}
  }

  Future<void> _loadSkippedFiles() async {
    if (!mounted) return;
    setState(() => _loadingSkipped = true);
    try {
      final skipped = await widget.audioService.getSkippedFiles();
      if (!mounted) return;
      setState(() {
        _skippedFiles = skipped;
      });
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _loadingSkipped = false);
      }
    }
  }

  Future<void> _scanPath(String rawPath) async {
    final path = rawPath.trim();
    if (path.isEmpty) return;
    setState(() => _isScanning = true);
    try {
      final mode = LibrarySettingsController.inferWatchModeForPath(path);
      final watched = await widget.audioService.addWatchedRoot(
        path,
        watchMode: mode,
      );
      if (!mounted) return;
      if (watched != null) {
        setState(() {
          _watchedRootsByPath = <String, WatchedRootRecord>{
            ..._watchedRootsByPath,
            LibrarySettingsPanel.normalizeFolderPathKey(watched.rootPath):
                watched,
          };
        });
      }
      final scanId = await widget.audioService.startDirectoryScan(path);
      if (!mounted) return;
      if (scanId != null && scanId.isNotEmpty) {
        final terminal = await _waitForScanCompletion(scanId);
        if (!mounted) return;
        if (terminal != null && terminal.state == ScanLifecycleState.failed) {
          setState(() {
            _scanStatus = '掃描「$path」失敗：${terminal.message ?? '未知錯誤'}';
          });
        } else {
          final count = terminal != null
              ? (terminal.added + terminal.updated + terminal.unchanged)
              : widget.audioService.libraryTracks.length;
          widget.settingsController.addOrUpdateFolder(path, count);
          setState(() {
            _scanStatus = '已掃描「$path」，收錄 $count 首曲目';
          });
        }
      } else {
        final count = widget.audioService.libraryTracks.length;
        widget.settingsController.addOrUpdateFolder(path, count);
        widget.onLibraryChanged?.call();
        await _refreshIngestionState();
        if (!mounted) return;
        setState(() {
          _scanStatus = '已掃描「$path」，收錄 $count 首曲目';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  Future<void> _handleDismissSkipped(SkippedFileRecord item) async {
    final ok = await widget.audioService.dismissSkippedFile(item.id);
    if (!mounted) return;
    await _loadSkippedFiles();
    if (!mounted) return;
    setState(() {
      _actionStatus = ok
          ? '已忽略隔離檔案「${item.filePath}」'
          : '無法忽略隔離檔案「${item.filePath}」';
    });
  }

  Future<void> _handleRetrySkipped(SkippedFileRecord item) async {
    final res = await widget.audioService.retrySkippedFile(item.id);
    if (!mounted) return;
    await _loadSkippedFiles();
    if (res['status'] == 'imported') {
      widget.onLibraryChanged?.call();
    }
    if (!mounted) return;
    final detail = res['detail']?.toString() ?? '';
    setState(() {
      _actionStatus = res['status'] == 'imported'
          ? '已重新匯入「${item.filePath}」'
          : '重試結果（${res['status'] ?? 'unknown'}）${detail.isNotEmpty ? '：$detail' : ''}';
    });
  }

  Future<void> _pickAndFillFolder() async {
    final chosen = await widget.settingsController.pickFolderNative();
    if (!mounted || chosen == null || chosen.isEmpty) return;
    _scanController.text = chosen;
    await _scanPath(chosen);
  }

  Future<void> _rescanAllFolders() async {
    final folders = List.of(widget.settingsController.folders);
    if (folders.isEmpty) return;
    setState(() => _isScanning = true);
    try {
      var latestCount = 0;
      var usedFallbackSync = false;
      for (final f in folders) {
        final scanId = await widget.audioService.startDirectoryScan(
          f.path,
          force: true,
        );
        if (!mounted) return;
        if (scanId != null && scanId.isNotEmpty) {
          final terminal = await _waitForScanCompletion(scanId);
          if (!mounted) return;
          if (terminal != null &&
              terminal.state == ScanLifecycleState.completed) {
            latestCount =
                terminal.added + terminal.updated + terminal.unchanged;
            widget.settingsController.addOrUpdateFolder(f.path, latestCount);
          }
        } else {
          usedFallbackSync = true;
          latestCount = widget.audioService.libraryTracks.length;
          widget.settingsController.addOrUpdateFolder(f.path, latestCount);
        }
      }
      if (usedFallbackSync) {
        widget.onLibraryChanged?.call();
        await _refreshIngestionState();
      }
      if (!mounted) return;
      setState(() {
        _scanStatus = '已完成全部 ${folders.length} 個資料夾重新掃描（共 $latestCount 首）';
      });
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  Future<void> _rescanTags() async {
    setState(() => _isScanning = true);
    try {
      final scanId = await widget.audioService.startTagRescan(force: true);
      if (!mounted) return;
      if (scanId.isNotEmpty) {
        final terminal = await _waitForScanCompletion(scanId);
        if (!mounted) return;
        if (terminal != null && terminal.state == ScanLifecycleState.failed) {
          setState(() {
            _actionStatus = '標籤中繼資料重新掃描失敗：${terminal.message ?? '未知錯誤'}';
          });
        } else {
          final count = terminal != null
              ? (terminal.updated > 0 ? terminal.updated : terminal.scanned)
              : '全部';
          setState(() {
            _actionStatus = '已完成標籤中繼資料重新掃描（更新 $count 筆）';
          });
        }
      } else {
        widget.onLibraryChanged?.call();
        unawaited(_refreshIngestionState());
        setState(() {
          _actionStatus = '已完成標籤中繼資料重新掃描（更新 全部 筆）';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  Future<void> _forceRebuildLibrary() async {
    setState(() => _isScanning = true);
    try {
      final res = await widget.audioService.forceRebuildLibrary();
      if (!mounted) return;
      final scanId = res['scan_id']?.toString().trim() ?? '';
      if (scanId.isNotEmpty) {
        final terminal = await _waitForScanCompletion(scanId);
        if (!mounted) return;
        if (terminal != null && terminal.state == ScanLifecycleState.failed) {
          setState(() {
            _actionStatus = '強制全庫重掃與修復失敗：${terminal.message ?? '未知錯誤'}';
          });
        } else {
          final count = terminal != null
              ? (terminal.added + terminal.updated + terminal.unchanged)
              : widget.audioService.libraryTracks.length;
          setState(() {
            _actionStatus = '已完成強制全庫重掃與修復（處理 $count 首曲目）';
          });
        }
      } else {
        widget.onLibraryChanged?.call();
        unawaited(_refreshIngestionState());
        setState(() {
          _actionStatus = '已完成強制全庫重掃與修復';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  bool get _hasExcludedChanges {
    final saved = widget.settingsController.excludedExtensions;
    if (saved.length != _draftExcluded.length) return true;
    return !saved.containsAll(_draftExcluded);
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.settingsController;
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final folders = ctrl.folders;
        return SettingsScrollBody(
          panelKey: const Key('library_settings_panel'),
          maxWidth: 780,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_actionStatus != null) ...[
                  _buildStatusBanner(_actionStatus!),
                  const SizedBox(height: LuminaTokens.spaceSm),
                ],
                _buildFoldersAndScanCard(ctrl, folders),
                const SizedBox(height: LuminaTokens.spaceMd),
                LibraryMetadataPolicyCard(
                  audioService: widget.audioService,
                  onLibraryChanged: widget.onLibraryChanged,
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                LibraryAlbumVisibilityCard(
                  albumLayoutController: widget.albumLayoutController,
                  onLibraryChanged: widget.onLibraryChanged,
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                _buildImportSettingsCard(ctrl),
                const SizedBox(height: LuminaTokens.spaceMd),
                _buildPlaybackCacheCard(ctrl),
                const SizedBox(height: LuminaTokens.spaceMd),
                _buildDuplicateCleanupCard(),
                const SizedBox(height: LuminaTokens.spaceMd),
                LibraryCleanupCard(
                  audioService: widget.audioService,
                  onLibraryChanged: widget.onLibraryChanged,
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                LibraryBackupCard(
                  audioService: widget.audioService,
                  onLibraryChanged: widget.onLibraryChanged,
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                _buildScanAndAnalysisCard(ctrl),
                const SizedBox(height: LuminaTokens.spaceMd),
                _buildSkippedFilesCard(),
              ],
            ),
          );
      },
    );
  }
}
