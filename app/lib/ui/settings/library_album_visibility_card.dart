import 'package:material_ui/material_ui.dart';

import '../../services/album_layout_settings_controller.dart';
import 'settings_widgets.dart';

/// Settings card exposing the Step 2 "Show Hidden & Duplicate Versions" toggle,
/// synchronized with [AlbumLayoutSettingsController] and refreshing the library.
class LibraryAlbumVisibilityCard extends StatefulWidget {
  final AlbumLayoutSettingsController? albumLayoutController;
  final VoidCallback? onLibraryChanged;

  const LibraryAlbumVisibilityCard({
    super.key,
    this.albumLayoutController,
    this.onLibraryChanged,
  });

  @override
  State<LibraryAlbumVisibilityCard> createState() =>
      _LibraryAlbumVisibilityCardState();
}

class _LibraryAlbumVisibilityCardState
    extends State<LibraryAlbumVisibilityCard> {
  bool _localShowHidden = false;

  void _handleToggle(bool next) {
    final ctrl = widget.albumLayoutController;
    if (ctrl != null) {
      ctrl.setShowHiddenAlbums(next);
    } else {
      setState(() => _localShowHidden = next);
    }
    widget.onLibraryChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.albumLayoutController;
    if (ctrl == null) {
      return _buildCard(_localShowHidden);
    }
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) => _buildCard(ctrl.showHiddenAlbums),
    );
  }

  Widget _buildCard(bool value) {
    return SettingsGroupCard(
      key: const Key('library_album_visibility_section'),
      title: '隱藏項目與版本顯示',
      description: '控制曲庫、專輯列表、Focus 與資料夾是否顯示已隱藏的曲目或次要重複版本。',
      children: [
        SettingsSwitchRow(
          key: const Key('switch_settings_show_hidden_albums'),
          title: '顯示隱藏項目',
          subtitle:
              '開啟後將一併顯示已隱藏的曲目、副版本與重複版本，方便透過右鍵或「...」選單管理或取消隱藏。',
          value: value,
          onChanged: _handleToggle,
        ),
      ],
    );
  }
}
