import QtQuick
import QtQuick.Controls
import Qt.labs.folderlistmodel
import Qt.labs.platform as Platform
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Widgets
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Services
import qs.Modules.Plugins
import QtQuick.Dialogs
import QtMultimedia
import "./dms-common"
import "./components"

DesktopPluginComponent {
    id: root

    property bool acceptsKeyboardFocus: true
    property bool _previewBusy: false

    layer.enabled: true
    layer.effect: OpacityMask {
        maskSource: Rectangle {
            width: root.width
            height: root.height
            radius: 12
        }
    }


    // Desktop widget dimensions
    minWidth: 200
    minHeight: 200
    
    // Default initial size if not set
    widgetWidth: pluginData.widgetWidth ?? 937
    widgetHeight: pluginData.widgetHeight ?? 503

    // Settings config
    readonly property real backgroundOpacity: (pluginData.backgroundOpacity ?? 0) / 100
    readonly property real borderOpacity: (pluginData.borderOpacity ?? 100) / 100
    readonly property real folderDropdownOpacity: (pluginData.folderDropdownOpacity ?? 95) / 100
    property bool showHidden: pluginData.showHidden ?? false
    property int cellSize: pluginData.cellSize ?? 94
    readonly property double sizeScale: cellSize / 84.0
    readonly property string sortBy: pluginData.sortBy ?? "type"
    readonly property string viewMode: pluginData.viewMode ?? "grid"
    readonly property string headerPosition: pluginData.headerPosition ?? "bottom"
    property bool showHeader: pluginData.showHeader ?? true
    readonly property var pinnedPaths: pluginData.pinnedPaths ?? []
    onPinnedPathsChanged: { updateFilteredModel(); buildFolderDropdownModel(); }

    property var folderDropdownModel: []

    // ── Dropdown drag-to-reorder state ──
    property bool _dropDragActive: false
    property int _dropDragFromIdx: -1
    property int _dropDragToIdx: -1
    property string _dropDragOrderKey: "folderDropdownOrder"

    property var stacks: pluginData.stacks ?? []
    onStacksChanged: updateFilteredModel()
    property var expandedStackIds: []

    // ── Plugin I18n ──────────────────────────────────────────────────────────────
    property string pluginLanguage: pluginData.pluginLanguage ?? "en"
    onPluginLanguageChanged: {
        _applyPluginLanguage(pluginLanguage);
        buildFolderDropdownModel();
    }
    property var _pluginFlatTranslations: ({})
    property bool _pluginI18nReady: false

    // ── Reactive Language Sync ──
    // DesktopPluginComponent binds pluginData = instanceConfig for instances.
    // Global settings changes (e.g. language in FolderViewSettings) update
    // the pluginService store and emit pluginDataChanged, but the instanceConfig
    // reference stays the same → QML does NOT see a change → pluginLanguage
    // never updates → translations never reload.
    //
    // Fix: poll pluginService.loadPluginData() on a timer.  ~800 ms latency
    // on language switch is imperceptible and this bypasses every QML binding /
    // signal wiring issue in one shot.
    Timer {
        id: languageSyncTimer
        interval: 800
        repeat: true
        running: true
        onTriggered: {
            if (!pluginService) return;
            var lang = pluginService.loadPluginData(pluginId, "pluginLanguage", "system");
            if (lang !== pluginLanguage)
                pluginLanguage = lang;
        }
    }

    // Poll mounted drives so hot-plugged USB / newly mounted partitions
    // appear in the folderDropdown without requiring a restart.
    Timer {
        id: drivePollTimer
        interval: 5000
        repeat: true
        running: true
        onTriggered: {
            if (folderDropdown && (folderDropdown.visible || folderDropdown.opened))
                buildFolderDropdownModel();
        }
    }

    // Background lsblk scan for unmounted drive detection
    Timer {
        id: driveScanTimer
        interval: 6000
        repeat: true
        running: true
        onTriggered: { lsblkProc.running = true; }
    }

    // Model arrays that auto-rebuild when translations change (non-readonly so i18n()
    // bindings re-evaluate when _pluginFlatTranslations or I18n.translations change)
    property var _viewModeOptions: [
        { label: i18n("Grid View"), value: "grid", icon: "grid_view" },
        { label: i18n("List View"), value: "list", icon: "view_list" },
        { label: i18n("Compact View"), value: "compact", icon: "view_module" }
    ]
    property var _createNewOptions: [
        { label: i18n("New Folder"), value: "folder", icon: "create_new_folder" },
        { label: i18n("New Document"), value: "file", icon: "note_add" },
        { label: i18n("New App"), value: "app", icon: "add_to_home_screen" }
    ]
    property var _sortOptions: [
        { label: i18n("Sort by Name"), value: "name", icon: "sort_by_alpha" },
        { label: i18n("Sort by Date"), value: "time", icon: "schedule" },
        { label: i18n("Sort by Size"), value: "size", icon: "bar_chart" },
        { label: i18n("Sort by Type"), value: "type", icon: "category" }
    ]
    property var _fileTypeOptions: [
        { label: i18n("All Files"), value: "all", icon: "menu" },
        { label: i18n("Folders Only"), value: "folders", icon: "folder" },
        { label: i18n("Files Only"), value: "files", icon: "description" },
        { label: i18n("Images Only"), value: "images", icon: "image" },
        { label: i18n("Documents Only"), value: "documents", icon: "article" },
        { label: i18n("Audio & Video"), value: "audio_video", icon: "movie" }
    ]
    property var _timeFilterOptions: [
        { label: i18n("Any Time"), value: "all", icon: "schedule" },
        { label: i18n("Last 24 Hours"), value: "today", icon: "today" },
        { label: i18n("Last 7 Days"), value: "week", icon: "date_range" },
        { label: i18n("Last 30 Days"), value: "month", icon: "calendar_month" },
        { label: i18n("Last 365 Days"), value: "year", icon: "history" }
    ]
    property var _headerPositionOptions: [
        { label: i18n("Top"), val: "top" },
        { label: i18n("Bottom"), val: "bottom" }
    ]

    readonly property bool isScrolledDown: viewMode === "grid"
        ? (typeof fileGrid !== "undefined" && fileGrid ? fileGrid.contentY > 50 : false)
        : viewMode === "list"
        ? (typeof fileList !== "undefined" && fileList ? fileList.contentY > 50 : false)
        : viewMode === "compact"
        ? (typeof fileCompact !== "undefined" && fileCompact ? fileCompact.contentY > 50 : false)
        : false

    // Resolved Folder Settings & URL
    property string folderType: pluginData.folderType ?? "home"
    property string customFolderPath: pluginData.customFolderPath ?? ""
    // Set to true when browsing a mounted drive partition (from driveListPopup)
    property bool _isOnDrive: false
    // Current drive info (label, path, icon) for showing drive entry in folderDropdown
    property var _currentDriveInfo: ({})

    readonly property string targetFolderUrl: {
        switch (folderType) {
            case "home":
                return Platform.StandardPaths.writableLocation(Platform.StandardPaths.HomeLocation).toString();
            case "downloads":
                return Platform.StandardPaths.writableLocation(Platform.StandardPaths.DownloadLocation).toString();
            case "music":
                return Platform.StandardPaths.writableLocation(Platform.StandardPaths.MusicLocation).toString();
            case "pictures":
                return Platform.StandardPaths.writableLocation(Platform.StandardPaths.PicturesLocation).toString();
            case "videos":
                return Platform.StandardPaths.writableLocation(Platform.StandardPaths.MoviesLocation).toString();
            case "documents":
                return Platform.StandardPaths.writableLocation(Platform.StandardPaths.DocumentsLocation).toString();
            case "trash":
                return Platform.StandardPaths.writableLocation(Platform.StandardPaths.HomeLocation).toString() + "/.local/share/Trash/files";
            case "custom": {
                if (customFolderPath && customFolderPath.trim() !== "") {
                    const clean = customFolderPath.trim();
                    if (clean.startsWith("~/")) {
                        return Platform.StandardPaths.writableLocation(Platform.StandardPaths.HomeLocation).toString() + clean.substring(1);
                    }
                    return "file://" + clean;
                }
                return Platform.StandardPaths.writableLocation(Platform.StandardPaths.DesktopLocation).toString();
            }
            default:
                return Platform.StandardPaths.writableLocation(Platform.StandardPaths.DesktopLocation).toString();
        }
    }

    property string folderDisplayName: {
        switch (folderType) {
            case "home": {
                var homePath = Platform.StandardPaths.writableLocation(Platform.StandardPaths.HomeLocation).toString();
                // Extract username from the last segment of the home path
                var parts = homePath.split("/");
                return parts[parts.length - 1] || i18n("Home");
            }
            case "desktop": return i18n("Desktop");
            case "downloads": return i18n("Downloads");
            case "music": return i18n("Music");
            case "pictures": return i18n("Pictures");
            case "videos": return i18n("Videos");
            case "documents": return i18n("Documents");
            case "trash": return i18n("Trash");
            case "custom":
                if (customFolderPath) {
                    const parts = customFolderPath.trim().split("/");
                    return parts[parts.length - 1] || i18n("Folder");
                }
                return i18n("Folder");
            default: return i18n("Folder");
        }
    }

    // Sorting field mapper
    readonly property int folderSortField: {
        switch (sortBy) {
            case "time": return FolderListModel.Time;
            case "size": return FolderListModel.Size;
            case "type": return FolderListModel.Type;
            default: return FolderListModel.Name;
        }
    }

    // Selected file tracking
    property var selectedFilePaths: []
    property var selectedPathsSet: ({})
    property string lastSelectedFilePath: ""
    property string searchPattern: ""
    property string selectedFileInfo: ""
    property string emptyColor: pluginData.emptyColor ?? "#00BFA5"
    property string folderColor: pluginData.folderColor ?? "#00BCD4"
    readonly property var favoritePaths: pluginData.favoritePaths ?? []
    onFavoritePathsChanged: buildFolderDropdownModel()

    function toggleFavorite(filePath) {
        if (!pluginService) return;
        var favs = root.favoritePaths.slice();
        var idx = favs.indexOf(filePath);
        if (idx !== -1) favs.splice(idx, 1);
        else favs.push(filePath);
        pluginService.savePluginData(pluginId, "favoritePaths", favs);
    }

    function removeBookmark(filePath) {
        // Remove from in-memory model immediately
        var newModel = [];
        for (var i = 0; i < root.folderDropdownModel.length; i++) {
            var item = root.folderDropdownModel[i];
            if (!(item.value === "bookmark" && item.path === filePath)) {
                newModel.push(item);
            }
        }
        root.folderDropdownModel = newModel;
        // Remove from GTK bookmarks file
        var bookFile = "/home/suruibin/.config/gtk-3.0/bookmarks";
        var encoded = encodeURIComponent(filePath).replace(/%2F/g, "/");
        Quickshell.execDetached(["sed", "-i", "\\|" + encoded + "|d", bookFile]);
    }

    // Inline rename state: file path of the item currently renamed in place
    // ("" when no item is being renamed). _inlineRenameArmPath holds the path
    // queued by inlineRenameArmTimer until it fires.
    property string renamingFilePath: ""
    property string _inlineRenameArmPath: ""

    // Clipboard copy/paste (replaces drag-and-drop)
    property var copiedFilePaths: []
    property bool cutMode: false
    property var _pastePendingOps: []  // Array of {src, dest, isCut, conflict} pending user confirmation
    property bool _pasteOverwriteAll: false

    function _syncToSystemClipboard() {
        if (root.copiedFilePaths.length === 0) return;
        var uris = root.copiedFilePaths.map(function(p) {
            return "file://" + root._cleanPath(p);
        }).join("\n");
        Quickshell.execDetached(["wl-copy", "-t", "text/uri-list", uris]);
    }

    Shortcut {
        sequence: StandardKey.Copy
        onActivated: {
            if (root.selectedFilePaths.length > 0) {
                root.copiedFilePaths = root.selectedFilePaths.slice();
                root.cutMode = false;
                root._syncToSystemClipboard();
            }
        }
    }
    Shortcut {
        sequence: StandardKey.Cut
        onActivated: {
            if (root.selectedFilePaths.length > 0) {
                root.copiedFilePaths = root.selectedFilePaths.slice();
                root.cutMode = true;
                root._syncToSystemClipboard();
            }
        }
    }
    Shortcut {
        sequence: StandardKey.Paste
        onActivated: {
            if (root.copiedFilePaths.length > 0) {
                var dest = root._cleanPath(root.targetFolderUrl);
                var isCut = root.cutMode;
                var ops = [];
                for (var i = 0; i < root.copiedFilePaths.length; i++) {
                    var src = root._cleanPath(root.copiedFilePaths[i]);
                    var name = src.split("/").pop();
                    var srcDir = src.substring(0, src.lastIndexOf("/"));
                    var destPath = dest + "/" + name;
                    if (srcDir === dest) {
                        var base = name.replace(/\.[^.]+$/, "");
                        var ext = name.substring(base.length);
                        destPath = dest + "/" + base + " (copy)" + ext;
                    }
                    if (src === destPath) continue;
                    ops.push({ src: src, dest: destPath, isCut: isCut, conflict: false });
                }
                if (ops.length === 0) return;
                root._checkPasteConflicts(ops);
            } else {
                // No internally copied files — try reading from system clipboard
                root.pasteFromClipboard();
            }
        }
    }
    Shortcut {
        sequence: "Del"
        onActivated: {
            if (root.selectedFilePaths.length > 0) {
                if (root.folderType === "trash") {
                    root.deleteFromTrashPermanently(root.selectedFilePaths[0]);
                } else {
                    var paths = root.selectedFilePaths.slice();
                    root.clearSelection();
                    for (var i = 0; i < paths.length; i++) {
                        Quickshell.execDetached(["gio", "trash", "--", root._cleanPath(paths[i])]);
                    }
                }
            }
        }
    }
    Shortcut {
        sequences: ["F2"]
        onActivated: {
            if (root.selectedFilePaths.length === 1) {
                root.armInlineRename(root.selectedFilePaths[0]);
            }
        }
    }
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: event => {
        // Empty — Space is now handled by a Shortcut so it no longer depends
        // on `keyHandler` having activeFocus. Previously focus drift after popup
        // closes caused Space to silently stop working until a DMS restart.
    }
    // Space preview — Shortcut (focus-independent). Avoid "Space" string form
    // because it conflicts with TextInput/search typing; using Qt.Key_Space via
    // Keys.onPressed was the cause of the focus bug. Keep as Shortcut with the
    // activeFocus guard so search/rename/preview-content typing still get space.
    Shortcut {
        sequences: ["Space"]
        enabled: root.selectedFilePaths.length === 1
                 && !headerSearchField.activeFocus
                 && !previewPopup.opened
                 && !renameDialog.opened
                 && !createDialog.opened
                 && !createAppDialog.opened
                 && !createStackDialog.opened
                 && !overwriteDialog.opened
                 && !infoDialog.opened
                 && !quickMenu.opened
                 && !settingsDropdown.opened
        onActivated: {
            if (root._previewBusy) {
                // Stuck from a previous failed open → clear and retry
                root._previewBusy = false;
            }
            root._previewBusy = true;
            var path = root.selectedFilePaths[0];
            var found = false;
            for (var i = 0; i < filteredModel.count; i++) {
                if (filteredModel.get(i).filePath === path) {
                    if (filteredModel.get(i).fileIsDir) {
                        root._previewBusy = false;
                        return;
                    }
                    previewPopup._currentIndex = i;
                    found = true;
                    break;
                }
            }
            if (!found) {
                root._previewBusy = false;
                return;
            }
            previewPopup.filePath = path;
            previewPopup.open();
        }
    }
    Shortcut {
        sequence: "Ctrl+H"
        onActivated: {
            root.showHidden = !root.showHidden;
            if (root.pluginService)
                root.pluginService.savePluginData(root.pluginId, "showHidden", root.showHidden);
        }
    }
    Shortcut {
        sequence: StandardKey.SelectAll
        onActivated: {
            var arr = [];
            var set = {};
            for (var i = 0; i < filteredModel.count; i++) {
                var fp = filteredModel.get(i).filePath;
                if (fp.startsWith("stack://")) continue;
                arr.push(fp);
                set[fp] = true;
            }
            root.selectedFilePaths = arr;
            root.selectedPathsSet = set;
        }
    }
    Shortcut {
        sequence: "Ctrl+F"
        onActivated: {
            headerSearchContainer.expanded = true;
            headerSearchField.forceActiveFocus();
        }
    }

    function clearSelection() {
        selectedFilePaths = [];
        selectedPathsSet = ({});
        lastSelectedFilePath = "";
    }

    function toggleSelection(filePath) {
        let arr = [];
        for (let i = 0; i < root.selectedFilePaths.length; i++)
            arr.push(root.selectedFilePaths[i]);
        let idx = arr.indexOf(filePath);
        if (idx === -1) {
            arr.push(filePath);
        } else {
            arr.splice(idx, 1);
        }
        let set = ({});
        for (let i = 0; i < arr.length; i++)
            set[arr[i]] = true;
        selectedPathsSet = set;
        selectedFilePaths = arr;
        lastSelectedFilePath = filePath;
        selectionClearTimer.restart();
    }

    function selectSingle(filePath) {
        let set = ({});
        set[filePath] = true;
        selectedPathsSet = set;
        selectedFilePaths = [filePath];
        lastSelectedFilePath = filePath;
        selectionClearTimer.restart();
    }

    function selectRangeTo(currentIndex) {
        if (lastSelectedFilePath === "") {
            if (filteredModel.count > currentIndex) {
                selectSingle(filteredModel.get(currentIndex).filePath);
            }
            return;
        }

        let lastIndex = -1;
        for (let i = 0; i < filteredModel.count; i++) {
            if (filteredModel.get(i).filePath === lastSelectedFilePath) {
                lastIndex = i;
                break;
            }
        }

        if (lastIndex === -1) {
            if (filteredModel.count > currentIndex) {
                selectSingle(filteredModel.get(currentIndex).filePath);
            }
            return;
        }

        let start = Math.min(lastIndex, currentIndex);
        let end = Math.max(lastIndex, currentIndex);
        let newSelection = [];
        for (let i = 0; i < root.selectedFilePaths.length; i++)
            newSelection.push(root.selectedFilePaths[i]);

        let newSet = ({});
        for (let i = 0; i < newSelection.length; i++)
            newSet[newSelection[i]] = true;

        for (let i = start; i <= end; i++) {
            let path = filteredModel.get(i).filePath;
            if (!newSet[path]) {
                newSet[path] = true;
                newSelection.push(path);
            }
        }
        selectedPathsSet = newSet;
        selectedFilePaths = newSelection;
        selectionClearTimer.restart();
    }

    function _cleanPath(url) {
        let path = String(url);
        if (path.startsWith("file://")) {
            path = path.substring(7);
        }
        if (path.startsWith("localhost/")) {
            path = path.substring(9);
        }
        return path;
    }

    // Single source of truth for renaming, shared by the inline editor and the
    // rename dialog. Handles both virtual stacks and on-disk files; the
    // extension is preserved from oldName for files.
    function applyRename(rawPath, oldName, isDir, newBaseName) {
        try {
            const trimmed = String(newBaseName).trim();
            if (trimmed.length === 0)
                return;

            // A slash would turn the rename into a move into another directory
            // (or an invalid path), so reject it.
            if (trimmed.indexOf("/") !== -1) {
                ToastService.showToast(i18n("Rename failed") + ": " + i18n("Name cannot contain slashes"), ToastService.levelError);
                return;
            }

            let newName = trimmed;
            // If user typed a name without extension, re-use old extension
            if (!isDir && trimmed.indexOf(".") === -1) {
                const lastDot = String(oldName).lastIndexOf(".");
                if (lastDot > 0)
                    newName = trimmed + String(oldName).substring(lastDot);
            }
            if (newName === String(oldName))
                return;

            let pathStr = String(rawPath);
            if (pathStr.startsWith("stack://")) {
                root.renameStack(pathStr.substring(8), trimmed);
                return;
            }

            pathStr = root._cleanPath(pathStr);
            if (!pathStr || pathStr.length === 0)
                return;

            const parts = pathStr.split("/");
            parts.pop();
            const newPath = parts.join("/") + "/" + newName;
            Quickshell.execDetached(["mv", pathStr, newPath]);
        } catch (e) {
            ToastService.showToast(i18n("Rename failed") + ": " + e.message, ToastService.levelError);
        }
    }

    function armInlineRename(filePath) {
        root._inlineRenameArmPath = filePath;
        inlineRenameArmTimer.restart();
    }

    // Shared by all three view delegates: a left click on the name label of an
    // item that is already the sole selection arms an inline rename; any other
    // left click just (re)selects the item.
    function handleItemLabelClick(mouseArea, labelItem, mouseX, mouseY, filePath) {
        // Rename is F2-only; click always selects
        root.selectSingle(filePath);
    }

    function isPathInFilteredModel(path) {
        for (let i = 0; i < filteredModel.count; i++) {
            if (filteredModel.get(i).filePath === path)
                return true;
        }
        return false;
    }

    function beginInlineRename(filePath) {
        inlineRenameArmTimer.stop();
        // The item may have vanished during the arm delay (e.g. deleted by
        // another process). Don't enter a rename that no delegate can ever
        // dismiss, which would leave renamingFilePath stuck non-empty.
        if (!isPathInFilteredModel(filePath))
            return;
        root.renamingFilePath = filePath;
    }

    function endInlineRename() {
        inlineRenameArmTimer.stop();
        Qt.callLater(() => { root.renamingFilePath = ""; });
    }

    // Wrapper for file execution — avoids needing Quickshell import in delegates
    function execFile(filePath) {
        let clean = root._cleanPath(filePath);
        if (clean.endsWith(".AppImage") || clean.endsWith(".appimage")) {
            Quickshell.execDetached([clean]);
        } else {
            Quickshell.execDetached(["gio", "open", clean]);
        }
    }

    // Wrapper for rename timer — avoids direct property access from delegates
    function stopRenameArmTimer() { inlineRenameArmTimer.stop(); }
    function restartRenameArmTimer() { inlineRenameArmTimer.restart(); }

    // Wrapper for showing the quick context menu from a delegate
    function showQuickMenu(filePath, fileName, fileIsDir, x, y) {
        if (root.selectedFilePaths.indexOf(filePath) === -1)
            root.selectSingle(filePath);
        quickMenu.currentPath = filePath;
        quickMenu.currentName = fileName;
        quickMenu.currentIsDir = fileIsDir;
        quickMenu.parent = root;
        quickMenu.x = Math.max(0, Math.min(root.width - quickMenu.width, x));
        quickMenu.y = Math.max(0, Math.min(root.height - quickMenu.height, y));
        quickMenu.open();
    }

    // Wrapper for showing the trash action popup from a delegate
    function showTrashActionPopup(filePath, fileName, x, y) {
        if (root.selectedFilePaths.indexOf(filePath) === -1)
            root.selectSingle(filePath);
        trashActionPopup.currentPath = filePath;
        trashActionPopup.currentName = fileName;
        trashActionPopup.parent = root;
        trashActionPopup.x = Math.max(0, Math.min(root.width - trashActionPopup.width, x));
        trashActionPopup.y = Math.max(0, Math.min(root.height - trashActionPopup.height, y));
        trashActionPopup.open();
    }

    // Restore a file from trash back to its original location
    function restoreFromTrash(filePath) {
        var paths = root.selectedFilePaths.length > 0
            ? root.selectedFilePaths.slice()
            : [filePath];
        if (paths.indexOf(filePath) === -1)
            paths.push(filePath);
        for (var ri = 0; ri < paths.length; ri++) {
            var p = paths[ri];
            if (!p || p.startsWith("stack://")) continue;
            var clean = root._cleanPath(p);
            var safePath = clean.replace(/'/g, "'\\''");
            Proc.runCommand("restoreTrash-" + Math.random(), ["sh", "-c",
                "info=\"$HOME/.local/share/Trash/info/$(basename '" + safePath + "').trashinfo\";\n" +
                'orig=$(sed -n \'s/^Path=//p\' "$info" 2>/dev/null);\n' +
                'if [ -z "$orig" ]; then echo "NOINFO"; exit 2; fi;\n' +
                'if [ -e "$orig" ]; then echo "CONFLICT:$orig"; exit 1; fi;\n' +
                "mkdir -p \"$(dirname \"$orig\")\" && mv '" + safePath + "' \"$orig\" && rm -f \"$info\" &&\n" +
                'echo "OK:$orig"'
            ], function(out, code) {
                if (code === 0 && out) {
                    var line = String(out).trim();
                    if (line.startsWith("OK:")) {
                        root.refreshCurrentFolder();
                    }
                } else if (code === 1) {
                    ToastService.showToast(i18n("Cannot restore — file already exists at original location"), ToastService.levelError);
                } else {
                    ToastService.showToast(i18n("Cannot restore — trash info not found"), ToastService.levelError);
                }
            });
        }
    }

    // Permanently delete files from trash
    function deleteFromTrashPermanently(filePath) {
        var paths = root.selectedFilePaths.length > 0
            ? root.selectedFilePaths.slice()
            : [filePath];
        if (paths.indexOf(filePath) === -1)
            paths.push(filePath);
        for (var ri = 0; ri < paths.length; ri++) {
            var p = paths[ri];
            if (!p || p.startsWith("stack://")) continue;
            var clean = root._cleanPath(p);
            var safePath = clean.replace(/'/g, "'\\''");
            Proc.runCommand("permDelete-" + Math.random(), ["sh", "-c",
                "rm -rf '" + safePath + "' && " +
                "rm -f \"$HOME/.local/share/Trash/info/$(basename '" + safePath + "').trashinfo\"" + " && echo OK"
            ], function(out, code) {
                if (code === 0) {
                    ToastService.showToast(i18n("Permanently deleted"), ToastService.levelInfo);
                    root.refreshCurrentFolder();
                } else {
                    ToastService.showToast(i18n("Delete failed"), ToastService.levelError);
                }
            });
        }
    }

    // Refresh the current folder view
    function refreshCurrentFolder() {
        var url = root.targetFolderUrl;
        if (url) {
            folderModel.folder = Qt.resolvedUrl(url);
        }
    }

    function dragMimeData(filePath) {
        // Dragging an item that is part of the current selection drags the
        // whole selection; otherwise just the pressed item.
        let paths = (root.selectedFilePaths.length > 0 && root.selectedFilePaths.indexOf(filePath) !== -1)
            ? root.selectedFilePaths
            : [filePath];
        paths = paths.filter(p => !String(p).startsWith("stack://")).map(p => root._cleanPath(p));
        const uris = paths.map(p => "file://" + p.split("/").map(encodeURIComponent).join("/"));
        return {
            "text/uri-list": uris.join("\r\n") + "\r\n",
            "text/plain": paths.join("\n")
        };
    }

    function launchDesktopFile(path) {
        let cleanPath = root._cleanPath(path);
        let shellCmd = 'cmd=$(grep -m 1 "^Exec=" "' + cleanPath + '" | cut -d= -f2- | sed "s/%[fFuUiIcDkKvV]//g"); exec sh -c "$cmd"';
        Quickshell.execDetached(["sh", "-c", shellCmd]);
    }

    // Folder navigation
    property var folderHistory: []
    property var forwardHistory: []
    function resolveStandardFolderPath(type) {
        switch (type) {
            case "root": return "/";
            case "home": return Platform.StandardPaths.writableLocation(Platform.StandardPaths.HomeLocation).toString();
            case "desktop": return Platform.StandardPaths.writableLocation(Platform.StandardPaths.DesktopLocation).toString();
            case "downloads": return Platform.StandardPaths.writableLocation(Platform.StandardPaths.DownloadLocation).toString();
            case "music": return Platform.StandardPaths.writableLocation(Platform.StandardPaths.MusicLocation).toString();
            case "pictures": return Platform.StandardPaths.writableLocation(Platform.StandardPaths.PicturesLocation).toString();
            case "videos": return Platform.StandardPaths.writableLocation(Platform.StandardPaths.MoviesLocation).toString();
            case "documents": return Platform.StandardPaths.writableLocation(Platform.StandardPaths.DocumentsLocation).toString();
            case "trash": return Platform.StandardPaths.writableLocation(Platform.StandardPaths.HomeLocation).toString() + "/.local/share/Trash/files";
            default: return "";
        }
    }

    function navigateToFolder(folderPath) {
        let cleanPath = root._cleanPath(String(folderPath));
        // Strip trailing slash for clean display name
        if (cleanPath.length > 1 && cleanPath.charAt(cleanPath.length - 1) === '/')
            cleanPath = cleanPath.substring(0, cleanPath.length - 1);
        let current = root.targetFolderUrl;
        let currentClean = root._cleanPath(String(current));
        if (currentClean !== cleanPath) {
            let hist = [];
            for (let i = 0; i < root.folderHistory.length; i++)
                hist.push(root.folderHistory[i]);
            if (hist.length === 0 || hist[hist.length - 1] !== currentClean)
                hist.push(currentClean);
            root.folderHistory = hist;
            root.forwardHistory = [];
        }
        let url = cleanPath.startsWith("file://") ? cleanPath : "file://" + cleanPath;
        folderModel.folder = Qt.resolvedUrl(url);
        if (pluginService) {
            pluginService.savePluginData(pluginId, "customFolderPath", cleanPath);
            pluginService.savePluginData(pluginId, "folderType", "custom");
        }
        root.customFolderPath = cleanPath;
        root.folderType = "custom";
        buildFolderDropdownModel();
    }

    function goBackFolder() {
        let hist = [];
        for (let i = 0; i < root.folderHistory.length; i++)
            hist.push(root.folderHistory[i]);
        if (hist.length > 0) {
            let currentClean = root._cleanPath(String(root.targetFolderUrl));
            let fwd = [];
            for (let i = 0; i < root.forwardHistory.length; i++)
                fwd.push(root.forwardHistory[i]);
            fwd.push(currentClean);
            root.forwardHistory = fwd;
            let prev = hist.pop();
            root.folderHistory = hist;
            let url = prev.startsWith("file://") ? prev : "file://" + prev;
            folderModel.folder = url;
            if (pluginService) {
                pluginService.savePluginData(pluginId, "customFolderPath", prev);
                pluginService.savePluginData(pluginId, "folderType", "custom");
            }
            root.customFolderPath = prev;
            root.folderType = "custom";
            buildFolderDropdownModel();
        }
    }

    function goForwardFolder() {
        let fwd = [];
        for (let i = 0; i < root.forwardHistory.length; i++)
            fwd.push(root.forwardHistory[i]);
        if (fwd.length > 0) {
            let currentClean = root._cleanPath(String(root.targetFolderUrl));
            let hist = [];
            for (let i = 0; i < root.folderHistory.length; i++)
                hist.push(root.folderHistory[i]);
            hist.push(currentClean);
            root.folderHistory = hist;
            let next = fwd.pop();
            root.forwardHistory = fwd;
            let url = next.startsWith("file://") ? next : "file://" + next;
            folderModel.folder = url;
            if (pluginService) {
                pluginService.savePluginData(pluginId, "customFolderPath", next);
                pluginService.savePluginData(pluginId, "folderType", "custom");
            }
            root.customFolderPath = next;
            root.folderType = "custom";
            buildFolderDropdownModel();
        }
    }

    function togglePin(filePath) {
        if (!pluginService) return;
        let pins = [];
        for (let i = 0; i < root.pinnedPaths.length; i++) {
            pins.push(root.pinnedPaths[i]);
        }
        let index = pins.indexOf(filePath);
        if (index !== -1) {
            pins.splice(index, 1);
        } else {
            pins.push(filePath);
        }
        pluginService.savePluginData(pluginId, "pinnedPaths", pins);
    }

    function addToGtkBookmarks(filePath) {
        var cleanPath = root._cleanPath(String(filePath));
        var uri = "file://" + cleanPath;
        var name = cleanPath.split("/").pop();
        var line = uri + " " + name;

        var bookmarksFile = "/home/suruibin/.config/gtk-3.0/bookmarks";

        var safeLine = line.replace(/'/g, "'\\''");
        Proc.runCommand("addBookmark-" + Math.random(), ["sh", "-c",
            "grep -qxF '" + safeLine + "' " + bookmarksFile + " || echo '" + safeLine + "' >> " + bookmarksFile],
            function(out, code) {
                root.buildFolderDropdownModel();
            });
    }

    function pasteFromClipboard() {
        let scriptPath = decodeURIComponent(root._cleanPath(Qt.resolvedUrl("paste.py")));
        let pathStr = decodeURIComponent(root._cleanPath(root.targetFolderUrl));

        ToastService.showToast(i18n("Pasting files..."), ToastService.levelInfo);
        Quickshell.execDetached([scriptPath, pathStr]);
    }

    function dropFiles(urls) {
        // Copy files dragged in from external windows into the current folder.
        let fileUris = urls.map(u => String(u)).filter(u => u.startsWith("file://"));
        if (fileUris.length === 0) return;

        let scriptPath = decodeURIComponent(root._cleanPath(Qt.resolvedUrl("paste.py")));
        let pathStr = decodeURIComponent(root._cleanPath(root.targetFolderUrl));

        ToastService.showToast(i18n("Copying files..."), ToastService.levelInfo);
        Quickshell.execDetached([scriptPath, "--drop", pathStr].concat(fileUris));
    }

    function _executePaste(ops, overwrite) {
        for (var i = 0; i < ops.length; i++) {
            var op = ops[i];
            if (!overwrite && op.conflict) continue;
            if (op.isCut) {
                Quickshell.execDetached(["mv", op.src, op.dest]);
            } else {
                Quickshell.execDetached(["cp", "-a", op.src, op.dest]);
            }
        }
        root.copiedFilePaths = [];
        root.cutMode = false;
        root._pastePendingOps = [];
        root._pasteOverwriteAll = false;
    }

    function _checkPasteConflicts(ops) {
        var checks = ops.map(function(o) {
            var safe = o.dest.replace(/'/g, "'\\''");
            return "test -e '" + safe + "' && echo 1 || echo 0";
        }).join("; ");
        Proc.runCommand("pasteCheck-" + Math.random(), ["sh", "-c", checks], function(out, code) {
            if (code !== 0 || !out) {
                // Can't check — proceed without overwrite prompt
                root._executePaste(ops, true);
                return;
            }
            var lines = String(out).trim().split("\n");
            var hasConflicts = false;
            for (var j = 0; j < lines.length && j < ops.length; j++) {
                if (lines[j].trim() === "1") {
                    ops[j].conflict = true;
                    hasConflicts = true;
                }
            }
            if (hasConflicts) {
                root._pastePendingOps = ops;
                overwriteDialog.conflictNames = ops.filter(function(o) { return o.conflict; }).map(function(o) { return o.dest.split("/").pop(); });
                overwriteDialog.open();
            } else {
                root._executePaste(ops, false);
            }
        });
    }

    onSelectedFilePathsChanged: {
        // A changed selection means any pending click-to-rename no longer
        // targets the clicked item.
        inlineRenameArmTimer.stop();
        if (selectedFilePaths.length > 0) {
            selectionClearTimer.restart();
        } else {
            selectionClearTimer.stop();
        }

        // Update selected file info for header display
        if (selectedFilePaths.length === 1) {
            const selPath = selectedFilePaths[0];
            let info = "";
            for (let i = 0; i < filteredModel.count; i++) {
                const item = filteredModel.get(i);
                if (item.filePath === selPath) {
                    const name = String(item.fileName || "");
                    const mtime = item.fileModified ? root.formatDate(item.fileModified) : "";
                    const isDir = item.fileIsDir;
                    const size = (!isDir && item.fileSize) ? root.formatFileSize(item.fileSize) : "";
                    const parts = [name];
                    if (root.favoritePaths.indexOf(selPath) !== -1) parts[0] = "★ " + name;
                    if (mtime) parts.push(mtime);
                    if (size) parts.push(size);
                    info = parts.join("  ");
                    break;
                }
            }
            root.selectedFileInfo = info;
        } else {
            root.selectedFileInfo = "";
        }
    }

    Timer {
        id: selectionClearTimer
        interval: 5000 // 5 seconds of inactivity
        repeat: false
        onTriggered: {
            if (!renameDialog.opened && !quickMenu.opened && root.renamingFilePath === "") {
                clearSelection();
            } else {
                selectionClearTimer.restart();
            }
        }
    }

    // Delays click-to-rename so a double-click (open) cancels it first.
    Timer {
        id: inlineRenameArmTimer
        interval: 400 // ~ system double-click interval
        repeat: false
        onTriggered: root.beginInlineRename(root._inlineRenameArmPath)
    }

    // ── Plugin I18n: Load plugin translations & use them locally ────────────────
    FileView {
        id: pluginI18nLoader
        onLoaded: {
            try {
                root._pluginFlatTranslations = JSON.parse(text());
                root._pluginI18nReady = true;
                console.info(`FolderView I18n: loaded ${Object.keys(root._pluginFlatTranslations).length} translations for '${root.pluginLanguage}'`);
                // Rebuild model arrays now that translations are available
                root.buildFolderDropdownModel();
                root._rebuildI18nArrays();
                // Publish translation map to instance config so settings page
                // can resolve dynamic labels (e.g. header position "Top"/"Bottom").
                if (root.pluginService && root.pluginId) {
                    root.pluginService.savePluginData(root.pluginId, "i18nMap", root._pluginFlatTranslations);
                    root.pluginService.savePluginData(root.pluginId, "i18nToken", Date.now());
                }
            } catch (e) {
                console.warn("FolderView I18n: error parsing:", e);
            }
        }
        onLoadFailed: error => {
            console.warn("FolderView I18n: failed to load:", error);
            // Fall back to English (always present)
            if (root.pluginLanguage !== "en") {
                pluginI18nLoader.path = Qt.resolvedUrl("translations/i18n/en.json");
            }
        }
    }

    function _applyPluginLanguage(locale) {
        if (locale === "System Default" || locale === "") locale = "system";
        if (!locale) return;

        if (locale === "system") {
            var sys = _stripLocaleEnc(Qt.locale().name);
            // Try to load plugin file matching system locale;
            // onLoadFailed will fall back to en.json.
            pluginI18nLoader.path = Qt.resolvedUrl("translations/i18n/" + sys + ".json");
            console.info("FolderView I18n: switching to system locale", sys);
            return;
        }

        // en, zh_CN, de, fr, ... — load plugin's own translation file
        pluginI18nLoader.path = Qt.resolvedUrl("translations/i18n/" + locale + ".json");
        console.info("FolderView I18n: switching to", locale);
    }

    // Force-rebuild all i18n-dependent model arrays so every UI string picks up
    // the current translation regardless of how QML tracks binding dependencies.
    function _rebuildI18nArrays() {
        root._viewModeOptions = [
            { label: i18n("Grid View"), value: "grid", icon: "grid_view" },
            { label: i18n("List View"), value: "list", icon: "view_list" },
            { label: i18n("Compact View"), value: "compact", icon: "view_module" }
        ];
        root._createNewOptions = [
            { label: i18n("New Folder"), value: "folder", icon: "create_new_folder" },
            { label: i18n("New Document"), value: "file", icon: "note_add" },
            { label: i18n("New App"), value: "app", icon: "add_to_home_screen" }
        ];
        root._sortOptions = [
            { label: i18n("Sort by Name"), value: "name", icon: "sort_by_alpha" },
            { label: i18n("Sort by Date"), value: "time", icon: "schedule" },
            { label: i18n("Sort by Size"), value: "size", icon: "bar_chart" },
            { label: i18n("Sort by Type"), value: "type", icon: "category" }
        ];
        root._fileTypeOptions = [
            { label: i18n("All Files"), value: "all", icon: "menu" },
            { label: i18n("Folders Only"), value: "folders", icon: "folder" },
            { label: i18n("Files Only"), value: "files", icon: "description" },
            { label: i18n("Images Only"), value: "images", icon: "image" },
            { label: i18n("Documents Only"), value: "documents", icon: "article" },
            { label: i18n("Audio & Video"), value: "audio_video", icon: "movie" }
        ];
        root._timeFilterOptions = [
            { label: i18n("Any Time"), value: "all", icon: "schedule" },
            { label: i18n("Last 24 Hours"), value: "today", icon: "today" },
            { label: i18n("Last 7 Days"), value: "week", icon: "date_range" },
            { label: i18n("Last 30 Days"), value: "month", icon: "calendar_month" },
            { label: i18n("Last 365 Days"), value: "year", icon: "history" }
        ];
        root._headerPositionOptions = [
            { label: i18n("Top"), val: "top" },
            { label: i18n("Bottom"), val: "bottom" }
        ];
        // Bump token after rebuilding arrays so inline i18n() bindings
        // (e.g. StyledText { text: i18n("...") }) re-evaluate too.
        root._i18nToken++;
    }

    // Local i18n() — checks plugin translations first, falls back to system I18n
    property int _i18nToken: 0
    function i18n(term, context) {
        // _i18nToken is read to create a QML binding dependency — when it changes
        // (after translations are reloaded) every binding that calls i18n()
        // re-evaluates and picks up the new translation.
        if (_i18nToken < 0) {}
        if (_pluginI18nReady && _pluginFlatTranslations[term]) {
            return _pluginFlatTranslations[term];
        }
        return I18n.tr(term, context);
    }

    // ── System Locale Change Detection ──────────────────────────────────────────
    // Qt.locale().name is frozen at process startup, so it can't detect system
    // locale changes.  Instead we poll /etc/locale.conf (the systemd locale
    // config that localectl writes to) via a shell command every 15 s.  When the
    // locale changes the new translation file is loaded into I18n.translations,
    // which triggers every I18n.tr() / i18n() binding to re-evaluate.
    property string _lastSystemLocale: Qt.locale().name
    property bool _checkingLocale: false

    // Strip encoding suffix (".UTF-8" → "") for translation file lookup
    function _stripLocaleEnc(loc) {
        var s = String(loc).trim();
        var dot = s.indexOf(".");
        return dot > 0 ? s.substring(0, dot) : s;
    }

    // ── Path Editor Autocomplete ──────────────────────────────────────────
    function _fetchPathCompletions() {
        if (!pathEditor || !pathEditor.visible) { _pathCompletions = []; return; }
        var text = pathEditor.text;
        if (!text || text.length === 0) { _pathCompletions = []; return; }

        var lastSlash = text.lastIndexOf("/");
        var basePath, prefix;
        if (lastSlash >= 0) {
            basePath = text.substring(0, lastSlash);
            prefix = text.substring(lastSlash + 1);
        } else {
            basePath = root._cleanPath(root.targetFolderUrl);
            prefix = text;
        }

        if (basePath.length === 0) basePath = "/";
        if (basePath.length > 1 && basePath.charAt(basePath.length - 1) === '/')
            basePath = basePath.substring(0, basePath.length - 1);

        var shellSafe = basePath.replace(/'/g, "'\\''");
        Proc.runCommand("pathComplete-" + Math.random(),
            ["sh", "-c", "ls -1 -p '" + shellSafe + "' 2>/dev/null"],
            (out, code) => {
                if (code !== 0 || !out) { _pathCompletions = []; return; }

                var entries = String(out).trim().split("\n").filter(e => e.length > 0);
                var results = [];
                for (var i = 0; i < entries.length; i++) {
                    var entry = entries[i];
                    var isDir = entry.charAt(entry.length - 1) === "/";
                    var name = isDir ? entry.substring(0, entry.length - 1) : entry;
                    if (name.charAt(0) === "." && prefix.charAt(0) !== ".") continue;
                    if (name.toLowerCase().indexOf(prefix.toLowerCase()) !== 0) continue;
                    var fullPath = (basePath === "/" ? "" : basePath) + "/" + name;
                    if (isDir) fullPath += "/";
                    results.push({ display: name + (isDir ? "/" : ""), fullPath: fullPath, isDir: isDir });
                }
                results.sort((a, b) => {
                    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
                    return a.display.toLowerCase().localeCompare(b.display.toLowerCase());
                });

                _pathCompletions = results;
                _pathCompletionIndex = -1;

                if (results.length > 0) {
                    var pos = pathEditor.mapToItem(root, 0, 0);
                    pathCompletionPopup.x = pos.x;
                    // Show above editor since it's at bottom
                    pathCompletionPopup.y = pos.y - Math.min(results.length * 28 + 4, 284);
                    pathCompletionPopup.width = Math.max(folderSelectorBtn.width, 180);
                    pathCompletionPopup.open();
                } else {
                    pathCompletionPopup.close();
                }
            }, 2000);
    }

    function _selectPathCompletion(idx) {
        if (idx < 0 || idx >= _pathCompletions.length) return;
        var item = _pathCompletions[idx];
        pathEditor.text = item.fullPath;
        pathEditor.cursorPosition = pathEditor.text.length;
        if (item.isDir) {
            Qt.callLater(() => pathCompletionDebounce.restart());
        } else {
            pathCompletionPopup.close();
            _pathCompletions = [];
        }
    }

    function retranslate() {
        // Force-reload system translations for the current locale
        var loc = root._stripLocaleEnc(root._lastSystemLocale);
        if (!loc || loc === "en" || loc === "C" || loc === "POSIX") return;
        if (root.pluginLanguage === "system" || root.pluginLanguage === "") {
            var folder = String(I18n.translationsFolder);
            var sep = folder.charAt(folder.length - 1) === "/" ? "" : "/";
            systemLocaleLoader.path = folder + sep + loc + ".json";
        }
    }

    FileView {
        id: systemLocaleLoader
        onLoaded: {
            try {
                I18n.translations = JSON.parse(text());
                I18n.translationsLoaded = true;
                root._rebuildI18nArrays();
                console.info("FolderView I18n: reloaded system translations for", root._lastSystemLocale);
            } catch (e) {
                console.warn("FolderView I18n: error parsing system locale:", e);
                I18n.translations = ({});
                I18n.translationsLoaded = true;
            }
        }
        onLoadFailed: {
            I18n.translations = ({});
            I18n.translationsLoaded = true;
            console.warn("FolderView I18n: no translation file for", root._lastSystemLocale);
        }
    }

    Timer {
        id: localeCheckTimer
        interval: 15000
        repeat: true
        running: true
        onTriggered: {
            if (root._checkingLocale) return;
            root._checkingLocale = true;
            Proc.runCommand("locale-check", ["sh", "-c",
                "cat /etc/locale.conf 2>/dev/null | grep '^LANG=' | head -1 | cut -sd= -f2- | tr -d '\\\" '"],
                (out, code) => {
                    root._checkingLocale = false;
                    if (code !== 0 || !out) return;
                    var cur = String(out).trim();
                    if (cur && cur !== root._lastSystemLocale) {
                        root._lastSystemLocale = cur;
                        root.retranslate();
                    }
                }, 500);
        }
    }

    Component.onDestruction: {
        selectionClearTimer.stop();
        inlineRenameArmTimer.stop();
        localeCheckTimer.stop();
    }
    Component.onCompleted: {
        buildFolderDropdownModel();
        _applyPluginLanguage(pluginLanguage);
        // Kick off initial lsblk scan
        Qt.callLater(function() { lsblkProc.running = true; });
    }

    ListModel {
        id: filteredModel
    }

    function updateFilteredModel() {
        filteredModel.clear();
        if (folderModel.status !== FolderListModel.Ready) return;
        
        const pattern = root.searchPattern.toLowerCase();
        let pinnedDirs = [];
        let pinnedFiles = [];
        let unpinnedDirs = [];
        let unpinnedFiles = [];

        // Load stacks in this folder and get list of files in collapsed stacks
        let currentFolderStacks = [];
        let collapsedFilePaths = new Set();
        let fileToExpandedStackMap = {}; // filePath -> stackId
        let expandedStackFilesMap = {}; // stackId -> array of item objects
        try {
            let sList = root.stacks || [];
            currentFolderStacks = sList.filter(s => s.folder === root.targetFolderUrl);
            
            // Sort stacks based on sortBy setting
            if (root.sortBy === "time") {
                currentFolderStacks.sort((a, b) => b.id.localeCompare(a.id));
            } else {
                currentFolderStacks.sort((a, b) => a.name.localeCompare(b.name, undefined, {numeric: true, sensitivity: 'base'}));
            }

            for (let s of currentFolderStacks) {
                let isExpanded = root.expandedStackIds.indexOf(s.id) !== -1;
                if (!isExpanded) {
                    for (let p of s.filePaths) {
                        collapsedFilePaths.add(p);
                    }
                } else {
                    for (let p of s.filePaths) {
                        fileToExpandedStackMap[p] = s.id;
                    }
                }
            }
        } catch (e) {
            console.log("Error loading stacks: " + e);
        }

        for (let i = 0; i < folderModel.count; i++) {
            try {
                const fName = folderModel.get(i, "fileName");
                const fPath = folderModel.get(i, "filePath");
                const fIsDir = folderModel.get(i, "fileIsDir");
                const fModified = folderModel.get(i, "fileModified");
                const fSize = folderModel.get(i, "fileSize") || 0;
                
                if (fName === undefined || fName === null || fPath === undefined || fPath === null) {
                    continue;
                }
                
                const nameStr = String(fName);
                let pathStr = String(fPath);

                // Skip file if it is in a collapsed stack
                if (collapsedFilePaths.has(pathStr)) {
                    continue;
                }
                
                // Extract extension once for all subsequent checks
                const ext = nameStr.includes(".") ? nameStr.split(".").pop().toLowerCase() : "";
                const isDir = !!fIsDir;

                // 1. Search Pattern filter check
        if (pattern !== "") {
            // Support * and ? wildcards → convert to regex
            var escaped = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.');
            var regex = new RegExp(escaped);
            if (!regex.test(nameStr.toLowerCase())) continue;
        }

                // 2. File Type filter check (inlined extension checks — avoids 3 function calls per item)
                if (root.filterType !== "all") {
                    if (root.filterType === "folders" && !isDir) continue;
                    if (root.filterType === "files" && isDir) continue;
                    if (root.filterType === "images" && (isDir || ["jpg","jpeg","png","gif","webp","svg","bmp"].indexOf(ext) === -1)) continue;
                    if (root.filterType === "documents" && (isDir || ["doc","docx","pdf","txt","odt","xls","xlsx","ppt","pptx","md","csv"].indexOf(ext) === -1)) continue;
                    if (root.filterType === "audio_video" && (isDir || ["mp3","wav","ogg","flac","m4a","mp4","mkv","avi","mov","webm","flv"].indexOf(ext) === -1)) continue;
                }

                // 3. Time filter check
                if (root.filterTime !== "all" && fModified !== undefined && fModified !== null) {
                    const elapsed = new Date() - fModified;
                    if (root.filterTime === "today" && elapsed > 24 * 60 * 60 * 1000) continue;
                    if (root.filterTime === "week" && elapsed > 7 * 24 * 60 * 60 * 1000) continue;
                    if (root.filterTime === "month" && elapsed > 30 * 24 * 60 * 60 * 1000) continue;
                    if (root.filterTime === "year" && elapsed > 365 * 24 * 60 * 60 * 1000) continue;
                }

                let isDesktop = nameStr.endsWith(".desktop") && !isDir;
                let displayBaseName = isDesktop ? nameStr.slice(0, -8) : nameStr;
                let itemType = root.getItemType(nameStr, !!fIsDir);
                let iconName = root.getIconName(nameStr, !!fIsDir);
                let iconColor = root.getIconColor(nameStr, !!fIsDir);
                let isEmpty = !fIsDir ? (fSize === 0) : false;
                let item = {
                    filePath: pathStr,
                    fileName: nameStr,
                    displayBaseName: displayBaseName,
                    fileIsDir: !!fIsDir,
                    itemType: itemType,
                    iconName: iconName,
                    iconColor: iconColor,
                    fileModified: fModified,
                    fileSize: fSize,
                    isEmpty: isEmpty,
                    isDesktop: isDesktop,
                    appName: "",
                    appIcon: "",
                    appExec: "",
                    isStack: false,
                    isExpanded: false,
                    belongingStackId: ""
                };

                // Async check: empty folders
                if (fIsDir) {
                    let checkPath = root._cleanPath(pathStr);
                    let safePath = checkPath.replace(/'/g, "'\\''");
                    Proc.runCommand("emptyCheck-" + Math.random(), ["sh", "-c", "ls -A '" + safePath + "' 2>/dev/null | head -1 | wc -l"], (out, code) => {
                        if (code === 0) {
                            let hasContent = parseInt(String(out).trim()) > 0;
                            for (let k = 0; k < filteredModel.count; k++) {
                                if (filteredModel.get(k).filePath === pathStr) {
                                    filteredModel.setProperty(k, "isEmpty", !hasContent);
                                    break;
                                }
                            }
                        }
                    });
                }
                
                let expandedStackId = fileToExpandedStackMap[pathStr];
                if (expandedStackId !== undefined) {
                    item.belongingStackId = expandedStackId;
                    if (!expandedStackFilesMap[expandedStackId]) {
                        expandedStackFilesMap[expandedStackId] = [];
                    }
                    expandedStackFilesMap[expandedStackId].push(item);
                    
                    if (isDesktop) {
                        let safePath = root._cleanPath(pathStr);
                        Proc.runCommand("parseDesktop-" + Math.random(), ["cat", safePath], (out, code) => {
                            if (code === 0 && out) {
                                let aName = "";
                                let aIcon = "";
                                let aExec = "";
                                let lines = out.split('\n');
                                for (let j = 0; j < lines.length; j++) {
                                    let l = lines[j].trim();
                                    if (l.startsWith("Name=") && !aName) aName = l.substring(5).trim();
                                    else if (l.startsWith("Icon=") && !aIcon) aIcon = l.substring(5).trim();
                                    else if (l.startsWith("Exec=") && !aExec) aExec = l.substring(5).trim();
                                }
                                
                                let targetIdx = -1;
                                for (let k = 0; k < filteredModel.count; k++) {
                                    if (filteredModel.get(k).filePath === pathStr) {
                                        targetIdx = k;
                                        break;
                                    }
                                }
                                
                                if (targetIdx !== -1) {
                                    filteredModel.setProperty(targetIdx, "appName", aName);
                                    filteredModel.setProperty(targetIdx, "appIcon", aIcon);
                                    filteredModel.setProperty(targetIdx, "appExec", aExec);
                                    filteredModel.setProperty(targetIdx, "displayBaseName", aName);
                                }
                            }
                        });
                    }
                    continue; // Skip partitioning to general list
                }

                if (isDesktop) {
                    let safePath = root._cleanPath(pathStr);
                    Proc.runCommand("parseDesktop-" + Math.random(), ["cat", safePath], (out, code) => {
                        if (code === 0 && out) {
                            let aName = "";
                            let aIcon = "";
                            let aExec = "";
                            let lines = out.split('\n');
                            for (let j = 0; j < lines.length; j++) {
                                let l = lines[j].trim();
                                if (l.startsWith("Name=") && !aName) aName = l.substring(5).trim();
                                else if (l.startsWith("Icon=") && !aIcon) aIcon = l.substring(5).trim();
                                else if (l.startsWith("Exec=") && !aExec) aExec = l.substring(5).trim();
                            }
                            
                            // Find the item index since model might have changed
                            let targetIdx = -1;
                            for (let k = 0; k < filteredModel.count; k++) {
                                if (filteredModel.get(k).filePath === pathStr) {
                                    targetIdx = k;
                                    break;
                                }
                            }
                            
                            if (targetIdx !== -1) {
                                filteredModel.setProperty(targetIdx, "appName", aName);
                                filteredModel.setProperty(targetIdx, "appIcon", aIcon);
                                filteredModel.setProperty(targetIdx, "appExec", aExec);
                                filteredModel.setProperty(targetIdx, "displayBaseName", aName);
                            }
                        }
                    });
                }

                let isPinned = root.pinnedPaths.indexOf(pathStr) !== -1;
                if (isPinned) {
                    if (fIsDir) {
                        pinnedDirs.push(item);
                    } else {
                        pinnedFiles.push(item);
                    }
                } else {
                    if (fIsDir) {
                        unpinnedDirs.push(item);
                    } else {
                        unpinnedFiles.push(item);
                    }
                }
            } catch (e) {
                console.log("Error processing file at index " + i + ": " + e);
            }
        }
        
        let pinnedStacks = [];
        let unpinnedStacks = [];

        // Append virtual stack items to pinnedStacks or unpinnedStacks
        for (let s of currentFolderStacks) {
            let isExpanded = root.expandedStackIds.indexOf(s.id) !== -1;
            let stackItem = {
                filePath: "stack://" + s.id,
                fileName: s.name,
                fileIsDir: true,
                isDesktop: false,
                displayBaseName: s.name,
                itemType: "dir",
                iconName: "layers",
                iconColor: Theme.primary,
                isEmpty: false,
                appName: "",
                appIcon: "",
                appExec: "",
                isStack: true,
                isExpanded: isExpanded,
                belongingStackId: isExpanded ? s.id : ""
            };
            
            let isPinned = root.pinnedPaths.indexOf("stack://" + s.id) !== -1;
            if (isPinned) {
                pinnedStacks.push(stackItem);
            } else {
                unpinnedStacks.push(stackItem);
            }
        }

        // 1. Pinned Stacks
        pinnedStacks.forEach(function(item) {
            filteredModel.append(item);
            if (item.isStack && item.isExpanded) {
                let sFiles = expandedStackFilesMap[item.belongingStackId] || [];
                sFiles.forEach(function(f) {
                    filteredModel.append(f);
                });
            }
        });

        // 2. Pinned Directories
        pinnedDirs.forEach(function(item) { filteredModel.append(item); });

        // 3. Pinned Files
        pinnedFiles.forEach(function(item) { filteredModel.append(item); });
        
        // 4. Unpinned Stacks
        unpinnedStacks.forEach(function(item) {
            filteredModel.append(item);
            if (item.isStack && item.isExpanded) {
                let sFiles = expandedStackFilesMap[item.belongingStackId] || [];
                sFiles.forEach(function(f) {
                    filteredModel.append(f);
                });
            }
        });

        // 5. Unpinned Directories
        unpinnedDirs.forEach(function(item) { filteredModel.append(item); });
        
        // 6. Unpinned Files
        unpinnedFiles.forEach(function(item) { filteredModel.append(item); });

        // ── AppImage icon matching via AppIcon/ folder ────────────────────
        let _iconDir = root._cleanPath(String(root.targetFolderUrl)) + "/AppIcon";
        let _safeIconDir = _iconDir.replace(/'/g, "'\\''");
        Proc.runCommand("scanAppIcon-" + Math.random(), ["sh", "-c", "ls -1 '" + _safeIconDir + "' 2>/dev/null | head -100"], (out, code) => {
            if (code !== 0 || !out || String(out).trim() === "") return;
            let iconFiles = String(out).trim().split('\n').filter(f => {
                let lower = f.toLowerCase();
                return lower.endsWith(".png") || lower.endsWith(".jpg") || lower.endsWith(".jpeg")
                    || lower.endsWith(".svg") || lower.endsWith(".webp");
            });
            if (iconFiles.length === 0) return;
            // Build icon stem → file:// URI map (lowercased stems)
            let _iMap = {};
            for (let _f of iconFiles) {
                let _dot = _f.lastIndexOf('.');
                if (_dot > 0) _iMap[_f.substring(0, _dot).toLowerCase()] = "file://" + _iconDir + "/" + _f;
            }
            // Match each non-dir AppImage in the model
            for (let _k = 0; _k < filteredModel.count; _k++) {
                let _name = filteredModel.get(_k).fileName;
                let _isDir = filteredModel.get(_k).fileIsDir;
                if (_isDir || (!_name.endsWith(".AppImage") && !_name.endsWith(".appimage"))) continue;
                let _matchBase = _name.substring(0, _name.length - 9).toLowerCase(); // strip .AppImage/.appimage
                for (let _stem in _iMap) {
                    if (_matchBase.includes(_stem)) {
                        filteredModel.setProperty(_k, "appIcon", _iMap[_stem]);
                        break;
                    }
                }
            }
        });

        // Release the inline-rename lock if the edited item is no longer present
        // after this refresh (e.g. it was trashed/moved while being renamed),
        // otherwise renamingFilePath stays stuck and selectionClearTimer never
        // clears the selection again.
        if (root.renamingFilePath !== "" && !isPathInFilteredModel(root.renamingFilePath)) {
            inlineRenameArmTimer.stop();
            root.renamingFilePath = "";
        }
    }

    function createStack(stackName, filePaths) {
        let newStack = {
            "id": "stack_" + Date.now() + "_" + Math.floor(Math.random() * 1000),
            "name": stackName,
            "folder": root.targetFolderUrl,
            "filePaths": filePaths
        };
        let newStacks = [...stacks, newStack];
        root.stacks = newStacks;
        if (pluginService) {
            pluginService.savePluginData(pluginId, "stacks", newStacks);
        }
        clearSelection();
        updateFilteredModel();
    }

    function renameStack(stackId, newName) {
        let newStacks = stacks.map(s => {
            if (s.id === stackId) {
                s.name = newName;
            }
            return s;
        });
        root.stacks = newStacks;
        if (pluginService) {
            pluginService.savePluginData(pluginId, "stacks", newStacks);
        }
        updateFilteredModel();
    }

    function ungroupStack(stackId) {
        let newStacks = stacks.filter(s => s.id !== stackId);
        root.stacks = newStacks;
        if (pluginService) {
            pluginService.savePluginData(pluginId, "stacks", newStacks);
        }
        expandedStackIds = expandedStackIds.filter(id => id !== stackId);
        clearSelection();
        updateFilteredModel();
    }

    function toggleStackExpanded(stackId) {
        let arr = [...expandedStackIds];
        let idx = arr.indexOf(stackId);
        if (idx === -1) {
            arr.push(stackId);
        } else {
            arr.splice(idx, 1);
        }
        expandedStackIds = arr;
        updateFilteredModel();
    }

    onSearchPatternChanged: updateFilteredModel()
 
    // Basic Filtering Properties
    property string filterType: "all"
    property string filterTime: "all"
    onFilterTypeChanged: updateFilteredModel()
    onFilterTimeChanged: updateFilteredModel()
    onFolderColorChanged: updateFilteredModel()

    function scrollToTop() {
        if (viewMode === "grid" && typeof fileGrid !== "undefined" && fileGrid) {
            fileGrid.contentY = 0;
        } else if (viewMode === "list" && typeof fileList !== "undefined" && fileList) {
            fileList.contentY = 0;
        } else if (viewMode === "compact" && typeof fileCompact !== "undefined" && fileCompact) {
            fileCompact.contentY = 0;
        }
    }

    function buildFolderDropdownModel() {
        var items = [
            { label: i18n("Home"), value: "home", icon: "home" },
            { label: i18n("Root"), value: "root", icon: "storage" },
            { label: i18n("Desktop"), value: "desktop", icon: "desktop_mac" },
            { label: i18n("Downloads"), value: "downloads", icon: "download" },
            { label: i18n("Music"), value: "music", icon: "music_note" },
            { label: i18n("Pictures"), value: "pictures", icon: "image" },
            { label: i18n("Videos"), value: "videos", icon: "movie" },
            { label: i18n("Documents"), value: "documents", icon: "description" },
            { label: i18n("Trash"), value: "trash", icon: "delete" }
        ];

        // Resolve home as clean filesystem path (strip file:// if present)
        var homeUrl = Platform.StandardPaths.writableLocation(Platform.StandardPaths.HomeLocation).toString();
        var homePath = homeUrl;
        if (homePath.indexOf("file://") === 0) homePath = homePath.substring(7);

        // Collect standard paths (clean paths, no file:// prefix) to skip duplicates
        var stdPaths = {};
        stdPaths[homePath] = true;
        stdPaths[homePath + "/Desktop"] = true;
        stdPaths[homePath + "/Downloads"] = true;
        stdPaths[homePath + "/Music"] = true;
        stdPaths[homePath + "/Pictures"] = true;
        stdPaths[homePath + "/Videos"] = true;
        stdPaths[homePath + "/Documents"] = true;

        // Read GTK bookmarks (system file manager favorites)
        var bookmarkItems = [];
        try {
            var bkUrl = homeUrl;
            if (bkUrl.charAt(bkUrl.length - 1) !== "/") bkUrl += "/";
            bkUrl += ".config/gtk-3.0/bookmarks";
            var xhr = new XMLHttpRequest();
            xhr.open("GET", bkUrl, false);
            xhr.send();
            if (xhr.status === 0 || xhr.status === 200) {
                var lines = xhr.responseText.split("\n");
                for (var bi = 0; bi < lines.length; bi++) {
                    var line = String(lines[bi]).trim();
                    if (line === "") continue;
                    // Format: "file:///path optional_label"
                    var spaceIdx = line.indexOf(" ");
                    var uri = spaceIdx >= 0 ? line.substring(0, spaceIdx) : line;
                    var label = spaceIdx >= 0 ? line.substring(spaceIdx + 1).trim() : "";
                    var filePath = decodeURIComponent(uri);
                    if (filePath.indexOf("file://") === 0) filePath = filePath.substring(7);

                    // Skip if matches a standard path
                    if (stdPaths[filePath] !== undefined) continue;
                    // Skip home root or empty
                    if (filePath === "" || filePath === homePath) continue;

                    var displayName = label || filePath.split("/").filter(function(s) { return s !== ""; }).pop() || filePath;
                    bookmarkItems.push({ label: displayName, value: "bookmark", icon: "bookmark", path: filePath });
                }
            }
        } catch (e) {}

        // Add bookmarks section
        if (bookmarkItems.length > 0) {
            items.push({ value: "separator", icon: "", label: "" });
            for (var bj = 0; bj < bookmarkItems.length; bj++) {
                items.push(bookmarkItems[bj]);
            }
        }

        // Favorites section
        var favs = root.favoritePaths || [];
        if (favs.length > 0) {
            items.push({ value: "separator", icon: "", label: "" });
            for (var fi = 0; fi < favs.length; fi++) {
                var favPath = String(favs[fi]);
                var favName = favPath.split("/").pop() || favPath;
                if (favName.length > 10) favName = favName.substring(0, 9) + "…";
                items.push({ label: favName, value: "favorite", icon: "star", path: favPath });
            }
        }

        // Drives section — opens a sub-popup with mountable partitions
        items.push({ value: "separator", icon: "", label: "" });
        items.push({ label: i18n("Drives"), value: "drives", icon: "hard_drive" });

        // Mounted drives — show all mounted partitions directly in the dropdown
        var _curPath = root.customFolderPath;
        root._isOnDrive = false;
        for (var _di = 0; _di < root._driveEntries.length; _di++) {
            var _de = root._driveEntries[_di];
            if (_de.mounted && _de.path && _de.path !== "") {
                // Check if current folder is inside this drive (for highlighting)
                if (!root._isOnDrive && _curPath && (_curPath === _de.path || _curPath.startsWith(_de.path + "/")))
                    root._isOnDrive = true;
                items.push({
                    label: _de.label,
                    value: "drive",
                    path: _de.path,
                    icon: _de.icon || "hard_drive",
                    mounted: true,
                    device: _de.device || ""
                });
            }
        }
        // Fallback: if current path matches a drive but _driveEntries wasn't populated yet
        if (!root._isOnDrive && root._currentDriveInfo && root._currentDriveInfo.path) {
            if (_curPath && (_curPath === root._currentDriveInfo.path || _curPath.startsWith(root._currentDriveInfo.path + "/"))) {
                root._isOnDrive = true;
                items.push({
                    label: root._currentDriveInfo.label,
                    value: "drive",
                    path: root._currentDriveInfo.path,
                    icon: root._currentDriveInfo.icon || "hard_drive",
                    mounted: true,
                    device: ""
                });
            } else {
                root._currentDriveInfo = ({});
            }
        }

        root.folderDropdownModel = root._applyDropdownOrder(items);
    }

    // ── Dropdown drag-reorder helpers ──

    // Unique stable key for a dropdown item (survives model rebuilds)
    function _itemKey(item) {
        if (!item || item.value === "separator") return "";
        if (item.path) return item.value + "|" + item.path;
        return item.value;
    }

    // Apply saved custom order to items array
    function _applyDropdownOrder(items) {
        var saved = pluginService ? pluginService.loadPluginData(pluginId, _dropDragOrderKey, "") : "";
        if (!saved || saved === "") return items;
        try {
            var order = JSON.parse(saved);
            if (!Array.isArray(order) || order.length === 0) return items;

            var keyMap = {};
            for (var i = 0; i < items.length; i++) {
                var k = root._itemKey(items[i]);
                if (k !== "") keyMap[k] = items[i];
            }

            var reordered = [];
            var used = {};
            for (var i = 0; i < order.length; i++) {
                var k = order[i];
                if (k !== "" && keyMap[k] !== undefined && !used[k]) {
                    reordered.push(keyMap[k]);
                    used[k] = true;
                }
            }

            // Append any new items not in saved order (e.g. new bookmarks)
            for (var i = 0; i < items.length; i++) {
                var k = root._itemKey(items[i]);
                if (k !== "" && !used[k]) {
                    reordered.push(items[i]);
                    used[k] = true;
                }
            }

            return reordered;
        } catch (e) {
            return items;
        }
    }

    // Save current dropdown order to plugin data
    function _saveDropdownOrder() {
        var model = root.folderDropdownModel;
        var order = [];
        for (var i = 0; i < model.length; i++) {
            var k = root._itemKey(model[i]);
            if (k !== "") order.push(k);
        }
        if (pluginService && order.length > 0)
            pluginService.savePluginData(pluginId, _dropDragOrderKey, JSON.stringify(order));
    }

    // Clamp drag target index to respect section boundaries
    function _clampDragTarget(fromIdx, targetIdx) {
        var model = root.folderDropdownModel;
        var fromItem = fromIdx >= 0 && fromIdx < model.length ? model[fromIdx] : null;
        if (!fromItem) return targetIdx;

        // Find "Drives" entry index
        var drivesIdx = -1;
        for (var i = 0; i < model.length; i++) {
            if (model[i].value === "drives") {
                drivesIdx = i;
                break;
            }
        }
        if (drivesIdx < 0) return targetIdx;

        // Mounted drives cannot be dragged above "Drives" entry
        if (fromItem.value === "drive" && targetIdx <= drivesIdx)
            return drivesIdx + 1;

        // Bookmarks and Favorites cannot be dragged below "Drives" entry
        if ((fromItem.value === "bookmark" || fromItem.value === "favorite") && targetIdx > drivesIdx)
            return drivesIdx;

        return targetIdx;
    }

    // Finish a drag operation: swap item in model, save order
    function _finishDrag() {
        if (!root._dropDragActive) return;
        root._dropDragActive = false;
        folderDropdownFlick.interactive = true;

        var fromIdx = root._dropDragFromIdx;
        var toIdx = root._clampDragTarget(root._dropDragFromIdx, root._dropDragToIdx);

        if (fromIdx >= 0 && toIdx >= 0 && fromIdx !== toIdx) {
            var model = root.folderDropdownModel.slice();

            var item = model.splice(fromIdx, 1)[0];
            var insertIdx = toIdx > fromIdx ? toIdx - 1 : toIdx;
            if (insertIdx > model.length) insertIdx = model.length;
            model.splice(insertIdx, 0, item);
            root.folderDropdownModel = model;
            root._saveDropdownOrder();
        }

        root._dropDragFromIdx = -1;
        root._dropDragToIdx = -1;
    }

    // Calculate target index for drop at given Y in Column coords
    function _dragTargetIdx(yInColumn) {
        var model = root.folderDropdownModel;
        var cumY = 24 + 2; // pin toggle height + Column.spacing
        for (var i = 0; i < model.length; i++) {
            var h = model[i].value === "separator" ? 10 : 28;
            var center = cumY + h / 2;
            if (yInColumn < center) return i;
            cumY += h + 2;
        }
        return model.length;
    }

    // Get Y position (in folderDropdownContent coords) for drop indicator at given item index
    function _dropIndicatorY(itemIdx) {
        var model = root.folderDropdownModel;
        var cumY = 24 + 2; // pin toggle height + spacing
        for (var i = 0; i < itemIdx; i++) {
            cumY += (model[i].value === "separator" ? 10 : 28) + 2;
        }
        var pt = folderDropdownColumn.mapToItem(folderDropdownContent, 0, cumY);
        return pt.y;
    }

    Connections {
        target: folderModel
        function onStatusChanged() {
            if (folderModel.status === FolderListModel.Ready) {
                updateFilteredModel();
            }
        }
        function onCountChanged() {
            updateFilteredModel();
        }
    }

    function formatFileSize(bytes) {
        if (!bytes || bytes <= 0) return "";
        const units = ["B", "KB", "MB", "GB", "TB"];
        let i = 0;
        let size = bytes;
        while (size >= 1024 && i < units.length - 1) { size /= 1024; i++; }
        return size.toFixed(i === 0 ? 0 : 1) + " " + units[i];
    }

    function formatDate(date) {
        if (!date) return "";
        const d = new Date(date);
        const pad = n => String(n).padStart(2, "0");
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
            + " " + pad(d.getHours()) + ":" + pad(d.getMinutes());
    }

    function isImage(fileName) {
        const ext = fileName.split('.').pop().toLowerCase();
        return ["jpg", "jpeg", "png", "gif", "webp", "svg", "bmp"].indexOf(ext) !== -1;
    }

    function getItemType(fileName, isDir) {
        if (isDir) return "dir";
        const ext = fileName.split('.').pop().toLowerCase();
        if (["jpg","jpeg","png","gif","webp","svg","bmp"].indexOf(ext) !== -1) return "image";
        if (["mp3","wav","ogg","flac","m4a"].indexOf(ext) !== -1) return "audio";
        if (["pdf"].indexOf(ext) !== -1) return "pdf";
        if (["mp4","mkv","avi","mov","webm","flv"].indexOf(ext) !== -1) return "video";
        return "other";
    }

    function getIconName(fileName, isDir) {
        if (isDir) return "folder";
        
        const ext = fileName.split('.').pop().toLowerCase();
        switch (ext) {
            case "jpg":
            case "jpeg":
            case "png":
            case "gif":
            case "webp":
            case "svg":
            case "bmp":
                return "image";
            case "mp3":
            case "wav":
            case "ogg":
            case "flac":
            case "m4a":
                return "audiotrack";
            case "mp4":
            case "mkv":
            case "avi":
            case "mov":
            case "webm":
                return "video_library";
            case "pdf":
                return "picture_as_pdf";
            case "zip":
            case "tar":
            case "gz":
            case "bz2":
            case "xz":
            case "rar":
            case "7z":
                return "archive";
            case "txt":
            case "md":
            case "json":
            case "xml":
            case "yaml":
            case "yml":
            case "conf":
            case "ini":
                return "description";
            case "sh":
            case "py":
            case "js":
            case "ts":
            case "rs":
            case "go":
            case "c":
            case "cpp":
            case "h":
            case "java":
            case "html":
            case "css":
                return "terminal";
            case "desktop":
                return "bookmark";
            default:
                return "insert_drive_file";
        }
    }

    function getIconColor(fileName, isDir) {
        if (isDir) return root.folderColor || Theme.primary;
        
        const ext = fileName.split('.').pop().toLowerCase();
        switch (ext) {
            case "jpg":
            case "jpeg":
            case "png":
            case "gif":
            case "webp":
            case "svg":
            case "bmp":
                return "#00BFA5"; // Teal
            case "mp3":
            case "wav":
            case "ogg":
            case "flac":
            case "m4a":
            case "mp4":
            case "mkv":
            case "avi":
            case "mov":
            case "webm":
                return "#7C4DFF"; // Indigo
            case "pdf":
                return "#FF1744"; // Red
            case "zip":
            case "tar":
            case "gz":
            case "bz2":
            case "xz":
            case "rar":
            case "7z":
                return "#FF9100"; // Amber
            case "txt":
            case "md":
            case "json":
            case "xml":
            case "yaml":
            case "yml":
            case "conf":
            case "ini":
                return "#2979FF"; // Blue
            case "sh":
            case "py":
            case "js":
            case "ts":
            case "rs":
            case "go":
            case "c":
            case "cpp":
            case "h":
            case "java":
            case "html":
            case "css":
                return "#FF5252"; // Coral Red
            default:
                return Theme.surfaceText;
        }
    }

    // Outer frosted glass background
    StyledRect {
        anchors.fill: parent
        anchors.margins: 15
        radius: Theme.cornerRadius
        clip: true
        color: Theme.withAlpha(Theme.surfaceContainer, root.backgroundOpacity)
        border.color: root.editMode ? Theme.primary : Theme.withAlpha(Theme.outline, root.borderOpacity)
        border.width: root.editMode ? 2 : 1

        Item {
            anchors.fill: parent
            anchors.margins: Theme.spacingM

            // Sidebar toggle icon
            MouseArea {
                id: sidebarToggleBtn
                anchors.left: parent.left
                anchors.leftMargin: root.sidebarPinned ? folderDropdown.width : 0
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 0
                width: 20; height: 20
                z: 1
                visible: root.showHeader ? !root.sidebarPinned : false
                cursorShape: Qt.PointingHandCursor
                onClicked: folderDropdown.visible ? folderDropdown.close() : folderDropdown.open()

                states: [
                    State {
                        name: "topHeader"
                        when: root.headerPosition === "top"
                        AnchorChanges {
                            target: sidebarToggleBtn
                            anchors.top: parent.top
                            anchors.bottom: undefined
                        }
                    }
                ]

                DankIcon {
                    anchors.centerIn: parent
                    name: "menu"
                    size: 16
                    color: Theme.surfaceText
                    opacity: sidebarToggleBtn.containsMouse ? 1.0 : 0.7
                }
            }

            // Home button — navigate to user home directory
            MouseArea {
                id: homeBtn
                anchors.left: root.headerPosition === "top"
                    ? (backBtn.visible ? backBtn.right : (sidebarToggleBtn.visible ? sidebarToggleBtn.right : parent.left))
                    : (sidebarToggleBtn.visible ? sidebarToggleBtn.right : parent.left)
                anchors.leftMargin: root.headerPosition === "top"
? (backBtn.visible ? 8 : (sidebarToggleBtn.visible ? 8 : (root.sidebarPinned ? folderDropdown.width - 15 - Theme.spacingM + 8 + 10 : 8)))
            : (sidebarToggleBtn.visible ? 8 : (root.sidebarPinned ? folderDropdown.width - 15 - Theme.spacingM + 8 + 10 : 8))
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 0
                width: 20; height: 20

                states: [
                    State {
                        name: "topHeader"
                        when: root.headerPosition === "top"
                        AnchorChanges {
                            target: homeBtn
                            anchors.top: parent.top
                            anchors.bottom: undefined
                        }
                    }
                ]
                z: 1
                visible: root.showHeader
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    var homeUrl = Platform.StandardPaths.writableLocation(Platform.StandardPaths.HomeLocation).toString();
                    root.navigateToFolder(homeUrl);
                }

                DankIcon {
                    anchors.centerIn: parent
                    name: "home"
                    size: 18
                    color: homeBtn.containsMouse ? Theme.primary : Theme.surfaceText
                    opacity: homeBtn.containsMouse ? 1.0 : 0.7
                }
            }
 
            // Folder selector — always visible at bottom-left
            MouseArea {
                id: folderSelectorBtn
                visible: root.showHeader
                anchors.left: homeBtn.right
                anchors.leftMargin: 8
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 0

                states: [
                    State {
                        name: "topHeader"
                        when: root.headerPosition === "top"
                        AnchorChanges {
                            target: folderSelectorBtn
                            anchors.top: parent.top
                            anchors.bottom: undefined
                        }
                    }
                ]

                width: root.folderPathEditMode ? 200 : folderRow.implicitWidth
                height: 20
                z: 1
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onDoubleClicked: root.folderPathEditMode = true

                Row {
                    id: folderRow
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXS
                    visible: !root.folderPathEditMode
                    DankIcon { name: "folder_open"; size: 16; color: folderSelectorBtn.containsMouse ? Theme.primary : Theme.surfaceText; opacity: folderSelectorBtn.containsMouse ? 1.0 : 0.8; anchors.verticalCenter: parent.verticalCenter }
                    StyledText { text: root.showFullPath ? root.targetFolderUrl.replace("file://", "") : root.folderDisplayName; font.pixelSize: Theme.fontSizeSmall; font.bold: true; color: folderSelectorBtn.containsMouse ? Theme.primary : Theme.surfaceText; opacity: folderSelectorBtn.containsMouse ? 1.0 : 0.8; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideMiddle }
                    DankIcon { name: "arrow_drop_down"; size: 12; color: folderSelectorBtn.containsMouse ? Theme.primary : Theme.surfaceText; opacity: folderSelectorBtn.containsMouse ? 1.0 : 0.6; anchors.verticalCenter: parent.verticalCenter }
                }

                TextInput {
                    id: pathEditor
                    anchors.fill: parent
                    anchors.leftMargin: 2
                    visible: root.folderPathEditMode
                    text: root._cleanPath(root.targetFolderUrl)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    verticalAlignment: TextInput.AlignVCenter
                    selectByMouse: true
                    activeFocusOnTab: false

                    onTextEdited: pathCompletionDebounce.restart()

                    onVisibleChanged: {
                        if (visible) {
                            forceActiveFocus();
                            selectAll();
                            pathCompletionDebounce.restart();
                        }
                    }

                    Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Down) {
                            if (_pathCompletions.length > 0 && pathCompletionPopup.visible) {
                                _pathCompletionIndex = Math.min(_pathCompletionIndex + 1, _pathCompletions.length - 1);
                                event.accepted = true;
                            }
                        } else if (event.key === Qt.Key_Up) {
                            if (_pathCompletions.length > 0 && pathCompletionPopup.visible) {
                                _pathCompletionIndex = Math.max(_pathCompletionIndex - 1, 0);
                                event.accepted = true;
                            }
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            if (_pathCompletions.length > 0 && _pathCompletionIndex >= 0 && pathCompletionPopup.visible) {
                                // Navigate directly to the selected completion
                                var navPath = _pathCompletions[_pathCompletionIndex].fullPath;
                                pathCompletionPopup.close();
                                _pathCompletions = [];
                                root.navigateToFolder(navPath);
                                root.folderPathEditMode = false;
                                event.accepted = true;
                            }
                        } else if (event.key === Qt.Key_Tab) {
                            if (_pathCompletions.length > 0 && pathCompletionPopup.visible) {
                                // Navigate directly to the selected (or first) completion
                                var tabIdx = _pathCompletionIndex >= 0 ? _pathCompletionIndex : 0;
                                var tabPath = _pathCompletions[tabIdx].fullPath;
                                pathCompletionPopup.close();
                                _pathCompletions = [];
                                root.navigateToFolder(tabPath);
                                root.folderPathEditMode = false;
                                event.accepted = true;
                            }
                        } else if (event.key === Qt.Key_Escape) {
                            if (pathCompletionPopup.visible) {
                                pathCompletionPopup.close();
                                _pathCompletions = [];
                                event.accepted = true;
                            } else {
                                root.folderPathEditMode = false;
                                event.accepted = true;
                            }
                        }
                    }

                    onAccepted: {
                        pathCompletionPopup.close();
                        var path = text.trim();
                        if (path.length > 0) root.navigateToFolder(path);
                        root.folderPathEditMode = false;
                    }

                    onActiveFocusChanged: {
                        if (!activeFocus) {
                            pathCompletionPopup.close();
                            _pathCompletions = [];
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.color: Theme.primary
                        border.width: 1
                        radius: 4
                        z: -1
                    }
                }
            }

            // Premium Header (left content: file status)
            Item {
                id: headerContainer
                anchors.left: folderSelectorBtn.right
                anchors.leftMargin: 0
                anchors.right: settingsBox.left
                height: 24
                anchors.top: parent.top
                visible: root.showHeader

                states: [
                    State {
                        name: "bottom"
                        when: root.headerPosition === "bottom"
                        AnchorChanges {
                            target: headerContainer
                            anchors.top: undefined
                            anchors.bottom: parent.bottom
                        }
                    }
                ]

                // Left: File Status only (folder selector moved to bottom-left)
                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 4
                    height: parent.height
                    spacing: Theme.spacingS

                    // File Status
                    MouseArea {
                        id: fileStatusBtn
                        height: parent.height; width: fileStatusRow.implicitWidth
                        hoverEnabled: true; cursorShape: Qt.PointingHandCursor; visible: folderModel.count > 0
                        onClicked: mouse => {
                            if (quickMenu.visible) { quickMenu.close(); return; }
                            if (root.selectedFilePaths.length === 0) return;
                            const globalPos = mapToItem(root, mouse.x, mouse.y);
                            quickMenu.parent = root;
                            quickMenu.x = Math.max(0, Math.min(root.width - quickMenu.width, globalPos.x));
                            quickMenu.y = Math.max(0, Math.min(root.height - quickMenu.height, globalPos.y));
                            if (root.selectedFilePaths.length === 1) {
                                const path = root.selectedFilePaths[0];
                                quickMenu.currentPath = path;
                                quickMenu.currentName = path.split('/').pop();
                                for (let i = 0; i < filteredModel.count; i++) {
                                    if (filteredModel.get(i).filePath === path) { quickMenu.currentIsDir = filteredModel.get(i).fileIsDir; break; }
                                }
                            }
                            quickMenu.open();
                        }
                        Row {
                            id: fileStatusRow; anchors.verticalCenter: parent.verticalCenter; spacing: 4
                            StyledText {
                                text: {
                                    let c = folderModel.count, s = root.selectedFilePaths.length;
                                    let str = "(" + c + ")";
                                    if (s > 0) str += " [" + s + " " + i18n("selected") + "]";
                                    return str;
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: fileStatusBtn.containsMouse ? Theme.primary : Theme.surfaceVariantText
                                opacity: fileStatusBtn.containsMouse ? 1.0 : 0.6
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            StyledText { text: root.selectedFileInfo; font.pixelSize: Theme.fontSizeSmall - 1; color: Theme.surfaceVariantText; opacity: 0.7; anchors.verticalCenter: parent.verticalCenter; visible: root.selectedFileInfo !== ""; elide: Text.ElideRight }
                        }
                    }
                }
            }

            // Back button (top-left, visible when in subfolder)
            MouseArea {
                id: backBtn
                anchors.left: sidebarToggleBtn.visible ? sidebarToggleBtn.right : parent.left
                anchors.leftMargin: sidebarToggleBtn.visible ? 8 : (root.sidebarPinned ? folderDropdown.width - 15 - Theme.spacingM + 8 + 10 : 8)
                anchors.top: parent.top
                width: 20
                height: 24
                visible: root.folderHistory.length > 0
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.goBackFolder()
                z: 5

                DankIcon {
                    anchors.centerIn: parent
                    name: "arrow_back"
                    size: 16
                    color: backBtn.containsMouse ? Theme.primary : Theme.surfaceText
                    opacity: backBtn.containsMouse ? 1.0 : 0.7
                }
            }

            // Right-side controls (hidden when showHeader is off)
            Item {
                id: headerControls
                anchors.right: settingsBox.left
                anchors.rightMargin: Theme.spacingS
                anchors.top: parent.top
                width: Math.max(childrenRect.width, 60)
                height: 24
                visible: root.showHeader
                z: 10

                states: [
                    State {
                        name: "bottom"
                        when: root.headerPosition === "bottom"
                        AnchorChanges {
                            target: headerControls
                            anchors.top: undefined
                            anchors.bottom: parent.bottom
                        }
                    }
                ]

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingS

                    // Back to Top Button
                    MouseArea {
                        id: backToTopBtn
                        width: visible ? 20 : 0
                        height: 20
                        visible: root.isScrolledDown
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.scrollToTop()

                        Behavior on width { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }

                        DankIcon {
                            anchors.centerIn: parent
                            name: "arrow_upward"
                            size: 16
                            color: backToTopBtn.containsMouse ? Theme.primary : Theme.surfaceText
                            opacity: backToTopBtn.containsMouse ? 1.0 : 0.7
                        }
                    }

                    // Premium Dynamic Expanding Search Input
                    Rectangle {
                        id: headerSearchContainer
                        
                        // Explicitly expanded state matching App Launcher design
                        property bool expanded: false
                        
                        width: expanded ? 120 : 20
                        height: 20
                        radius: 10
                        color: expanded 
                            ? Theme.withAlpha(Theme.surfaceText, headerSearchField.activeFocus ? 0.12 : 0.08) 
                            : "transparent"
                        border.color: expanded 
                            ? (headerSearchField.activeFocus ? Theme.primary : Theme.withAlpha(Theme.surfaceText, 0.3)) 
                            : "transparent"
                        border.width: expanded ? 1 : 0
                        
                        anchors.verticalCenter: parent.verticalCenter
                        clip: true

                        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Behavior on border.color { ColorAnimation { duration: 150 } }

                        // Clicking on the container focuses the text input (which triggers expansion)
                        MouseArea {
                            anchors.fill: parent
                            visible: !headerSearchContainer.expanded
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                headerSearchContainer.expanded = true;
                                headerSearchField.forceActiveFocus();
                            }
                        }

                        DankIcon {
                            id: headerSearchIcon
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: headerSearchContainer.expanded ? 4 : (headerSearchContainer.width - size) / 2
                            name: "search"
                            size: 14
                            color: Theme.surfaceText
                            opacity: headerSearchField.activeFocus ? 1.0 : (headerSearchContainer.expanded ? 0.6 : 0.7)
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                        }

                        TextInput {
                            id: headerSearchField
                            anchors.left: headerSearchIcon.right
                    anchors.leftMargin: 8
                            anchors.right: headerClearBtn.visible ? headerClearBtn.left : parent.right
                            anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceText
                            selectByMouse: true
                            visible: headerSearchContainer.expanded
                            opacity: headerSearchContainer.expanded ? 1.0 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 150 } }

                            // Placeholder Text
                            Text {
                                text: i18n("Search...")
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceText
                                opacity: 0.35
                                visible: headerSearchField.text === "" && !headerSearchField.activeFocus
                            }

                            onTextChanged: root.searchPattern = text.trim()

                            // Escape collapses search and restores focus to main handler
                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Escape) {
                                    headerSearchField.text = "";
                                    root.searchPattern = "";
                                    headerSearchContainer.expanded = false;
                                    keyHandler.forceActiveFocus();
                                    event.accepted = true;
                                }
                            }
                        }

                        // Clear and Collapse button
                        MouseArea {
                            id: headerClearBtn
                            width: 12
                            height: 12
                            anchors.right: parent.right
                            anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            visible: headerSearchContainer.expanded
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            
                            DankIcon {
                                anchors.centerIn: parent
                                name: "close"
                                size: 10
                                color: Theme.surfaceText
                                opacity: headerClearBtn.containsMouse ? 0.9 : 0.5
                            }

                            onClicked: {
                                headerSearchField.text = "";
                                root.searchPattern = "";
                                headerSearchField.focus = false;
                                headerSearchContainer.expanded = false;
                            }
                        }
                    }

                    // Open terminal in current directory
                    MouseArea {
                        id: terminalBtn
                        width: 20
                        height: 20
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var dir = String(root.targetFolderUrl);
                            if (dir.startsWith("file://"))
                                dir = dir.substring(7);
                            if (dir.startsWith("localhost/"))
                                dir = dir.substring(9);
                            Quickshell.execDetached(["xdg-terminal-exec", "--dir=" + dir]);
                        }

                        DankIcon {
                            anchors.centerIn: parent
                            name: "terminal"
                            size: 16
                            color: terminalBtn.containsMouse ? Theme.primary : Theme.surfaceText
                            opacity: terminalBtn.containsMouse ? 1.0 : 0.7
                        }
                    }

                    // View Mode Switcher
                    MouseArea {
                        id: viewModeBtn
                        width: 20
                        height: 20
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: viewModeDropdown.visible ? viewModeDropdown.close() : viewModeDropdown.open()

                        DankIcon {
                            anchors.centerIn: parent
                            name: root.viewMode === "grid" ? "grid_view"
                                : root.viewMode === "list" ? "view_list"
                                : "view_module"
                            size: 16
                            color: viewModeBtn.containsMouse ? Theme.primary : Theme.surfaceText
                            opacity: viewModeBtn.containsMouse ? 1.0 : 0.7
                        }
                    }

                    // View Mode Dropdown
                    Popup {
                        id: viewModeDropdown
                        parent: viewModeBtn
                        width: 130
                        height: viewModeColumn.implicitHeight + Theme.spacingS * 2
                        padding: 0
        modal: false
        dim: false
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                        x: viewModeBtn.width - viewModeDropdown.width
                        y: root.headerPosition === "bottom" ? -height - 4 : viewModeBtn.height + 4

                        background: Rectangle { color: "transparent" }

        contentItem: Rectangle {
            color: Theme.withAlpha(Theme.surfaceContainer, 0.95)
            radius: Theme.cornerRadius
            border.color: Theme.withAlpha(Theme.outline, 0.15)
            border.width: 1
            clip: true
            focus: true
            Keys.onEscapePressed: { if (sidebarPinned) folderDropdown.close(); }

                            Column {
                                id: viewModeColumn
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: 2

                                Repeater {
                                    model: root._viewModeOptions

                                    delegate: Rectangle {
                                        width: parent.width
                                        height: 28
                                        radius: Theme.cornerRadius - 2
                                        color: vmArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.15) : "transparent"

                                        Row {
                                            anchors.left: parent.left
                                            anchors.leftMargin: Theme.spacingS
                                            anchors.right: parent.right
                                            anchors.rightMargin: Theme.spacingS
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: Theme.spacingS

                                            DankIcon {
                                                name: modelData.icon
                                                size: 14
                                                color: root.viewMode === modelData.value ? Theme.primary : Theme.surfaceText
                                                anchors.verticalCenter: parent.verticalCenter
                                            }

                                            StyledText {
                                                text: modelData.label
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.bold: root.viewMode === modelData.value
                                                color: root.viewMode === modelData.value ? Theme.primary : Theme.surfaceText
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }

                                        MouseArea {
                                            id: vmArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                viewModeDropdown.close();
                                                if (pluginService) {
                                                    pluginService.savePluginData(pluginId, "viewMode", modelData.value);
                                                }
                                            }
                                        }
                                    }
                }
            }
        }
    }

                    // Create Button (New Folder / New File)
                    MouseArea {
                        id: createBtn
                        width: 20
                        height: 20
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: createDropdown.open()

                        DankIcon {
                            anchors.centerIn: parent
                            name: "add"
                            size: 16
                            color: createBtn.containsMouse ? Theme.primary : Theme.surfaceText
                            opacity: createBtn.containsMouse ? 1.0 : 0.7
                        }
                    }

                    // Filter Button
                    MouseArea {
                        id: filterBtn
                        width: 20
                        height: 20
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: filterDropdown.open()

                        DankIcon {
                            anchors.centerIn: parent
                            name: "filter_list"
                            size: 16
                            color: (root.filterType !== "all" || root.filterTime !== "all") ? Theme.primary : (filterBtn.containsMouse ? Theme.primary : Theme.surfaceText)
                            opacity: (root.filterType !== "all" || root.filterTime !== "all" || filterBtn.containsMouse) ? 1.0 : 0.7
                        }
                    }

                    // Sort By Button
                    MouseArea {
                        id: sortByBtn
                        width: 20
                        height: 20
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: sortByDropdown.open()
 
                        DankIcon {
                            anchors.centerIn: parent
                            name: {
                                switch (root.sortBy) {
                                    case "time": return "schedule";
                                    case "size": return "bar_chart";
                                    case "type": return "category";
                                    default: return "sort_by_alpha";
                                }
                            }
                            size: 16
                            color: sortByBtn.containsMouse ? Theme.primary : Theme.surfaceText
                            opacity: sortByBtn.containsMouse ? 1.0 : 0.7
                        }
                    }
 
                }
            }

            // Desktop Widgets button (always visible at bottom)
            Item {
                id: desktopWidgetsBox
                anchors.right: settingsBox.left
                anchors.rightMargin: Theme.spacingS
                anchors.bottom: parent.bottom
                width: 20
                height: 24
                z: 10
                opacity: root.showHeader ? 1.0 : (dwBtn.containsMouse ? 1.0 : 0.05)
                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }

                MouseArea {
                    id: dwBtn
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: PopoutService.openSettingsWithTab("desktop_widgets")

                    DankIcon {
                        anchors.centerIn: parent
                        name: "widgets"
                        size: 16
                        color: dwBtn.containsMouse ? Theme.primary : Theme.surfaceText
                        opacity: dwBtn.containsMouse ? 1.0 : 0.7
                    }
                }
            }

            // Settings button (always visible at bottom-right)
            Item {
                id: settingsBox
                anchors.right: parent.right; anchors.rightMargin: 4
                anchors.bottom: parent.bottom
                width: 20
                height: 24
                z: 10
                opacity: root.showHeader ? 1.0 : (settingsBtn.containsMouse ? 1.0 : 0.05)
                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }

                MouseArea {
                    id: settingsBtn
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: settingsDropdown.visible ? settingsDropdown.close() : settingsDropdown.open()

                    DankIcon {
                        anchors.centerIn: parent
                        name: "settings"
                        size: 16
                        color: settingsBtn.containsMouse ? Theme.primary : Theme.surfaceText
                        opacity: settingsBtn.containsMouse ? 1.0 : 0.7
                    }
                }

                // Settings Popup
                Popup {
                    id: settingsDropdown
                    parent: settingsBtn
                    width: 220
                    height: Math.min(500, settingsColumn.implicitHeight + Theme.spacingM * 2)
                    padding: 0
                    modal: true
                    dim: false
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                    x: settingsBtn.width - settingsDropdown.width
                    y: -height - 4

                    background: Rectangle { color: "transparent" }

                    contentItem: Rectangle {
                color: Theme.withAlpha(Theme.surfaceContainer, 0.95)
                        radius: Theme.cornerRadius
                        border.color: Theme.withAlpha(Theme.outline, 0.15)
                        border.width: 1

                    
                        Column {
                            id: settingsColumn
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            StyledText {
                                text: i18n("Appearance")
                                font.pixelSize: Theme.fontSizeSmall
                                font.bold: true
                                color: Theme.surfaceText
                            }

                            // Background Opacity
                            Row { width: parent.width; height: 24; spacing: Theme.spacingS
                                StyledText { text: i18n("Bg Opacity"); font.pixelSize: Theme.fontSizeSmall - 1; color: Theme.surfaceVariantText; width: 85; anchors.verticalCenter: parent.verticalCenter }
                                Item { width: parent.width - 85 - 40; height: parent.height; anchors.verticalCenter: parent.verticalCenter
                                    Slider {
                                        id: bgSlider; anchors.verticalCenter: parent.verticalCenter; width: parent.width
                                        from: 0; to: 100; value: pluginData.backgroundOpacity ?? 0
                                        onMoved: { if (pluginService) pluginService.savePluginData(pluginId, "backgroundOpacity", Math.round(value)) }
                                    }
                                }
                                StyledText { text: Math.round(bgSlider.value) + "%"; font.pixelSize: Theme.fontSizeSmall - 1; color: Theme.surfaceText; width: 35; anchors.verticalCenter: parent.verticalCenter }
                            }

                            // Border Opacity
                            Row { width: parent.width; height: 24; spacing: Theme.spacingS
                                StyledText { text: i18n("Border Opacity"); font.pixelSize: Theme.fontSizeSmall - 1; color: Theme.surfaceVariantText; width: 85; anchors.verticalCenter: parent.verticalCenter }
                                Item { width: parent.width - 85 - 40; height: parent.height; anchors.verticalCenter: parent.verticalCenter
                                    Slider {
                                        id: borderSlider; anchors.verticalCenter: parent.verticalCenter; width: parent.width
                                        from: 0; to: 100; value: pluginData.borderOpacity ?? 100
                                        onMoved: { if (pluginService) pluginService.savePluginData(pluginId, "borderOpacity", Math.round(value)) }
                                    }
                                }
                                StyledText { text: Math.round(borderSlider.value) + "%"; font.pixelSize: Theme.fontSizeSmall - 1; color: Theme.surfaceText; width: 35; anchors.verticalCenter: parent.verticalCenter }
                            }

                            // SideBar Opacity
                            Row { width: parent.width; height: 24; spacing: Theme.spacingS
                                StyledText { text: i18n("SideBar Opacity"); font.pixelSize: Theme.fontSizeSmall - 1; color: Theme.surfaceVariantText; width: 85; anchors.verticalCenter: parent.verticalCenter }
                                Item { width: parent.width - 85 - 40; height: parent.height; anchors.verticalCenter: parent.verticalCenter
                                    Slider {
                                        id: sbSlider; anchors.verticalCenter: parent.verticalCenter; width: parent.width
                                        from: 0; to: 100; value: pluginData.folderDropdownOpacity ?? 95
                                        onMoved: { if (pluginService) pluginService.savePluginData(pluginId, "folderDropdownOpacity", Math.round(value)) }
                                    }
                                }
                                StyledText { text: Math.round(sbSlider.value) + "%"; font.pixelSize: Theme.fontSizeSmall - 1; color: Theme.surfaceText; width: 35; anchors.verticalCenter: parent.verticalCenter }
                            }

                            // Header Position
                            Row { width: parent.width; height: 24; spacing: Theme.spacingS
                                StyledText { text: i18n("Header"); font.pixelSize: Theme.fontSizeSmall - 1; color: Theme.surfaceVariantText; width: 85; anchors.verticalCenter: parent.verticalCenter }
                                Row { spacing: Theme.spacingXS; anchors.verticalCenter: parent.verticalCenter
                                    Repeater {
                                        model: root._headerPositionOptions
                                        delegate: Rectangle {
                                            width: 50; height: 22; radius: 4
                                            color: (root.headerPosition === modelData.val) ? Theme.primary : (hpArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.1) : "transparent")
                                            border.color: (root.headerPosition === modelData.val) ? Theme.primary : Theme.withAlpha(Theme.outline, 0.2)
                                            border.width: 1
                                            StyledText { anchors.centerIn: parent; text: modelData.label; font.pixelSize: Theme.fontSizeSmall - 1; color: (root.headerPosition === modelData.val) ? Theme.onPrimary : Theme.surfaceText }
                                            MouseArea { id: hpArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: { if (pluginService) pluginService.savePluginData(pluginId, "headerPosition", modelData.val); settingsDropdown.close() } } } }
                                }
                            }

                            // Show Header toggle
                            Row { width: parent.width; height: 24; spacing: Theme.spacingS
                                StyledText { text: i18n("Show Header"); font.pixelSize: Theme.fontSizeSmall - 1; color: Theme.surfaceVariantText; width: 85; anchors.verticalCenter: parent.verticalCenter }
                                Item { width: 40; height: parent.height; anchors.verticalCenter: parent.verticalCenter
                                    DankIcon {
                                        anchors.centerIn: parent; name: root.showHeader ? "toggle_on" : "toggle_off"; size: 24
                                        color: root.showHeader ? Theme.primary : Theme.surfaceVariantText
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                            onClicked: { root.showHeader = !root.showHeader; if (pluginService) pluginService.savePluginData(pluginId, "showHeader", root.showHeader); settingsDropdown.close() } } }
                                }
                            }

                            // Empty indicator color
                            Column { width: parent.width; spacing: 6
                                StyledText { text: i18n("Empty Color"); font.pixelSize: Theme.fontSizeSmall - 1; color: Theme.surfaceVariantText }
                                Row { spacing: 5
                                    Repeater {
                                        model: ["#FF1744", "#00E676", "#FFEA00", "#448AFF", "#D500F9", "#00BFA5", "#FF9100", "#E91E63", "#00BCD4", "#795548"]
                                        delegate: Rectangle {
                                            width: 14; height: 14; radius: 2
                                            color: modelData
                                            border.width: root.emptyColor === modelData ? 2 : 1
                                            border.color: root.emptyColor === modelData ? Theme.surfaceText : Theme.withAlpha(Theme.outline, 0.3)
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.emptyColor = modelData; if (pluginService) pluginService.savePluginData(pluginId, "emptyColor", modelData); settingsDropdown.close() } }
                                        }
                                    }
                                }
                            }

                            // Folder icon color
                            Column { width: parent.width; spacing: 6
                                StyledText { text: i18n("Folder Color"); font.pixelSize: Theme.fontSizeSmall - 1; color: Theme.surfaceVariantText }
                                Row { spacing: 5
                                    Repeater {
                                        model: ["", "#FF1744", "#00E676", "#FFEA00", "#448AFF", "#D500F9", "#00BFA5", "#FF9100", "#E91E63", "#00BCD4"]
                                        delegate: Rectangle {
                                            width: 14; height: 14; radius: modelData === "" ? 7 : 2
                                            color: modelData || Theme.primary
                                            border.width: root.folderColor === modelData ? 2 : 1
                                            border.color: root.folderColor === modelData ? Theme.surfaceText : Theme.withAlpha(Theme.outline, 0.3)
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.folderColor = modelData; if (pluginService) pluginService.savePluginData(pluginId, "folderColor", modelData); settingsDropdown.close() } }
                                        }
                                    }
                                }
                            }

                            // Language switcher — dropdown style
                            Item {
                                id: langSection
                                width: parent.width
                                height: langSectionCol.implicitHeight + 4

                                readonly property var _langModel: [
                                    { label: i18n("System Default"), code: "system" },
                                    { label: "中文", code: "zh_CN" },
                                    { label: "English", code: "en" },
                                    { label: "Deutsch", code: "de" },
                                    { label: "Español", code: "es" },
                                    { label: "Français", code: "fr" },
                                    { label: "日本語", code: "ja" },
                                    { label: "한국어", code: "ko" },
                                    { label: "Русский", code: "ru" },
                                    { label: "Tiếng Việt", code: "vi" }
                                ]
                                property bool langListOpen: false
                                readonly property string _currentLangLabel: {
                                    for (var i = 0; i < _langModel.length; i++) {
                                        if (_langModel[i].code === root.pluginLanguage)
                                            return _langModel[i].label;
                                    }
                                    return root.pluginLanguage;
                                }

                                Column {
                                    id: langSectionCol
                                    width: parent.width
                                    spacing: 2

                                    StyledText {
                                        text: i18n("Language")
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        font.bold: true
                                        color: Theme.surfaceText
                                    }

                                    // Dropdown button
                                    Rectangle {
                                        width: parent.width
                                        height: 28
                                        radius: 4
                                        color: langDropArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.1) : Theme.withAlpha(Theme.outline, 0.08)
                                        border.color: Theme.withAlpha(Theme.outline, 0.2)
                                        border.width: 1

                                        Row {
                                            anchors.fill: parent
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 8
                                            spacing: 4

                                            StyledText {
                                                text: langSection._currentLangLabel
                                                font.pixelSize: Theme.fontSizeSmall - 1
                                                color: Theme.surfaceText
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: parent.width - 24
                                                elide: Text.ElideRight
                                            }

                                            DankIcon {
                                                name: langSection.langListOpen ? "expand_less" : "expand_more"
                                                size: 16
                                                color: Theme.surfaceVariantText
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }

                                        MouseArea {
                                            id: langDropArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: langSection.langListOpen = !langSection.langListOpen
                                        }
                                    }

                                    // Dropdown list
                                    Rectangle {
                                        width: parent.width
                                        height: langSection.langListOpen ? Math.min(200, langListView.implicitHeight + 4) : 0
                                        radius: 4
                                        color: Theme.withAlpha(Theme.surfaceContainer, 0.98)
                                        border.color: Theme.withAlpha(Theme.outline, 0.15)
                                        border.width: 1
                                        clip: true
                                        visible: height > 0

                                        Flickable {
                                            anchors.fill: parent
                                            anchors.margins: 2
                                            contentHeight: langListView.implicitHeight
                                            boundsBehavior: Flickable.StopAtBounds

                                            Column {
                                                id: langListView
                                                width: parent.width

                                                Repeater {
                                                    model: langSection._langModel

                                                    delegate: Rectangle {
                                                        width: parent.width
                height: 20
                                                        radius: 2
                                                        color: {
                                                            if (root.pluginLanguage === modelData.code)
                                                                return Theme.withAlpha(Theme.primary, 0.15);
                                                            if (langItemArea.containsMouse)
                                                                return Theme.withAlpha(Theme.surfaceText, 0.06);
                                                            return "transparent";
                                                        }

                                                        StyledText {
                                                            text: modelData.label
                                                            font.pixelSize: Theme.fontSizeSmall - 1
                                                            color: root.pluginLanguage === modelData.code ? Theme.primary : Theme.surfaceText
                                                            font.weight: root.pluginLanguage === modelData.code ? Font.Medium : Font.Normal
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            anchors.left: parent.left
                                                            anchors.leftMargin: 8
                                                        }

                                                        MouseArea {
                                                            id: langItemArea
                                                            anchors.fill: parent
                                                            hoverEnabled: true
                                                            cursorShape: Qt.PointingHandCursor
                                                            onClicked: {
                                                                root.pluginLanguage = modelData.code;
                                                                if (pluginService)
                                                                    pluginService.savePluginData(pluginId, "pluginLanguage", modelData.code);
                                                                langSection.langListOpen = false;
    }
    Shortcut {
        sequence: StandardKey.Delete
        onActivated: {
            if (root.selectedFilePaths.length > 0) {
                var paths = root.selectedFilePaths.slice();
                root.clearSelection();
                for (var i = 0; i < paths.length; i++) {
                    Quickshell.execDetached(["gio", "trash", "--", root._cleanPath(paths[i])]);
                }
            }
        }
    }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                    }
                }
            }
            // Grid View container
            Item {
                id: filesContainer
                anchors.left: parent.left
                anchors.leftMargin: root.sidebarPinned ? folderDropdown.width : 0
                anchors.right: parent.right
                clip: true

                // Default anchors: header at top
                anchors.top: (root.showHeader && root.headerPosition === "top") ? headerContainer.bottom : parent.top
                anchors.topMargin: !root.showHeader ? Theme.spacingS : (root.headerPosition === "top" ? Theme.spacingS : 0)
                anchors.bottom: parent.bottom

                states: [
                    State {
                        name: "headerBottom"
                        when: root.showHeader && root.headerPosition === "bottom"
                        AnchorChanges {
                            target: filesContainer
                            anchors.top: parent.top
                            anchors.bottom: headerContainer.top
                        }
                        PropertyChanges {
                            target: filesContainer
                            anchors.topMargin: 0
                            anchors.bottomMargin: Theme.spacingS
                        }
                    }
                ]

                FolderListModel {
                    id: folderModel
                    folder: root.targetFolderUrl
                    showDirsFirst: true
                    showHidden: root.showHidden
                    sortField: root.folderSortField
                }

                GridView {
                    id: fileGrid
                    interactive: root.renamingFilePath === ""
                    // Center grid content horizontally so left/right borders stay equal
                    readonly property int _cols: Math.max(1, Math.floor((parent ? parent.width : root.cellSize) / root.cellSize))
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: _cols * root.cellSize
                    anchors.horizontalCenter: parent.horizontalCenter
                    cellWidth: root.cellSize
                    cellHeight: root.cellSize + 16
                    model: filteredModel
                    visible: root.viewMode === "grid"
                    boundsBehavior: Flickable.StopAtBounds
                    cacheBuffer: cellHeight * 3

                    // Smooth add/remove transitions
                    add: Transition {
                        NumberAnimation { properties: "opacity,scale"; from: 0; to: 1.0; duration: 100; easing.type: Easing.OutQuad }
                    }
                    remove: Transition {
                        NumberAnimation { property: "opacity"; to: 0; duration: 80 }
                    }

                    delegate: FileItemDelegate {
                        width: fileGrid.cellWidth
                        height: fileGrid.cellHeight
                        dmsFileManager: root
                        viewMode: "grid"
                        layoutMode: false
                        thumbnailSize: 20
                        launchScale: 0.92
                        pinIconSize: 16
                        labelPixelSize: Theme.fontSizeSmall + 1
                        labelMaxLines: 2
                        labelWrap: true
                        bgMargin: Theme.spacingXS
                        bgRadius: Theme.cornerRadius
                    }
                }

                // List View of files
                ListView {
                    id: fileList
                    interactive: root.renamingFilePath === ""
                    anchors.fill: parent
                    model: filteredModel
                    visible: root.viewMode === "list"
                    boundsBehavior: Flickable.StopAtBounds
                    spacing: 2
                    clip: true
                    cacheBuffer: 100

                    // Smooth add/remove transitions
                    add: Transition {
                        NumberAnimation { property: "opacity"; from: 0; to: 1.0; duration: 80 }
                    }
                    remove: Transition {
                        NumberAnimation { property: "opacity"; to: 0; duration: 60 }
                    }

                    delegate: FileItemDelegate {
                        width: fileList.width
                        height: Math.round(36 * root.sizeScale)
                        dmsFileManager: root
                        viewMode: "list"
                        layoutMode: true
                        thumbnailSize: Math.round(20 * root.sizeScale)
                        launchScale: 0.98
                        pinIconSize: 14
                        labelPixelSize: Theme.fontSizeSmall + 2
                        bgMargin: Theme.spacingXS
                        bgRadius: Theme.cornerRadius - 2
                    }
                }

                // Compact View of files (1 or 2 columns list layout)
                GridView {
                    id: fileCompact
                    interactive: root.renamingFilePath === ""
                    anchors.fill: parent
                    cellWidth: parent.width / 3
                    cellHeight: Math.round(30 * root.sizeScale)
                    model: filteredModel
                    visible: root.viewMode === "compact"
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true
                    cacheBuffer: 100

                    // Smooth add/remove transitions
                    add: Transition {
                        NumberAnimation { properties: "opacity,scale"; from: 0; to: 1.0; duration: 80 }
                    }
                    remove: Transition {
                        NumberAnimation { property: "opacity"; to: 0; duration: 60 }
                    }

                    delegate: FileItemDelegate {
                        width: fileCompact.cellWidth
                        height: Math.round(30 * root.sizeScale)
                        dmsFileManager: root
                        viewMode: "compact"
                        layoutMode: true
                        thumbnailSize: Math.round(16 * root.sizeScale)
                        launchScale: 0.98
                        pinIconSize: 12
                        labelPixelSize: Theme.fontSizeSmall + 1
                        bgMargin: Theme.spacingXS
                        bgRadius: Theme.cornerRadius - 2
                    }
                }

                // Background area for middle-click on empty space → new file dialog
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    z: -1
                    onClicked: mouse => {
                        if (previewPopup.opened) {
                            previewPopup.close();
                        } else if (root.renamingFilePath !== "") {
                            root.endInlineRename();
                        } else if (mouse.button === Qt.MiddleButton) {
                            createDialog.showFor(false);
                        }
                    }
                }

                // Wheel overlay — scroll, Ctrl+Wheel zooms, mouse side buttons for back/forward
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: false
                    acceptedButtons: Qt.ExtraButton1 | Qt.ExtraButton2
                    onWheel: wheel => {
                        if (wheel.modifiers & Qt.ControlModifier) {
                            let delta = wheel.angleDelta.y > 0 ? 2 : -2;
                            let newSize = Math.max(64, Math.min(128, root.cellSize + delta));
                            if (newSize !== root.cellSize) {
                                root.cellSize = newSize;
                                if (pluginService)
                                    pluginService.savePluginData(pluginId, "cellSize", newSize);
                            }
                            wheel.accepted = true;
                        } else {
                            var target = fileGrid.visible ? fileGrid :
                                         (fileList.visible ? fileList : fileCompact)
                            if (target && target.contentHeight > target.height) {
                                wheel.accepted = true
                                target.contentY = Math.max(0, Math.min(
                                    target.contentY - wheel.angleDelta.y,
                                    target.contentHeight - target.height))
                            }
                        }
                    }
                    onClicked: mouse => {
                        if (mouse.button === Qt.ExtraButton2 && root.folderHistory.length > 0)
                            root.goBackFolder();
                        else if (mouse.button === Qt.ExtraButton1 && root.forwardHistory.length > 0)
                            root.goForwardFolder();
                    }
                }

                // Placeholder when folder is empty or search returns no results
                Column {
                    anchors.centerIn: parent
                    spacing: Theme.spacingM
                    visible: filteredModel.count === 0 && folderModel.status === FolderListModel.Ready
                    width: parent.width * 0.8

                    DankIcon {
                        name: folderModel.count === 0 ? "folder_open" : "search_off"
                        size: 48
                        color: Theme.surfaceText
                        opacity: 0.25
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    StyledText {
                        text: folderModel.count === 0 
                            ? root.folderDisplayName + " " + i18n("is empty") 
                            : i18n("No search results found")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        opacity: 0.4
                        horizontalAlignment: Text.AlignHCenter
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }

                // Copy files dragged in from external windows into the current
                // folder (Drag & Drop In). Disabled for the read-only Trash view.
                DropArea {
                    id: dropArea
                    anchors.fill: parent
                    z: 100
                    enabled: root.folderType !== "trash"
                    keys: ["text/uri-list"]

                    onEntered: drag => {
                        if (drag.hasUrls)
                            drag.accept(Qt.CopyAction);
                        else
                            drag.accepted = false;
                    }
                    onDropped: drop => {
                        if (!drop.hasUrls)
                            return;
                        root.dropFiles(drop.urls);
                        drop.accept(Qt.CopyAction);
                    }

                    // Drop hint shown while dragging files over the widget
                    Rectangle {
                        anchors.fill: parent
                        visible: dropArea.containsDrag
                        radius: Theme.cornerRadius
                        // Darkened background overlay for focus
                        color: Qt.rgba(0, 0, 0, 0.5)
                        
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: Theme.withAlpha(Theme.primary, 0.15)
                            border.color: Theme.primary
                            border.width: 2
                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: Theme.spacingS

                            DankIcon {
                                name: "download"
                                size: 48
                                color: Theme.primary
                                anchors.horizontalCenter: parent.horizontalCenter
                            }

                            StyledText {
                                text: i18n("Drop to copy here")
                                font.pixelSize: Theme.fontSizeMedium
                                font.bold: true
                                color: Theme.primary
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                    }
                }

            }
        }
    }

    // Keyboard handler — inside StyledRect, as last child for highest z-order
    Item {
        id: keyHandler
        anchors.fill: parent
        focus: true

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    if (overwriteDialog.opened) { overwriteDialog.close(); root._pastePendingOps = []; root._pasteOverwriteAll = false; }
                    else if (renameDialog.opened) renameDialog.close();
                else if (infoDialog.opened) infoDialog.close();
                else if (createDialog.opened) createDialog.close();
                else if (createAppDialog.opened) createAppDialog.close();
                else if (createStackDialog.opened) createStackDialog.close();
                else if (quickMenu.opened) quickMenu.close();
                else if (createDropdown.opened) createDropdown.close();
                else if (sortByDropdown.opened) sortByDropdown.close();
                else if (filterDropdown.opened) filterDropdown.close();
                else if (viewModeDropdown.opened) viewModeDropdown.close();
                else if (settingsDropdown.opened) settingsDropdown.close();
                else if (root.folderHistory.length > 0) root.goBackFolder();
                event.accepted = true;
            }
        }

        Component.onCompleted: forceActiveFocus()
    }

    // Persist dimensions when resized
    onWidgetWidthChanged: {
        if (pluginService && widgetWidth !== pluginData.widgetWidth) {
            pluginService.savePluginData(pluginId, "widgetWidth", widgetWidth);
        }
    }

    onWidgetHeightChanged: {
        if (pluginService && widgetHeight !== pluginData.widgetHeight) {
            pluginService.savePluginData(pluginId, "widgetHeight", widgetHeight);
        }
    }

    // Quick Action Menu on Middle Click
    Popup {
        id: quickMenu
        width: 180
        height: menuColumn.implicitHeight + Theme.spacingS * 2
        padding: 0
        modal: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        property string currentPath: ""
        property string currentName: ""
        property bool currentIsDir: false

        background: Rectangle {
            color: "transparent"
        }

        contentItem: Rectangle {
            color: Theme.withAlpha(Theme.surfaceContainer, 0.95)
            radius: Theme.cornerRadius
            border.color: Theme.withAlpha(Theme.outline, 0.15)
            border.width: 1

            Column {
                id: menuColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: 2

                Repeater {
                    model: [
                        {
                            text: i18n("Open"),
                            icon: "open_in_new",
                            visible: true,
                            action: function() {
                                quickMenu.close();
                                for (let path of root.selectedFilePaths) {
                                    let clean = root._cleanPath(path);
                                    if (clean.endsWith(".desktop")) {
                                        root.launchDesktopFile(path);
                                    } else {
                                        root.execFile(clean);
                                    }
                                }
                                root.clearSelection();
                            }
                        },
                        {
                            text: i18n("Open with..."),
                            icon: "app_registration",
                            visible: root.selectedFilePaths.length === 1 && !quickMenu.currentPath.startsWith("stack://") && !quickMenu.currentIsDir,
                            action: function() {
                                quickMenu.close();
                                let clean = root._cleanPath(quickMenu.currentPath);
                                Quickshell.execDetached(["dms", "open", clean]);
                                root.clearSelection();
                            }
                        },
                        {
                            text: i18n("Float File"),
                            icon: "picture_in_picture",
                            visible: root.selectedFilePaths.length === 1 && (root.isImage(quickMenu.currentName) || quickMenu.currentName.toLowerCase().endsWith(".pdf")),
                            action: function() {
                                quickMenu.close();
                                const path = root.selectedFilePaths[0];
                                Quickshell.execDetached(["dms", "ipc", "call", "floaty", "floatFromUrl", "file://" + path]);
                            }
                        },
                        {
                            text: i18n("Copy"),
                            icon: "content_copy",
                            visible: false,
                            action: function() {
                                quickMenu.close();
                                const paths = root.selectedFilePaths;
                                const name = quickMenu.currentName;

                                // Single image file: use DMS clipboard.copyFile so it appears
                                // in the DMS clipboard history and can be pasted in any app.
                                if (paths.length === 1 && root.isImage(name)) {
                                    DMSService.sendRequest("clipboard.copyFile", { "filePath": paths[0] }, function(resp) {
                                        if (resp.error) {
                                            ToastService.showToast(i18n("Copy failed") + ": " + resp.error, ToastService.levelError);
                                        } else {
                                            ToastService.showToast(i18n("Image Copied") + ": " + name, ToastService.levelInfo);
                                        }
                                    });
                                    return;
                                }

                                // Multi-file or non-image: use wl-copy with the gnome URI
                                // format so the selection can be pasted into file managers.
                                // Note: dms cl copy cannot be used here because the DMS daemon
                                // intercepts and re-serves the entry, corrupting the content.
                                let uris = [];
                                for (let path of paths) {
                                    uris.push("file://" + path);
                                }
                                const cmd = "echo -ne \"copy\\n" + uris.join("\\n") + "\" | wl-copy -t x-special/gnome-copied-files";
                                Quickshell.execDetached(["bash", "-c", cmd]);

                                const label = paths.length > 1
                                    ? i18n("Copied %1 items").arg(paths.length)
                                    : i18n("File Copied") + ": " + name;
                                ToastService.showToast(label, ToastService.levelInfo);
                            }
                        },
                        {
                            text: i18n("Copy File Path"),
                            icon: "content_copy",
                            visible: true,
                            action: function() {
                                quickMenu.close();
                                const joinedPaths = root.selectedFilePaths.join("\n");
                                Quickshell.execDetached(["dms", "cl", "copy", joinedPaths]);
                                
                                let label = root.selectedFilePaths.length > 1
                                    ? i18n("Copied %1 paths").arg(root.selectedFilePaths.length)
                                    : i18n("Copied to Clipboard") + ": " + quickMenu.currentName;
                                ToastService.showToast(label, ToastService.levelInfo);
                            }
                        },
                        {
                            text: i18n("Copy Dir Path"),
                            icon: "folder_copy",
                            visible: true,
                            action: function() {
                                quickMenu.close();
                                let dirPath = root._cleanPath(String(root.targetFolderUrl));
                                Quickshell.execDetached(["dms", "cl", "copy", dirPath]);
                            }
                        },
                        {
                            actionName: "favorite",
                            visible: true,
                            action: function() {
                                quickMenu.close();
                                root.toggleFavorite(quickMenu.currentPath);
                            }
                        },
                        {
                            text: i18n("Add to Bookmarks"),
                            icon: "bookmark",
                            visible: root.selectedFilePaths.length === 1 && quickMenu.currentIsDir && !quickMenu.currentPath.startsWith("stack://"),
                            action: function() {
                                quickMenu.close();
                                root.addToGtkBookmarks(quickMenu.currentPath);
                            }
                        },
                        {
                            actionName: "pin",
                            visible: true,
                            action: function() {
                                quickMenu.close();
                                root.togglePin(quickMenu.currentPath);
                            }
                        },
                        {
                            text: i18n("Rename"),
                            icon: "edit",
                            visible: root.selectedFilePaths.length <= 1,
                            action: function() {
                                quickMenu.close();
                                renameDialog.showFor(quickMenu.currentPath, quickMenu.currentName, quickMenu.currentIsDir);
                            }
                        },
                        {
                            text: i18n("Information"),
                            icon: "info",
                            visible: root.selectedFilePaths.length <= 1 && !quickMenu.currentPath.startsWith("stack://"),
                            action: function() {
                                quickMenu.close();
                                infoDialog.showFor(quickMenu.currentPath, quickMenu.currentName, quickMenu.currentIsDir);
                            }
                        },
                        {
                            text: i18n("Group into Stack"),
                            icon: "layers",
                            visible: root.selectedFilePaths.length > 1 && root.selectedFilePaths.every(p => !p.startsWith("stack://")),
                            action: function() {
                                quickMenu.close();
                                createStackDialog.showFor(root.selectedFilePaths);
                            }
                        },
                        {
                            text: i18n("Ungroup Stack"),
                            icon: "layers_clear",
                            visible: root.selectedFilePaths.length === 1 && quickMenu.currentPath.startsWith("stack://"),
                            action: function() {
                                quickMenu.close();
                                let stackId = quickMenu.currentPath.substring(8);
                                root.ungroupStack(stackId);
                            }
                        },
                        { isSeparator: true },
                        {
                            text: i18n("Move to Trash"),
                            icon: "delete",
                            dangerous: true,
                            visible: root.selectedFilePaths.every(p => !p.startsWith("stack://")),
                            action: function() {
                                quickMenu.close();
                                const cleanPaths = root.selectedFilePaths.map(p => root._cleanPath(p));
                                Quickshell.execDetached(["gio", "trash"].concat(cleanPaths));
                                root.clearSelection();
                            }
                        }
                    ]

                    delegate: Rectangle {
                        width: parent.width
                        property bool isSeparator: !!modelData.isSeparator
                        property bool itemVisible: modelData.visible !== undefined ? modelData.visible : true
                        visible: itemVisible
                        height: !itemVisible ? 0 : (isSeparator ? 9 : 28)
                        radius: isSeparator ? 0 : Theme.cornerRadius - 2
                        color: isSeparator 
                            ? "transparent"
                            : (menuArea.containsMouse 
                                ? (modelData.dangerous ? Theme.withAlpha(Theme.error, 0.15) : Theme.withAlpha(Theme.primary, 0.15)) 
                                : "transparent")

                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width - Theme.spacingS * 2
                            height: 1
                            color: Theme.withAlpha(Theme.outline, 0.15)
                            visible: isSeparator
                        }

                        Row {
                            visible: !isSeparator
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            DankIcon {
                                name: modelData.actionName === "favorite"
                                    ? (root.favoritePaths.indexOf(quickMenu.currentPath) !== -1 ? "star" : "star_outline")
                                    : (modelData.actionName === "pin"
                                        ? "push_pin"
                                        : (modelData.icon || ""))
                                size: 14
                                color: modelData.dangerous && menuArea.containsMouse ? Theme.error : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !isSeparator && parent.parent.itemVisible
                            }

                            StyledText {
                                text: modelData.actionName === "favorite"
                                    ? (root.favoritePaths.indexOf(quickMenu.currentPath) !== -1 ? i18n("Remove from Favorites") : i18n("Add to Favorites"))
                                    : (modelData.actionName === "pin"
                                        ? (root.pinnedPaths.indexOf(quickMenu.currentPath) !== -1 ? i18n("Unpin from Top") : i18n("Pin to Top"))
                                        : (modelData.text || ""))
                                font.pixelSize: Theme.fontSizeSmall
                                color: modelData.dangerous && menuArea.containsMouse ? Theme.error : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                visible: !isSeparator && parent.parent.itemVisible
                            }
                        }

                        MouseArea {
                            id: menuArea
                            anchors.fill: parent
                            enabled: !isSeparator
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: modelData.action()
                        }
                    }
                }
            }
        }
    }

    // Trash Action Popup — middle-click in trash: Restore / Delete Permanently
    Popup {
        id: trashActionPopup
        width: 190
        height: menuColumnTrash.implicitHeight + Theme.spacingS * 2
        padding: 0
        modal: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        property string currentPath: ""
        property string currentName: ""

        background: Rectangle {
            color: "transparent"
        }

        contentItem: Rectangle {
            color: Theme.withAlpha(Theme.surfaceContainer, 0.95)
            radius: Theme.cornerRadius
            border.color: Theme.withAlpha(Theme.outline, 0.15)
            border.width: 1

            Column {
                id: menuColumnTrash
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: 2

                Repeater {
                    model: [
                        {
                            text: i18n("Restore"),
                            icon: "restore_from_trash",
                            dangerous: false,
                            action: function() {
                                trashActionPopup.close();
                                root.restoreFromTrash(trashActionPopup.currentPath);
                            }
                        },
                        {
                            text: i18n("Delete Permanently"),
                            icon: "delete_forever",
                            dangerous: true,
                            action: function() {
                                trashActionPopup.close();
                                root.deleteFromTrashPermanently(trashActionPopup.currentPath);
                            }
                        }
                    ]

                    delegate: Rectangle {
                        width: parent.width
                        property bool itemVisible: true
                        visible: itemVisible
                        height: 32
                        radius: Theme.cornerRadius - 2
                        color: trashMenuArea.containsMouse
                            ? (modelData.dangerous ? Theme.withAlpha(Theme.error, 0.15) : Theme.withAlpha(Theme.primary, 0.15))
                            : "transparent"

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            DankIcon {
                                name: modelData.icon || ""
                                size: 16
                                color: modelData.dangerous && trashMenuArea.containsMouse ? Theme.error : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: modelData.text || ""
                                font.pixelSize: Theme.fontSizeSmall
                                color: modelData.dangerous && trashMenuArea.containsMouse ? Theme.error : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            id: trashMenuArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: modelData.action()
                        }
                    }
                }
            }
        }
    }

    // Rename Dialog
    DmsFileManagerRenameDialog {
        id: renameDialog
        pluginLanguage: root.pluginLanguage
    }

    // Create Stack Dialog
    DmsFileManagerCreateStackDialog {
        id: createStackDialog
        pluginLanguage: root.pluginLanguage
    }

    // Info Dialog
    DmsFileManagerInfoDialog {
        id: infoDialog
        pluginLanguage: root.pluginLanguage
    }

    // Overwrite Confirmation Dialog
    Popup {
        id: overwriteDialog
        width: 320
        height: 200
        padding: 0
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape

        property var conflictNames: []

        x: parent ? Math.round((parent.width - width) / 2) : 0
        y: parent ? Math.round((parent.height - height) / 2) : 0

        background: Rectangle {
            color: "transparent"
        }

        contentItem: Rectangle {
            color: Theme.withAlpha(Theme.surfaceContainer, 0.95)
            radius: Theme.cornerRadius
            border.color: Theme.withAlpha(Theme.outline, 0.15)
            border.width: 1

            Column {
                anchors.fill: parent
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingS

                StyledText {
                    text: i18n("Overwrite existing files?")
                    font.bold: true
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                }

                StyledText {
                    width: parent.width
                    text: {
                        var names = overwriteDialog.conflictNames;
                        if (names.length <= 2) {
                            return names.join(", ");
                        }
                        return names.slice(0, 2).join(", ") + " +" + (names.length - 2);
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    opacity: 0.7
                    wrapMode: Text.WrapAnywhere
                    elide: Text.ElideRight
                    maximumLineCount: 2
                }

                Item { width: 1; height: 8 }

                Row {
                    width: parent.width
                    spacing: Theme.spacingS
                    layoutDirection: Qt.RightToLeft

                    DankButton {
                        text: i18n("Overwrite All")
                        backgroundColor: Theme.primary
                        textColor: Theme.primaryText
                        onClicked: {
                            overwriteDialog.close();
                            root._executePaste(root._pastePendingOps, true);
                        }
                    }

                    DankButton {
                        text: i18n("Skip")
                        backgroundColor: Theme.surfaceContainerHigh
                        textColor: Theme.surfaceText
                        onClicked: {
                            overwriteDialog.close();
                            root._executePaste(root._pastePendingOps, false);
                        }
                    }

                    DankButton {
                        text: i18n("Cancel")
                        backgroundColor: Theme.surfaceContainerHigh
                        textColor: Theme.surfaceText
                        onClicked: {
                            overwriteDialog.close();
                            root._pastePendingOps = [];
                            root._pasteOverwriteAll = false;
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    text: i18n("Files with the same name already exist in this folder.")
                    font.pixelSize: 10
                    color: Theme.surfaceText
                    opacity: 0.5
                    wrapMode: Text.WrapAnywhere
                }
            }
        }
    }

    // Create Folder/File Dialog
    DmsFileManagerCreateDialog {
        id: createDialog
        targetFolderUrl: root.targetFolderUrl
        pluginLanguage: root.pluginLanguage
    }

    // Create App Dialog
    DmsFileManagerCreateAppDialog {
        id: createAppDialog
        targetFolderUrl: root.targetFolderUrl
        pluginLanguage: root.pluginLanguage
    }

    property bool showFullPath: false
    property bool folderPathEditMode: false
    property var _pathCompletions: []
    property int _pathCompletionIndex: -1

    // Folder Switcher Dropdown Popup
    property bool sidebarPinned: pluginData.sidebarPinned ?? true
    onSidebarPinnedChanged: { if (pluginService) pluginService.savePluginData(pluginId, "sidebarPinned", sidebarPinned); }
    Popup {
        id: folderDropdown
        parent: root
        width: Math.min(root.width * 0.15, 240)
        height: root.height - 28
        padding: 0
        modal: !sidebarPinned
        dim: false
        closePolicy: sidebarPinned ? Popup.NoAutoClose : Popup.CloseOnPressOutside
        x: 15
        visible: sidebarPinned || opened
        y: 15

        background: Rectangle {
            color: "transparent"
        }

        contentItem: Rectangle {
            id: folderDropdownContent
            color: Theme.withAlpha(Theme.surfaceContainer, root.folderDropdownOpacity)
            radius: Theme.cornerRadius
            border.color: Theme.withAlpha(Theme.outline, 0.15)
            border.width: 1

            Flickable {
                id: folderDropdownFlick
                anchors.fill: parent
                contentHeight: folderDropdownColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ScrollBar.vertical: ScrollBar { 
                    policy: ScrollBar.AlwaysOn
                    width: 4
                    topPadding: 8
                    bottomPadding: 8
                }

                Column {
                id: folderDropdownColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: 2

                // Pin/unpin sidebar toggle
                Row {
                    width: parent.width
                    height: 24
                    visible: !isSeparator
                    anchors.right: parent.right

                    StyledText {
                        text: root.sidebarPinned ? "📌" : "📍"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.sidebarPinned = !root.sidebarPinned; }
                        }
                    }
                }

                Repeater {
                    model: root.folderDropdownModel

                    delegate: Rectangle {
                        width: parent.width
                        height: modelData.value === "separator" ? 10 : 28
                        radius: Theme.cornerRadius - 2
                        color: {
                            if (isSeparator) return "transparent";
                            if (root._dropDragActive && index === root._dropDragFromIdx)
                                return Theme.withAlpha(Theme.primary, 0.25);
                            if (dropdownItemArea.containsMouse)
                                return Theme.withAlpha(Theme.primary, 0.15);
                            return "transparent";
                        }

                         readonly property bool isSeparator: modelData.value === "separator"
                        readonly property bool isPinned: modelData.value === "pinned" || modelData.value === "bookmark"
                        readonly property bool isCustom: modelData.value === "custom"
                        readonly property bool isActiveDrive: modelData.value === "drive" && root.customFolderPath && modelData.path && (root.customFolderPath === modelData.path || root.customFolderPath.startsWith(modelData.path + "/"))

                        // Separator line
                        Rectangle {
                            anchors.left: parent.left; anchors.leftMargin: Theme.spacingS
                            anchors.right: parent.right; anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            height: 1
                            color: Theme.withAlpha(Theme.outline, 0.12)
                            visible: isSeparator
                        }

                        // Normal item row (hidden for separator)
                        Row {
                            visible: !isSeparator
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            DankIcon {
                                name: modelData.icon || "folder"
                                size: 14
                                color: isPinned ? Theme.primary : ((root.folderType === modelData.value || isActiveDrive || (modelData.value === "drives" && root._isOnDrive)) ? Theme.primary : Theme.surfaceText)
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: modelData.label
                                font.pixelSize: Theme.fontSizeSmall
                                font.bold: isPinned || (root.folderType === modelData.value && !isCustom) || isActiveDrive || (modelData.value === "drives" && root._isOnDrive)
                                color: isPinned ? Theme.primary : ((root.folderType === modelData.value && !isCustom) || isActiveDrive || (modelData.value === "drives" && root._isOnDrive) ? root.folderColor : Theme.surfaceText)
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                width: parent.width - (modelData.value === "favorite" || modelData.value === "bookmark" ? 25 : modelData.value === "trash" ? 40 : (modelData.value === "drive" && modelData.mounted) ? 25 : 0) - Theme.spacingS
                            }

                            // Delete button (favorites + bookmarks)
                            StyledText {
                                text: "✕"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.error
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.right: parent.right
                                visible: dropdownItemArea.containsMouse && (modelData.value === "favorite" || modelData.value === "bookmark")
                            }

                            // Eject button (mounted drives)
                            StyledText {
                                text: "⏏"
                                font.pixelSize: Theme.fontSizeSmall
                                color: root.folderColor
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.right: parent.right
                                visible: dropdownItemArea.containsMouse && modelData.value === "drive" && modelData.mounted
                            }

                        }

                        MouseArea {
                            id: dropdownItemArea
                            anchors.fill: parent
                            hoverEnabled: !isSeparator
                            cursorShape: isSeparator ? Qt.ArrowCursor : Qt.PointingHandCursor
                            visible: !isSeparator

                            onClicked: mouse => {
                                // Eject button on mounted drives
                                if (modelData.value === "drive" && modelData.mounted && mouse.x > parent.width - 25) {
                                    unmountProc.command = ["udisksctl", "unmount", "-b", modelData.device];
                                    unmountProc.pendingDevice = modelData.device;
                                    unmountProc.running = true;
                                    return;
                                }
                                // X button on favorites/bookmarks
                                if ((modelData.value === "favorite" || modelData.value === "bookmark") && mouse.x > parent.width - 25) {
                                    if (modelData.value === "favorite") {
                                        root.toggleFavorite(modelData.path);
                                    } else {
                                        root.removeBookmark(modelData.path);
                                    }
                                    return;
                                }
                                if (modelData.value !== "drives" && !root.sidebarPinned)
                                    folderDropdown.close();
                                if (isPinned) {
                                    root.navigateToFolder(modelData.path);
                                } else if (modelData.value === "favorite") {
                                    root.navigateToFolder(modelData.path);
                                } else if (modelData.value === "drive") {
                                    if (modelData.path && modelData.path !== "") {
                                        root.navigateToFolder(modelData.path);
                                    } else if (modelData.device) {
                                        mountProc.command = ["udisksctl", "mount", "-b", modelData.device];
                                        mountProc.pendingDevice = modelData.device;
                                        mountProc.running = true;
                                        folderDropdown.close();
                                    }
                                } else if (modelData.value === "drives") {
                                    root._rebuildDriveList();
                                    driveListPopup.open();
                                } else {
                                    // Default standard folder type
                                    var stdPath = root.resolveStandardFolderPath(modelData.value);
                                    if (stdPath !== "") {
                                        root.navigateToFolder(stdPath);
                                        // Restore correct folderType (navigateToFolder overrides to "custom")
                                        root.folderType = modelData.value;
                                        if (pluginService) {
                                            pluginService.savePluginData(pluginId, "folderType", modelData.value);
                                        }
                                    }
                                }
                            }
                        }

                        // Drag-to-reorder grip handle (separate MouseArea overlaying left 16px)
                        MouseArea {
                            id: gripDragArea
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: 16
                            visible: !isSeparator && !isCustom
                            cursorShape: Qt.SizeAllCursor
                            preventStealing: true

                            onPressed: mouse => {
                                root._dropDragActive = true;
                                root._dropDragFromIdx = index;
                                root._dropDragToIdx = index;
                                folderDropdownFlick.interactive = false;
                            }

                            onPositionChanged: mouse => {
                                if (!root._dropDragActive) return;
                                var pt = mapToItem(folderDropdownColumn, mouse.x, mouse.y);
                                var targetIdx = root._dragTargetIdx(pt.y);
                                targetIdx = root._clampDragTarget(root._dropDragFromIdx, targetIdx);
                                if (targetIdx !== root._dropDragToIdx) {
                                    root._dropDragToIdx = targetIdx;
                                    dropIndicator.y = root._dropIndicatorY(targetIdx);
                                }
                            }

                            onReleased: {
                                root._finishDrag();
                                dropIndicator.y = 0;
                            }
                        }

                        // Empty trash button (on top of all MouseAreas)
                        StyledText {
                            text: i18n("Empty")
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: emptyBtn.containsMouse ? "#FF1744" : Theme.error
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            visible: !isSeparator && root.folderType === "trash" && modelData.value === "trash"

                            MouseArea {
                                id: emptyBtn
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    emptyTrashConfirm.open();
                                }
                            }
                        }
                    }
                }
            }
        }

        // Drop indicator overlay for drag-to-reorder
        Rectangle {
            id: dropIndicator
            visible: root._dropDragActive
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.spacingS
            anchors.rightMargin: Theme.spacingS
            height: 2
            y: 0
            color: Theme.primary
            radius: 1
            z: 10
        }

        // Empty trash confirmation dialog
        Popup {
            id: emptyTrashConfirm
            parent: folderDropdownContent
            width: 180
            height: 80
            x: (parent.width - width) / 2
            y: (parent.height - height) / 2
            padding: 0
            modal: true
            dim: true
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

            background: Rectangle {
                color: Theme.surfaceContainer
                radius: Theme.cornerRadius
                border.color: Theme.withAlpha(Theme.outline, 0.15)
                border.width: 1
            }

            contentItem: Column {
                anchors.centerIn: parent
                spacing: 8

                StyledText {
                    text: i18n("Empty Trash")
                    font.pixelSize: Theme.fontSizeSmall
                    font.bold: true
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12

                    Rectangle {
                        width: 60; height: 24; radius: 4
                        color: Theme.error
                        StyledText {
                            text: i18n("Empty")
                            color: "white"
                            font.pixelSize: Theme.fontSizeSmall - 1
                            anchors.centerIn: parent
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                Quickshell.execDetached(["gio", "trash", "--empty"]);
                                folderModel.folder = Qt.resolvedUrl(root.targetFolderUrl);
                                emptyTrashConfirm.close();
                            }
                        }
                    }

                    Rectangle {
                        width: 60; height: 24; radius: 4
                        color: Theme.surfaceVariant
                        StyledText {
                            text: i18n("Cancel")
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall - 1
                            anchors.centerIn: parent
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: emptyTrashConfirm.close()
                        }
                    }
                }
            }
        }
    }
}

    // Drive list popup (opened from folderDropdown "Drives" entry)
    Popup {
        id: driveListPopup
        parent: folderDropdownContent
        width: 320
        height: Math.min(driveListColumn.implicitHeight + Theme.spacingS * 2, 400)
        padding: 0
        x: folderDropdown.width + 4
        y: 0
        modal: false
        dim: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            color: Theme.withAlpha(Theme.surfaceContainer, root.folderDropdownOpacity)
            radius: Theme.cornerRadius
            border.color: Theme.withAlpha(Theme.outline, 0.15)
            border.width: 1
        }

        contentItem: Column {
            id: driveListColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingS
            spacing: 2

            StyledText {
                text: i18n("Drives")
                font.pixelSize: Theme.fontSizeSmall
                font.bold: true
                color: Theme.surfaceVariantText
                height: 24
                verticalAlignment: Text.AlignVCenter
            }

            Rectangle {
                height: 1
                color: Theme.withAlpha(Theme.outline, 0.12)
            }

            Repeater {
                model: root.driveListModel

                delegate: Rectangle {
                    id: driveDelegateRoot
                    width: parent.width
                    height: 28
                    radius: Theme.cornerRadius - 2
                    color: driveItemArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.15) : "transparent"

                    readonly property var _d: modelData

                    // Icon — left side
                    DankIcon {
                        id: driveDelIcon
                        x: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        name: modelData.icon || "hard_drive"
                        size: 14
                        color: modelData.mounted ? Theme.primary : Theme.surfaceVariantText
                    }

                    // Size text — right side
                    StyledText {
                        id: driveDelSize
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.size
                        font.pixelSize: Theme.fontSizeSmall - 2
                        color: Theme.surfaceVariantText
                        visible: modelData.size !== ""
                    }

                    // Label + subtitle — middle, filling remaining space
                    Column {
                        anchors.left: driveDelIcon.right
                        anchors.leftMargin: Theme.spacingS
                        anchors.right: driveDelSize.left
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1
                        clip: true

                        StyledText {
                            text: modelData.label
                            font.pixelSize: Theme.fontSizeSmall
                            font.bold: true
                            color: modelData.mounted ? Theme.surfaceText : Theme.surfaceVariantText
                            elide: Text.ElideRight
                            width: parent.width
                        }

                        StyledText {
                            text: modelData.mounted ? modelData.path : (modelData.device + " · " + i18n("unmounted"))
                            font.pixelSize: Theme.fontSizeSmall - 2
                            color: Theme.surfaceVariantText
                            opacity: 0.7
                            elide: Text.ElideRight
                            width: parent.width
                        }
                    }

                    MouseArea {
                        id: driveItemArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (modelData.mounted && modelData.path && modelData.path !== "") {
                                driveListPopup.close();
                                if (!root.sidebarPinned) folderDropdown.close();
                                root._currentDriveInfo = { label: modelData.label, path: modelData.path, icon: modelData.icon || "hard_drive" };
                                root.navigateToFolder(modelData.path);
                                root._isOnDrive = true;
                                buildFolderDropdownModel();
                            } else if (modelData.device) {
                                driveListPopup.close();
                                mountProc.command = ["udisksctl", "mount", "-b", modelData.device];
                                mountProc.pendingDevice = modelData.device;
                                mountProc.running = true;
                            }
                        }
                    }
                }
            }

            Item { height: 4; width: 1 }
        }
    }

    // Create Dropdown Popup
    Popup {
        id: createDropdown
        parent: createBtn
        width: 140
        height: createDropdownColumn.implicitHeight + Theme.spacingS * 2
        padding: 0
        modal: true
        dim: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        x: createBtn.width - createDropdown.width
        y: root.headerPosition === "bottom" ? -height - 4 : createBtn.height + 4

        background: Rectangle {
            color: "transparent"
        }

        contentItem: Rectangle {
            color: Theme.withAlpha(Theme.surfaceContainer, 0.95)
            radius: Theme.cornerRadius
            border.color: Theme.withAlpha(Theme.outline, 0.15)
            border.width: 1

            Column {
                id: createDropdownColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: 2

                        Repeater {
                            model: root._createNewOptions

                    delegate: Rectangle {
                        width: parent.width
                        height: 28
                        radius: Theme.cornerRadius - 2
                        color: createDropdownItemArea.containsMouse 
                            ? Theme.withAlpha(Theme.primary, 0.15) 
                            : "transparent"

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            DankIcon {
                                name: modelData.icon
                                size: 14
                                color: Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: modelData.label
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            id: createDropdownItemArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                createDropdown.close();
                                if (modelData.value === "app") {
                                    createAppDialog.show();
                                } else {
                                    createDialog.showFor(modelData.value === "folder");
                                }
                            }
                        }
                    }
                }
            }
        }
    }



    // Sort By Dropdown Popup
    Popup {
        id: sortByDropdown
        parent: sortByBtn
        width: 140
        height: sortByDropdownColumn.implicitHeight + Theme.spacingS * 2
        padding: 0
        modal: true
        dim: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        x: sortByBtn.width - sortByDropdown.width
        y: root.headerPosition === "bottom" ? -height - 4 : sortByBtn.height + 4

        background: Rectangle {
            color: "transparent"
        }

        contentItem: Rectangle {
            color: Theme.withAlpha(Theme.surfaceContainer, 0.95)
            radius: Theme.cornerRadius
            border.color: Theme.withAlpha(Theme.outline, 0.15)
            border.width: 1

            Column {
                id: sortByDropdownColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: 2

                        Repeater {
                            model: root._sortOptions

                    delegate: Rectangle {
                        width: parent.width
                        height: 28
                        radius: Theme.cornerRadius - 2
                        color: sortByArea.containsMouse 
                            ? Theme.withAlpha(Theme.primary, 0.15) 
                            : "transparent"

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            DankIcon {
                                name: modelData.icon
                                size: 14
                                color: root.sortBy === modelData.value ? Theme.primary : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: modelData.label
                                font.pixelSize: Theme.fontSizeSmall
                                font.bold: root.sortBy === modelData.value
                                color: root.sortBy === modelData.value ? Theme.primary : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            id: sortByArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                sortByDropdown.close();
                                if (pluginService) {
                                    pluginService.savePluginData(pluginId, "sortBy", modelData.value);
                                }
                            }
                        }
                    }
                }
            }
        }
    }



    // Filter Dropdown Popup
    Popup {
        id: filterDropdown
        parent: filterBtn
        width: 160
        height: filterDropdownColumn.implicitHeight + Theme.spacingS * 2
        padding: 0
        modal: true
        dim: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        x: filterBtn.width - filterDropdown.width
        y: root.headerPosition === "bottom" ? -height - 4 : filterBtn.height + 4
 
        background: Rectangle {
            color: "transparent"
        }
 
        contentItem: Rectangle {
            color: Theme.withAlpha(Theme.surfaceContainer, 0.95)
            radius: Theme.cornerRadius
            border.color: Theme.withAlpha(Theme.outline, 0.15)
            border.width: 1
 
            Column {
                id: filterDropdownColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: 4
 
                // Section 1: File Type
                StyledText {
                    text: i18n("File Type")
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.bold: true
                    color: Theme.surfaceVariantText
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingS
                }
 
                        Repeater {
                            model: root._fileTypeOptions
 
                    delegate: Rectangle {
                        width: parent.width
                        height: 24
                        radius: Theme.cornerRadius - 2
                        color: typeArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.15) : "transparent"
 
                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS
 
                            DankIcon {
                                name: modelData.icon
                                size: 12
                                color: root.filterType === modelData.value ? Theme.primary : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
 
                            StyledText {
                                text: modelData.label
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.bold: root.filterType === modelData.value
                                color: root.filterType === modelData.value ? Theme.primary : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
 
                        MouseArea {
                            id: typeArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.filterType = modelData.value;
                                filterDropdown.close();
                            }
                        }
                    }
                }
 
                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.withAlpha(Theme.outline, 0.1)
                }
 
                // Section 2: Time
                StyledText {
                    text: i18n("Time Modified")
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.bold: true
                    color: Theme.surfaceVariantText
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingS
                }
 
                        Repeater {
                            model: root._timeFilterOptions

                    delegate: Rectangle {
                        width: parent.width
                        height: 24
                        radius: Theme.cornerRadius - 2
                        color: timeArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.15) : "transparent"

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            DankIcon {
                                name: modelData.icon
                                size: 12
                                color: root.filterTime === modelData.value ? Theme.primary : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
 
                            StyledText {
                                text: modelData.label
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.bold: root.filterTime === modelData.value
                                color: root.filterTime === modelData.value ? Theme.primary : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
 
                        MouseArea {
                            id: timeArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.filterTime = modelData.value;
                                filterDropdown.close();
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.withAlpha(Theme.outline, 0.1)
                }

                // Show Hidden Files toggle
                Rectangle {
                    width: parent.width
                    height: 28
                    radius: Theme.cornerRadius - 2
                    color: hiddenArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.15) : "transparent"

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS

                        DankIcon {
                            name: root.showHidden ? "visibility" : "visibility_off"
                            size: 14
                            color: root.showHidden ? Theme.primary : Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: i18n("Show Hidden Files")
                            font.pixelSize: Theme.fontSizeSmall - 1
                            font.bold: root.showHidden
                            color: root.showHidden ? Theme.primary : Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: hiddenArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.showHidden = !root.showHidden;
                            if (pluginService)
                                pluginService.savePluginData(pluginId, "showHidden", root.showHidden);
                            filterDropdown.close();
                        }
                    }
                }
            }
        }
    }

    // Drive list for picker Mounts popup
    property var _driveEntries: []
    property var driveListModel: []

    function _rebuildDriveList() {
        var list = [];
        for (var i = 0; i < root._driveEntries.length; i++) {
            var de = root._driveEntries[i];
            if (de.label === "Windows") continue;
            list.push({
                label: de.label,
                path: de.path,
                device: de.device,
                mounted: de.mounted,
                icon: de.icon,
                size: de.size || "",
                fstype: de.fstype || ""
            });
        }
        root.driveListModel = list;
    }

    Process {
        id: lsblkProc
        command: ["lsblk", "-o", "NAME,FSTYPE,MOUNTPOINT,LABEL,SIZE,TYPE", "-J"]
        stdout: StdioCollector { id: lsblkOut }
        onExited: function(exitCode, exitStatus) {
            if (exitCode !== 0 || lsblkOut.text.trim() === "") return;
            var json, result = [];
            try { json = JSON.parse(lsblkOut.text); } catch (e) { return; }
            var devices = json.blockdevices || [];
            for (var di = 0; di < devices.length; di++)
                root._scanDevice(devices[di], result);
            root._driveEntries = result;
            // Rebuild dropdown model with latest drive data (mounted + unmounted)
            buildFolderDropdownModel();
            root._rebuildDriveList();
        }
    }

    Process {
        id: mountProc
        property string pendingDevice: ""
        stdout: StdioCollector {}
        onExited: function(exitCode, exitStatus) {
            if (exitCode === 0 && mountProc.pendingDevice)
                rescanTimer.start();
            mountProc.pendingDevice = "";
        }
    }

    Process {
        id: unmountProc
        property string pendingDevice: ""
        stdout: StdioCollector {}
        onExited: function(exitCode, exitStatus) {
            if (exitCode === 0 && unmountProc.pendingDevice)
                rescanTimer.start();
            unmountProc.pendingDevice = "";
        }
    }

    Timer {
        id: rescanTimer
        interval: 400
        repeat: false
        onTriggered: { lsblkProc.running = true; }
    }

    function _scanDevice(dev, result) {
        if (dev.type === "disk" && dev.children) {
            for (var ci = 0; ci < dev.children.length; ci++)
                root._scanDevice(dev.children[ci], result);
            return;
        }
        if (dev.type !== "part" && dev.type !== "crypt") return;
        if (!dev.fstype || dev.fstype === "") return;
        if (dev.fstype === "swap") return;
        if (dev.fstype === "vfat" && dev.mountpoint === "/boot/efi") return;
        // Skip mounted system partitions not under user-accessible mount points
        if (dev.mountpoint && dev.mountpoint.indexOf("/media/") !== 0 && dev.mountpoint.indexOf("/run/media/") !== 0 && dev.mountpoint.indexOf("/mnt/") !== 0) return;

        var dispName = dev.label;
        if (!dispName && dev.mountpoint)
            dispName = dev.mountpoint.split("/").filter(function(s) { return s !== ""; }).pop() || dev.name;
        if (!dispName)
            dispName = dev.name;
        var mounted = !!dev.mountpoint;
        var fs = dev.fstype || "";
        var icon = "hard_drive";
        result.push({ label: dispName, path: dev.mountpoint || "", device: "/dev/" + dev.name, mounted: mounted, icon: icon, size: dev.size || "" });
    }

    // _scanDrives removed — lsblk runs on driveScanTimer

    // ── File Preview Popup (Space key) ────────────────────────────────────────
    Shortcut {
        sequence: "Ctrl+S"
        enabled: previewPopup.opened && previewPopup.isText
        onActivated: previewPopup._saveTextFile()
    }
    Popup {
        id: previewPopup
        width: root.width
        height: root.height
        modal: true
        dim: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onClosed: {
            root._previewBusy = false;
            keyHandler.forceActiveFocus();
            crossFadeAnim.stop();
            _effectActive = false;
            _effectiveTransition = "";
            _transitionProgress = 0;
            nextImg.source = "";
            mediaPlayer.stop();
            _slideshowRunning = false;
            slideshowTimer.stop();
            // Reset text state. Do NOT clear textFileLoader.path — that
            // starts an async load from "" whose onLoadFailed can race with
            // the next onFilePathChanged, corrupting _textContent.
            _textContent = "";
            _textLoading = false;
            textLoadTimer.stop();
            currentImg.source = "";
        }
        onAboutToShow: {
            // Preload image just before the popup becomes visible — at this
            // point the Image is in the active scene graph and loading will
            // actually begin (setting source while the popup is closed is
            // deferred by Qt).  This gives the image a head start on decoding
            // while the popup transition completes.
            root._previewBusy = false; // Safety: unstick if previous open failed
            if (isImage)
                currentImg.source = "file://" + filePath;
        }
        onOpened: {
            root._previewBusy = false;
            contentItem.forceActiveFocus();
            if (isVideo) {
                mediaPlayer.source = "";
                reloadVideo.start();
            }
            if (isImage) {
                // Load the image for initial popup open. Once loaded, the
                // crossfade system handles subsequent transitions (wheel,
                // slideshow) by loading into nextImg and swapping on finish.
                // There is no source binding on currentImg — the binding
                // would race with _crossFadeTo, loading the new path into
                // BOTH currentImg and nextImg simultaneously.
                crossFadeAnim.stop();
                previewPopup._effectActive = false;
                previewPopup._effectiveTransition = "";
                previewPopup._transitionProgress = 0;
                nextImg.source = "";
                currentImg.source = "file://" + filePath;
                _imageNameVisible = true;
                hideImageNameTimer.restart();
            }
            if (isText) {
                // Ensure text loads even when onFilePathChanged didn't fire
                // because filePath was set to the same value (close+reopen
                // of the same file without navigating elsewhere).
                if (!_textContent && !_textLoading) {
                    _textLoading = true;
                    textFileLoader.path = "file://" + filePath;
                    textLoadTimer.restart();
                }
            }
        }

        Timer {
            id: reloadVideo
            interval: 50
            repeat: false
            onTriggered: {
                mediaPlayer.source = "file://" + previewPopup.filePath;
                mediaPlayer.play();
            }
        }
        anchors.centerIn: parent
        padding: 0

        property string filePath: ""
        property string fileName: filePath.split("/").pop() || ""
        property string fileExt: fileName.split(".").pop().toLowerCase() || ""
        property string _textContent: ""
        property bool _textLoading: false
        property int _currentIndex: -1
        property bool _wheelLocked: false
        property int _selectedSubTrack: -1
        property bool _imageNameVisible: true
        property bool _slideshowRunning: false
        property real _transitionProgress: 0
        property bool _effectActive: false
        property string _transitionEffect: "random"
        property string _effectiveTransition: ""
        readonly property var _availableEffects: ["none", "fade", "wipe", "disc", "stripes", "iris bloom", "pixelate", "portal", "wave", "mosaic", "diamond", "glitch", "random"]

        function _saveTextFile() {
            if (!isText) return;
            var content = _textContent || "";
            var fpath = filePath;
            // Escape content for Python single-quoted string literal
            var escaped = content
                .replace(/\\/g, "\\\\")
                .replace(/'/g, "\\'")
                .replace(/\n/g, "\\n")
                .replace(/\r/g, "\\r")
                .replace(/\t/g, "\\t")
                .replace(/\f/g, "\\f");
            Quickshell.execDetached(["python3", "-c",
                "open('" + fpath.replace(/'/g, "'\\''") + "','w').write('" + escaped + "')"
            ]);
        }

        Shortcut {
            sequence: "Ctrl+S"
            onActivated: previewPopup._saveTextFile()
        }

        Timer {
            id: slideshowTimer
            interval: 30000
            repeat: true
            onTriggered: {
                if (!previewPopup._slideshowRunning) return;
                var step = 1;
                for (var i = previewPopup._currentIndex + step; i < filteredModel.count; i++) {
                    var item = filteredModel.get(i);
                    if (!item.fileIsDir) {
                        previewPopup._currentIndex = i;
                        previewPopup.filePath = item.filePath;
                        return;
                    }
                }
                for (var j = 0; j < previewPopup._currentIndex; j++) {
                    var item2 = filteredModel.get(j);
                    if (!item2.fileIsDir) {
                        previewPopup._currentIndex = j;
                        previewPopup.filePath = item2.filePath;
                        return;
                    }
                }
            }
        }

        Timer {
            id: hideImageNameTimer
            interval: 3000
            repeat: false
            onTriggered: previewPopup._imageNameVisible = false
        }

        function _resetImageNameTimer() {
            _imageNameVisible = true;
            hideImageNameTimer.restart();
        }
        onFilePathChanged: {
            _textContent = "";
            _textLoading = false;
            if (isText) {
                _textLoading = true;
                textFileLoader.path = "file://" + filePath;
                textLoadTimer.restart();
            }
            // In-popup wheel/slideshow transitions: use crossfade system.
            if (isImage && filePath && previewPopup.opened)
                imagePreviewContainer._crossFadeTo(filePath);
        }

        Timer {
            id: textLoadTimer
            interval: 15000
            repeat: false
            onTriggered: {
                if (previewPopup._textLoading) {
                    previewPopup._textContent = "(error: timeout)";
                    previewPopup._textLoading = false;
                }
            }
        }

        Timer {
            id: wheelUnlockTimer
            interval: 100
            repeat: false
            onTriggered: previewPopup._wheelLocked = false
        }

        function _wheelSwitch(delta) {
            if (previewPopup._wheelLocked) return;
            previewPopup._wheelLocked = true;
            wheelUnlockTimer.restart();
            var step = delta > 0 ? -1 : 1;
            for (var i = _currentIndex + step; i >= 0 && i < filteredModel.count; i += step) {
                var item = filteredModel.get(i);
                if (!item.fileIsDir) {
                    _currentIndex = i;
                    filePath = item.filePath;
                    return;
                }
            }
        }

        function _formatTime(ms) {
            if (!ms || ms <= 0) return "0:00";
            var totalSec = Math.floor(ms / 1000);
            var min = Math.floor(totalSec / 60);
            var sec = totalSec % 60;
            return min + ":" + (sec < 10 ? "0" : "") + sec;
        }
        readonly property var imageExts: ["png", "jpg", "jpeg", "gif", "bmp", "webp", "svg"]
        readonly property var textExts: ["txt", "md", "py", "js", "qml", "json", "xml", "html", "css", "cpp", "h", "c", "sh", "yml", "yaml", "ini", "cfg", "conf", "log", "toml", "rs", "go", "ts"]
        readonly property var videoExts: ["mkv", "mp4", "avi", "mov", "webm", "flv", "wmv", "m4v", "mpg", "mpeg"]
        readonly property bool isImage: imageExts.indexOf(fileExt) !== -1
        readonly property bool isText: textExts.indexOf(fileExt) !== -1
        readonly property bool isVideo: videoExts.indexOf(fileExt) !== -1

        background: Rectangle {
            color: Theme.surfaceContainer
            radius: Theme.cornerRadius
            border.color: Theme.withAlpha(Theme.outline, 0.2)
            border.width: 1
        }

        contentItem: Item {
            focus: true
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Space || event.key === Qt.Key_Escape) {
                    event.accepted = true;
                    previewPopup.close();
                } else if (event.key === Qt.Key_S && event.modifiers & Qt.ControlModifier) {
                    event.accepted = true;
                    previewPopup._saveTextFile();
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                onWheel: wheel => {
                    if (previewPopup.isImage) {
                        previewPopup._wheelSwitch(wheel.angleDelta.y);
                    }
                }
            }

            // FileView — non-visual data loader, sibling of preview pages
            FileView {
                id: textFileLoader
                onLoaded: { previewPopup._textContent = text(); previewPopup._textLoading = false; }
                onLoadFailed: { previewPopup._textContent = "(error)"; previewPopup._textLoading = false; }
            }

            // ====== Image preview page ======
            // Independent overlapping pages — no Column! Each fills the full
            // content area with its own layout. Only one page is visible at
            // a time. This completely decouples the three preview types.
            Item {
                id: imagePreviewContainer
                visible: previewPopup.isImage
                anchors.fill: parent
                anchors.margins: Theme.spacingM

                Image {
                    id: currentImg
                    anchors.fill: parent
                    source: ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    sourceSize.width: parent.width
                    sourceSize.height: parent.height
                    onStatusChanged: {
                        if (status === Image.Error && source !== "")
                            console.debug("previewPopup: Image load error for", source);
                    }
                }

                Image {
                    id: nextImg
                    anchors.fill: parent
                    source: ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    sourceSize.width: parent.width
                    sourceSize.height: parent.height
                }

                ShaderEffectSource {
                    id: srcA
                    sourceItem: previewPopup._effectActive ? currentImg : null
                    hideSource: previewPopup._effectActive
                    live: previewPopup._effectActive
                    anchors.fill: parent
                }

                ShaderEffectSource {
                    id: srcB
                    sourceItem: previewPopup._effectActive ? nextImg : null
                    hideSource: previewPopup._effectActive
                    live: previewPopup._effectActive
                    anchors.fill: parent
                }

                ShaderEffect {
                    visible: previewPopup._effectiveTransition === "fade"
                    anchors.fill: parent
                    property variant source1: srcA; property variant source2: srcB
                    property real progress: previewPopup._transitionProgress
                    fragmentShader: Qt.resolvedUrl("Shaders/qsb/wp_fade.frag.qsb")
                }
                ShaderEffect {
                    visible: previewPopup._effectiveTransition === "wipe"
                    anchors.fill: parent
                    property variant source1: srcA; property variant source2: srcB
                    property real progress: previewPopup._transitionProgress
                    property real smoothness: 0.05; property real direction: 0
                    fragmentShader: Qt.resolvedUrl("Shaders/qsb/wp_wipe.frag.qsb")
                }
                ShaderEffect {
                    visible: previewPopup._effectiveTransition === "disc"
                    anchors.fill: parent
                    property variant source1: srcA; property variant source2: srcB
                    property real progress: previewPopup._transitionProgress
                    property real smoothness: 0.05
                    property real aspectRatio: width / height
                    property real centerX: 0.5; property real centerY: 0.5
                    fragmentShader: Qt.resolvedUrl("Shaders/qsb/wp_disc.frag.qsb")
                }
                ShaderEffect {
                    visible: previewPopup._effectiveTransition === "stripes"
                    anchors.fill: parent
                    property variant source1: srcA; property variant source2: srcB
                    property real progress: previewPopup._transitionProgress
                    property real smoothness: 0.05
                    property real count: 8; property real angle: 0
                    fragmentShader: Qt.resolvedUrl("Shaders/qsb/wp_stripes.frag.qsb")
                }
                ShaderEffect {
                    visible: previewPopup._effectiveTransition === "iris bloom"
                    anchors.fill: parent
                    property variant source1: srcA; property variant source2: srcB
                    property real progress: previewPopup._transitionProgress
                    fragmentShader: Qt.resolvedUrl("Shaders/qsb/wp_iris_bloom.frag.qsb")
                }
                ShaderEffect {
                    visible: previewPopup._effectiveTransition === "pixelate"
                    anchors.fill: parent
                    property variant source1: srcA; property variant source2: srcB
                    property real progress: previewPopup._transitionProgress
                    fragmentShader: Qt.resolvedUrl("Shaders/qsb/wp_pixelate.frag.qsb")
                }
                ShaderEffect {
                    visible: previewPopup._effectiveTransition === "portal"
                    anchors.fill: parent
                    property variant source1: srcA; property variant source2: srcB
                    property real progress: previewPopup._transitionProgress
                    fragmentShader: Qt.resolvedUrl("Shaders/qsb/wp_portal.frag.qsb")
                }
                ShaderEffect {
                    visible: previewPopup._effectiveTransition === "wave"
                    anchors.fill: parent
                    property variant source1: srcA; property variant source2: srcB
                    property real progress: previewPopup._transitionProgress
                    fragmentShader: Qt.resolvedUrl("Shaders/qsb/custom_wave.frag.qsb")
                }
                ShaderEffect {
                    visible: previewPopup._effectiveTransition === "mosaic"
                    anchors.fill: parent
                    property variant source1: srcA; property variant source2: srcB
                    property real progress: previewPopup._transitionProgress
                    fragmentShader: Qt.resolvedUrl("Shaders/qsb/custom_mosaic.frag.qsb")
                }
                ShaderEffect {
                    visible: previewPopup._effectiveTransition === "diamond"
                    anchors.fill: parent
                    property variant source1: srcA; property variant source2: srcB
                    property real progress: previewPopup._transitionProgress
                    fragmentShader: Qt.resolvedUrl("Shaders/qsb/custom_diamond.frag.qsb")
                }
                ShaderEffect {
                    visible: previewPopup._effectiveTransition === "glitch"
                    anchors.fill: parent
                    property variant source1: srcA; property variant source2: srcB
                    property real progress: previewPopup._transitionProgress
                    fragmentShader: Qt.resolvedUrl("Shaders/qsb/custom_glitch.frag.qsb")
                }

                NumberAnimation {
                    id: crossFadeAnim
                    target: previewPopup
                    property: "_transitionProgress"
                    from: 0.0; to: 1.0
                    duration: 800
                    easing.type: Easing.InOutCubic
                    onFinished: {
                        currentImg.source = nextImg.source;
                        nextImg.source = "";
                        previewPopup._transitionProgress = 0.0;
                        previewPopup._effectActive = false;
                        previewPopup._effectiveTransition = "";
                    }
                }

                function _crossFadeTo(newPath) {
                    if (!newPath) return;
                    crossFadeAnim.stop();
                    previewPopup._effectActive = false;
                    previewPopup._effectiveTransition = "";
                    previewPopup._transitionProgress = 0;
                    nextImg.source = "";

                    var effect = previewPopup._transitionEffect;
                    if (effect === "random") {
                        var avail = previewPopup._availableEffects.filter(function(e) { return e !== "none" && e !== "random"; });
                        effect = avail[Math.floor(Math.random() * avail.length)];
                    }
                    if (effect === "none") {
                        currentImg.source = "file://" + newPath;
                        return;
                    }
                    previewPopup._effectiveTransition = effect;
                    nextImg.source = "file://" + newPath;
                    previewPopup._effectActive = true;
                    crossFadeAnim.from = 0;
                    crossFadeAnim.to = 1;
                    crossFadeAnim.restart();
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.ArrowCursor
                    onPositionChanged: previewPopup._resetImageNameTimer()
                    onEntered: previewPopup._resetImageNameTimer()
                    onWheel: {
                        previewPopup._resetImageNameTimer();
                        previewPopup._wheelSwitch(wheel.angleDelta.y);
                    }
                }
            }

            // ====== Text preview page ======
            // Use Loader to destroy the TextArea when not viewing text.
            // This frees all text-layout memory so image decoding has no
            // competition for main-thread / heap resources.
            Loader {
                id: textPreviewLoader
                active: previewPopup.isText
                visible: active
                anchors.fill: parent
                anchors.margins: Theme.spacingM
                sourceComponent: ScrollView {
                    anchors.fill: parent
                    clip: true

                    TextArea {
                        id: textPreviewArea
                        font.pixelSize: Theme.fontSizeSmall + 1
                        color: Theme.surfaceText
                        selectionColor: Qt.rgba(0, 0.7, 0, 0.35)
                        selectedTextColor: Theme.surfaceText
                        text: previewPopup._textContent || ""
                        placeholderText: previewPopup._textLoading ? i18n("Loading\u2026") : ""
                        placeholderTextColor: Theme.surfaceVariantText
                        wrapMode: TextEdit.Wrap
                        onTextChanged: previewPopup._textContent = text
                        background: Rectangle {
                            color: "transparent"
                            border.color: textPreviewArea.activeFocus ? Theme.withAlpha(Theme.surfaceText, 0.3) : "transparent"
                            border.width: 1
                            radius: 4
                        }
                    }
                }
            }

            // ====== Video preview page ======
            Item {
                visible: previewPopup.isVideo
                anchors.fill: parent
                anchors.margins: Theme.spacingM

                MediaPlayer {
                    id: mediaPlayer
                    source: "file://" + previewPopup.filePath
                    videoOutput: videoOutput
                    audioOutput: AudioOutput { }
                    autoPlay: true
                    activeSubtitleTrack: -1
                }

                VideoOutput {
                    id: videoOutput
                    anchors.fill: parent
                    fillMode: VideoOutput.Stretch
                }

                MouseArea {
                    id: videoMA
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                    z: 2
                }

                Column {
                    z: 1
                    anchors.left: parent.left; anchors.leftMargin: 8
                    anchors.right: parent.right; anchors.rightMargin: 8
                    anchors.bottom: parent.bottom; anchors.bottomMargin: 4
                    spacing: 2
                    opacity: videoMA.containsMouse ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    Row {
                        visible: mediaPlayer.subtitleTracks.length > 0
                        anchors.right: parent.right
                        spacing: 4
                        Repeater {
                            model: mediaPlayer.subtitleTracks
                             delegate: StyledText {
                                text: modelData.label || modelData.language || ("Track " + model.index)
                            font.pixelSize: Theme.fontSizeSmall - 1
                                color: previewPopup._selectedSubTrack === model.index ? "yellow" : "white"
                                font.bold: previewPopup._selectedSubTrack === model.index
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        mediaPlayer.activeSubtitleTrack = model.index;
                                        previewPopup._selectedSubTrack = model.index;
                                    }
                                }
                            }
                        }
                        StyledText {
                            text: i18n("Off")
                            font.pixelSize: Theme.fontSizeSmall - 2
                            color: previewPopup._selectedSubTrack === -1 ? "yellow" : "white"
                            font.bold: previewPopup._selectedSubTrack === -1
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    mediaPlayer.activeSubtitleTrack = -1;
                                    previewPopup._selectedSubTrack = -1;
                                }
                            }
                        }
                    }

                    Slider {
                        id: videoSlider
                        width: parent.width
                        from: 0
                        to: mediaPlayer.duration || 1
                        value: videoSlider.pressed ? videoSlider.value : mediaPlayer.position
                        live: true
                        onMoved: mediaPlayer.setPosition(videoSlider.value)
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: mediaPlayer.playbackState === MediaPlayer.PlayingState ? mediaPlayer.pause() : mediaPlayer.play()
                }
            }

            // ====== Unsupported file type ======
            StyledText {
                visible: !previewPopup.isImage && !previewPopup.isText && !previewPopup.isVideo
                text: i18n("Preview not available for this file type")
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                anchors.centerIn: parent
            }

            // Bottom bar: filename left, save hint right
            Item {
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingM
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingM
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 6
                height: 20
                opacity: previewPopup.isVideo ? (videoMA.containsMouse ? 1.0 : 0.0)
                       : (previewPopup.isImage ? (previewPopup._imageNameVisible ? 1.0 : 0.0) : 1.0)
                Behavior on opacity { NumberAnimation { duration: 300 } }

                StyledText {
                    anchors.left: parent.left
                    anchors.right: previewPopup.isVideo ? timeRow.left
                                : (previewPopup.isImage ? slideshowControls.left : saveHint.left)
                    text: previewPopup.fileName
                    font.pixelSize: Theme.fontSizeSmall + 2
                    font.bold: true
                    color: Theme.primary
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                // Slideshow controls (bottom-right, for images)
                Row {
                    id: slideshowControls
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: previewPopup.isImage
                    spacing: 2

                    // Effect selector
                    Repeater {
                        model: previewPopup._availableEffects
                        delegate: StyledText {
                            text: modelData
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: previewPopup._transitionEffect === modelData ? "yellow" : "white"
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: previewPopup._transitionEffect = modelData
                            }
                        }
                    }

                    StyledText { text: "|"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall - 3 }

                    // Delay time selector
                    Repeater {
                        model: [3, 5, 10, 30, 60, 120]
                        delegate: StyledText {
                            text: modelData + "s"
                            font.pixelSize: Theme.fontSizeSmall - 2
                            color: slideshowTimer.interval === modelData * 1000 ? "yellow" : "white"
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: slideshowTimer.interval = modelData * 1000
                            }
                        }
                    }

                    // Play/Stop button
                    StyledText {
                        text: previewPopup._slideshowRunning ? "⏸" : "▶"
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: previewPopup._slideshowRunning ? "yellow" : "white"
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                previewPopup._slideshowRunning = !previewPopup._slideshowRunning;
                                if (previewPopup._slideshowRunning)
                                    slideshowTimer.start();
                                else
                                    slideshowTimer.stop();
                            }
                        }
                    }
                }

                // Video time: right side
                Row {
                    id: timeRow
                    anchors.right: parent.right
                    visible: previewPopup.isVideo
                    spacing: 2
                    StyledText { text: previewPopup._formatTime(mediaPlayer.position); font.pixelSize: Theme.fontSizeSmall-1; color: Theme.primary }
                    StyledText { text: "/"; font.pixelSize: Theme.fontSizeSmall-1; color: Theme.surfaceVariantText }
                    StyledText { text: previewPopup._formatTime(mediaPlayer.duration); font.pixelSize: Theme.fontSizeSmall-1; color: Theme.primary }
                }

                // Save hint: right side (for text files)
                StyledText {
                    id: saveHint
                    anchors.right: parent.right
                    visible: previewPopup.isText
                    text: i18n("Ctrl+S to save  ·  Esc/Space to close")
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.primary
                }
            }
        }
    }

    // ── Path Editor Autocomplete ──────────────────────────────────────────
    Timer {
        id: pathCompletionDebounce
        interval: 150
        onTriggered: root._fetchPathCompletions()
    }

    Popup {
        id: pathCompletionPopup
        parent: root
        padding: 0
        margins: 0
        closePolicy: Popup.CloseOnPressOutside

        background: Rectangle {
            color: Theme.withAlpha(Theme.surfaceContainer, 0.95)
            radius: Theme.cornerRadius
            border.color: Theme.withAlpha(Theme.outline, 0.15)
            border.width: 1
        }

        contentItem: ListView {
            id: pathCompletionList
            implicitHeight: Math.min(contentHeight, 280)
            clip: true
            model: _pathCompletions
            currentIndex: _pathCompletionIndex

            delegate: Rectangle {
                anchors.left: parent.left
                anchors.leftMargin: 4
                anchors.right: parent.right
                anchors.rightMargin: 4
                height: 28
                radius: 4
                color: pathCompletionList.currentIndex === index
                    ? Theme.withAlpha(Theme.primary, 0.15)
                    : (delegateMouse.containsMouse ? Theme.withAlpha(Theme.primary, 0.08) : "transparent")

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    DankIcon {
                        name: modelData.isDir ? "folder" : "description"
                        size: 14
                        anchors.verticalCenter: parent.verticalCenter
                        color: modelData.isDir ? Theme.primary : Theme.surfaceText
                    }
                    StyledText {
                        text: modelData.display
                        font.pixelSize: Theme.fontSizeSmall
                        color: pathCompletionList.currentIndex === index ? Theme.primary : Theme.surfaceText
                        font.bold: pathCompletionList.currentIndex === index
                    }
                }

                MouseArea {
                    id: delegateMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root._selectPathCompletion(index)
                }
            }

            highlightMoveDuration: 0
            highlightResizeDuration: 0
        }
    }
}
