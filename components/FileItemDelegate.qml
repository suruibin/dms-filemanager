import QtQuick

// FileItemDelegate — shared delegate for grid/list/compact views.
// IMPORTANT: Do NOT import Quickshell or qs modules here.
// All external function calls go through delegate.dmsFileManager wrapper functions.
Item {
    id: delegate

    // ── Required model properties ──────────────────────────────────────────────
    required property string filePath
    required property string fileName
    required property bool   fileIsDir
    required property int    index
    required property string displayBaseName
    required property string iconName
    required property string iconColor
    required property string itemType
    required property bool   isDesktop
    required property string appIcon
    required property bool   isStack
    required property bool   isEmpty
    required property string belongingStackId
    required property var    dmsFileManager

    // ── View-mode parameters (set by FolderView.qml) ───────────────────────────
    property string viewMode:       "list"
    property bool   layoutMode:     true    // false=column(grid), true=row(list/compact)
    property real   thumbnailSize:  20
    property real   launchScale:    0.98
    property real   pinIconSize:    14
    property int    labelPixelSize: 12
    property int    labelMaxLines:  1
    property bool   labelWrap:      false
    property real   bgMargin:       2
    property real   bgRadius:       4

    // ── Computed visuals ───────────────────────────────────────────────────────
    property bool isLaunching: false

    readonly property bool isSelected: delegate.dmsFileManager
        ? delegate.dmsFileManager.selectedPathsSet[filePath] !== undefined : false
    readonly property bool editing: delegate.dmsFileManager && delegate.filePath !== ""
        && delegate.dmsFileManager.renamingFilePath === delegate.filePath
        && delegate.dmsFileManager.viewMode === delegate.viewMode
    readonly property bool _pinned: delegate.dmsFileManager
        ? delegate.dmsFileManager.pinnedPaths.indexOf(filePath) !== -1 : false
    readonly property bool _isFavorite: delegate.dmsFileManager
        ? delegate.dmsFileManager.favoritePaths.indexOf(filePath) !== -1 : false
    readonly property bool _isCut: delegate.dmsFileManager && delegate.dmsFileManager.cutMode
        && delegate.dmsFileManager.copiedFilePaths.indexOf(filePath) !== -1
    readonly property bool _isCopy: delegate.dmsFileManager && !delegate.dmsFileManager.cutMode
        && delegate.dmsFileManager.copiedFilePaths.indexOf(filePath) !== -1

    // Colors matching Theme.primary / Theme.surfaceText (hardcoded since Theme not available)
    readonly property color _primary:     Qt.rgba(0.39, 0.59, 1.0, 1.0)
    readonly property color _surfaceText: Qt.rgba(1, 1, 1, 1)

    readonly property color _bgNormal: ma.containsMouse
        ? (belongingStackId !== ""
            ? (isStack ? Qt.rgba(_primary.r, _primary.g, _primary.b, 0.22) : Qt.rgba(_primary.r, _primary.g, _primary.b, 0.12))
            : Qt.rgba(1, 1, 1, 0.06))
        : (belongingStackId !== ""
            ? (isStack ? Qt.rgba(_primary.r, _primary.g, _primary.b, 0.12) : Qt.rgba(_primary.r, _primary.g, _primary.b, 0.05))
            : "transparent")
    readonly property color _bgColor: isLaunching
        ? Qt.rgba(_primary.r, _primary.g, _primary.b, 0.3)
        : (isSelected ? Qt.rgba(_primary.r, _primary.g, _primary.b, 0.15) : _bgNormal)
    readonly property color _borderColor: isLaunching
        ? _primary
        : (isSelected ? _primary
            : (belongingStackId !== ""
                ? (isStack ? _primary : Qt.rgba(_primary.r, _primary.g, _primary.b, 0.25))
                : "transparent"))
    readonly property int _borderWidth: isLaunching ? 2 : (isSelected ? 1 : (belongingStackId !== "" ? 1 : 0))

    // ── Launch pulse ───────────────────────────────────────────────────────────
    SequentialAnimation {
        id: launchPulse
        running: false
        NumberAnimation { target: delegate; property: "scale"; to: delegate.launchScale; duration: 100; easing.type: Easing.OutQuad }
        NumberAnimation { target: delegate; property: "scale"; to: 1.02;     duration: 150; easing.type: Easing.OutBack }
        NumberAnimation { target: delegate; property: "scale"; to: 1.0;      duration: 100; easing.type: Easing.OutQuad }
    }

    Timer {
        id: launchTimer
        interval: 800; repeat: false
        onTriggered: delegate.isLaunching = false
    }

    // ── Drag removed — use Ctrl+C/V instead ───────────────────────────────────


    // ── Background & interaction ────────────────────────────────────────────────
    Rectangle {
        id: bgRect
        anchors.fill: parent
        anchors.margins: delegate.bgMargin
        radius: delegate.bgRadius
        color: delegate._bgColor
        border.color: delegate._borderColor
        border.width: delegate._borderWidth

        // Grid layout (column: icon above + name below)
        Column {
            anchors.fill: parent
            anchors.margins: 4
            spacing: 2
            visible: !delegate.layoutMode

            Item {
                width: parent.width
                height: parent.height - 28
                DmsFileManagerThumbnail {
                    anchors.fill: parent
                    filePath: delegate.filePath; fileName: delegate.fileName
                    isDir: delegate.fileIsDir; appIcon: delegate.appIcon
                    iconName: delegate.iconName; iconColor: delegate.iconColor
                    itemType: delegate.itemType
                    sizeScale: delegate.dmsFileManager ? delegate.dmsFileManager.sizeScale : 1
                    hover: ma.containsMouse
                }
                // Empty indicator dot for grid view (0-byte files + empty folders)
                Rectangle {
                    anchors.centerIn: parent
                    width: 8; height: 8; radius: 4
                    color: delegate.dmsFileManager ? delegate.dmsFileManager.emptyColor : "red"
                    visible: delegate.isEmpty
                }
                // Favorite star on icon center - click to remove, show X on hover
                Item {
                    anchors.centerIn: parent
                    width: 24; height: 24
                    visible: delegate._isFavorite
                    z: 1

                    Text {
                        anchors.centerIn: parent
                        text: favStarMA.containsMouse ? "✕" : "★"
                        color: favStarMA.containsMouse ? "red" : "#FFD700"
                        font.pixelSize: delegate.pinIconSize + 4
                    }

                    MouseArea {
                        id: favStarMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (delegate.dmsFileManager) delegate.dmsFileManager.toggleFavorite(delegate.filePath);
                        }
                    }
                }
            }
            Text {
                width: parent.width
                visible: !delegate.editing
                font.pixelSize: delegate.labelPixelSize
                text: delegate.displayBaseName
                color: _surfaceText
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                maximumLineCount: delegate.labelMaxLines
                wrapMode: delegate.labelWrap ? Text.WrapAnywhere : Text.NoWrap
                opacity: ma.containsMouse ? 1.0 : 0.85
            }
        }

        // List/compact layout (row: icon left + name right)
        Row {
            anchors.fill: parent
            anchors.leftMargin: 6; anchors.rightMargin: 6
            spacing: 6
            visible: delegate.layoutMode

            DmsFileManagerThumbnail {
                width: delegate.thumbnailSize; height: width
                anchors.verticalCenter: parent.verticalCenter
                filePath: delegate.filePath; fileName: delegate.fileName
                isDir: delegate.fileIsDir; appIcon: delegate.appIcon
                iconName: delegate.iconName; iconColor: delegate.iconColor
                itemType: delegate.itemType
                sizeScale: delegate.dmsFileManager ? delegate.dmsFileManager.sizeScale : 1
                hover: ma.containsMouse
            }

            Text {
                visible: !delegate.editing
                font.pixelSize: delegate.labelPixelSize
                width: parent.width - delegate.thumbnailSize - 6 - (delegate._pinned ? delegate.pinIconSize + 4 : 0) - (delegate._isFavorite ? 14 : 0) - (delegate.isEmpty ? 10 : 0)
                text: delegate.displayBaseName
                color: _surfaceText
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            // Indicators after name: empty dot + favorite star
            Text {
                text: delegate.isEmpty ? "●" : ""
                color: delegate.dmsFileManager ? delegate.dmsFileManager.emptyColor : "red"
                font.pixelSize: delegate.labelPixelSize - 2
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: delegate._isFavorite ? (favListStarMA2.containsMouse ? "✕" : "★") : ""
                color: favListStarMA2.containsMouse ? "red" : "#FFD700"
                font.pixelSize: delegate.labelPixelSize
                anchors.verticalCenter: parent.verticalCenter

                MouseArea {
                    id: favListStarMA2
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (delegate.dmsFileManager) delegate.dmsFileManager.toggleFavorite(delegate.filePath);
                    }
                }
            }
        }

        // Inline rename editor — bottom-aligned, centered text
        Loader {
            active: delegate.editing; visible: active
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 2
            height: active && item ? item.implicitHeight : 0
            sourceComponent: Component {
                DmsFileManagerInlineRename {
                    fontPixelSize: delegate.labelPixelSize
                    targetName: delegate.fileName
                    targetIsDir: delegate.fileIsDir
                    onAccepted: newBaseName => {
                        delegate.dmsFileManager.applyRename(delegate.filePath, delegate.fileName, delegate.fileIsDir, newBaseName);
                        delegate.dmsFileManager.endInlineRename();
                    }
                    onCanceled: delegate.dmsFileManager.endInlineRename()
                }
            }
        }

        // Pin indicator
        Rectangle {
            width: delegate.pinIconSize; height: width; radius: 3
            color: _primary
            anchors.top: parent.top; anchors.topMargin: 2
            anchors.right: parent.right; anchors.rightMargin: 2
            visible: delegate._pinned
        }

        // Cut visual indicator
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.35)
            radius: parent.radius
            visible: delegate._isCut
            z: 1
            Text {
                anchors.centerIn: parent
                text: "✕"
                color: "white"
                font.pixelSize: 32
                font.bold: true
            }
        }

        // Copy visual indicator
        Rectangle {
            x: 4
            y: 4
            width: 18; height: 18
            radius: 4
            color: Qt.rgba(0, 0.35, 0.7, 0.85)
            visible: delegate._isCopy
            z: 2
            Text {
                anchors.centerIn: parent
                text: "C"
                color: "white"
                font.pixelSize: 12
                font.bold: true
            }
        }

        // ── Interaction ──────────────────────────────────────────────────────
        MouseArea {
            id: ma
            anchors.fill: parent
            enabled: !delegate.editing
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton

            onClicked: mouse => {
                var fv = delegate.dmsFileManager; if (!fv) return;
                // Dismiss rename when clicking any other file
                if (fv.renamingFilePath !== "" && fv.renamingFilePath !== delegate.filePath)
                    fv.endInlineRename();
                if (mouse.button === Qt.LeftButton) {
                    if (delegate.filePath.startsWith("stack://")) {
                        fv.toggleStackExpanded(delegate.filePath.substring(8)); return;
                    }
                    if (mouse.modifiers & Qt.ControlModifier)
                        fv.toggleSelection(delegate.filePath);
                    else if (mouse.modifiers & Qt.ShiftModifier)
                        fv.selectRangeTo(delegate.index);
                    else
                        fv.handleItemLabelClick(ma, ma, mouse.x, mouse.y, delegate.filePath);
                } else if (mouse.button === Qt.MiddleButton) {
                    fv.stopRenameArmTimer();
                    if (fv.folderType === "trash") {
                        var gp = mapToItem(fv, mouse.x, mouse.y);
                        fv.showTrashActionPopup(delegate.filePath, delegate.fileName, gp.x, gp.y);
                    } else {
                        var gp = mapToItem(fv, mouse.x, mouse.y);
                        fv.showQuickMenu(delegate.filePath, delegate.fileName, delegate.fileIsDir, gp.x, gp.y);
                    }
                }
            }

            onDoubleClicked: mouse => {
                var fv = delegate.dmsFileManager; if (!fv) return;
                if (mouse.button === Qt.LeftButton) {
                    fv.stopRenameArmTimer();
                    if (delegate.filePath.startsWith("stack://")) {
                        fv.toggleStackExpanded(delegate.filePath.substring(8)); return;
                    }
                    delegate.isLaunching = true;
                    launchPulse.restart(); launchTimer.restart();
                    if (delegate.fileIsDir)
                        fv.navigateToFolder(delegate.filePath);
                    else if (delegate.isDesktop)
                        fv.launchDesktopFile(delegate.filePath);
                    else
                        fv.execFile(delegate.filePath);
                    fv.clearSelection();
                }
            }
        }
    }

}
