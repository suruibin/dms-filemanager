import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Services
import "../dms-common"

Popup {
    id: createAppDialog
    width: 380
    height: 520
    padding: 0
    modal: true
    dim: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0

    property string targetFolderUrl: ""
    property var allApps: []

    // ── Plugin I18n ──────────────────────────────────────────────────────────
    property var _pluginFlatTranslations: ({})
    property bool _pluginI18nReady: false
    property int __i18nTick: 1
    // Set from FolderView.qml to inherit current language
    property string pluginLanguage: "system"
    onPluginLanguageChanged: _loadPluginTranslations(pluginLanguage)

    function _loadPluginTranslations(locale) {
        if (locale === "System Default" || locale === "") locale = "system";
        if (locale === "system") locale = "en";
        if (!locale) {
            createAppDialog._pluginFlatTranslations = ({});
            createAppDialog._pluginI18nReady = false;
            __i18nTick++;
            return;
        }
        pluginI18nLoader.path = Qt.resolvedUrl("../translations/i18n/" + locale + ".json");
    }

    function i18n(term, context) {
        var _ = __i18nTick;
        if (_pluginI18nReady && _pluginFlatTranslations[term]) {
            return _pluginFlatTranslations[term];
        }
        return I18n.tr(term, context);
    }

    FileView {
        id: pluginI18nLoader
        onLoaded: {
            try {
                createAppDialog._pluginFlatTranslations = JSON.parse(text());
                createAppDialog._pluginI18nReady = true;
            } catch (e) {
                console.warn("CreateAppDialog I18n: error parsing:", e);
            }
        }
        onLoadFailed: error => {
            console.warn("CreateAppDialog I18n: failed to load:", error);
        }
    }

    Component.onCompleted: _loadPluginTranslations(pluginLanguage)

    function fetchApps() {
        // Fetch all apps directly from Quickshell's DesktopEntries singleton
        const allEntries = DesktopEntries.applications.values;
        let apps = [];
        let seen = {};
        for (let i = 0; i < allEntries.length; i++) {
            const app = allEntries[i];
            if (app && !app.noDisplay) {
                const nm = app.name || "";
                if (seen[nm]) continue; // skip duplicates by name
                seen[nm] = true;
                apps.push({
                    name: nm,
                    exec: app.execString || (app.command ? app.command.join(" ") : ""),
                    icon: app.icon || ""
                });
            }
        }
        apps.sort((a, b) => (a.name || "").localeCompare(b.name || ""));
        createAppDialog.allApps = apps;
        updateAppModel();
    }

    onOpened: {
        Qt.callLater(() => {
            searchField.text = "";
            nameField.text = "";
            execField.text = "";
            iconField.text = "";
            if (createAppDialog.allApps.length === 0) {
                fetchApps();
            } else {
                updateAppModel();
            }
            modeStack.currentIndex = 0;
            searchField.forceActiveFocus();
        });
    }

    function updateAppModel() {
        appModel.clear();
        const query = searchField.text.trim().toLowerCase();
        for (let i = 0; i < allApps.length; i++) {
            const app = allApps[i];
            if (query === "" || (app.name || "").toLowerCase().indexOf(query) !== -1 || (app.exec || "").toLowerCase().indexOf(query) !== -1) {
                appModel.append({
                    appName: app.name,
                    appExec: app.exec,
                    appIcon: app.icon
                });
            }
        }
    }

    background: Rectangle {
        color: "transparent"
    }

    contentItem: Rectangle {
        color: Theme.surfaceContainer
        radius: Theme.cornerRadius
        border.color: Theme.withAlpha(Theme.outline, 0.15)
        border.width: 1

        Column {
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            // Dialog Header
            Item {
                width: parent.width
                height: 24
                
                StyledText {
                    text: i18n("New Application")
                    font.bold: true
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                }

                // Close Dialog Button
                MouseArea {
                    width: 24
                    height: 24
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: createAppDialog.close()
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter

                    DankIcon {
                        anchors.centerIn: parent
                        name: "close"
                        size: 16
                        color: Theme.surfaceText
                        opacity: parent.containsMouse ? 1.0 : 0.6
                    }
                }
            }

            // Tabs Segmented Control
            Rectangle {
                width: parent.width
                height: 32
                radius: 16
                color: Theme.withAlpha(Theme.surfaceText, 0.05)
                border.color: Theme.withAlpha(Theme.outline, 0.1)
                border.width: 1

                Row {
                    anchors.fill: parent
                    anchors.margins: 2

                    // Tab 1: System Apps
                    MouseArea {
                        id: tabSysBtn
                        width: parent.width / 2
                        height: parent.height
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            modeStack.currentIndex = 0;
                            searchField.forceActiveFocus();
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: 14
                            color: modeStack.currentIndex === 0 ? Theme.primary : "transparent"

                            StyledText {
                                anchors.centerIn: parent
                                text: i18n("System Apps")
                                font.bold: modeStack.currentIndex === 0
                                font.pixelSize: Theme.fontSizeSmall
                                color: modeStack.currentIndex === 0 ? Theme.onPrimary : Theme.surfaceText
                                opacity: modeStack.currentIndex === 0 ? 1.0 : (tabSysBtn.containsMouse ? 0.9 : 0.6)
                            }
                        }
                    }

                    // Tab 2: Custom App
                    MouseArea {
                        id: tabCustBtn
                        width: parent.width / 2
                        height: parent.height
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            modeStack.currentIndex = 1;
                            nameField.forceActiveFocus();
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: 14
                            color: modeStack.currentIndex === 1 ? Theme.primary : "transparent"

                            StyledText {
                                anchors.centerIn: parent
                                text: i18n("Custom App")
                                font.bold: modeStack.currentIndex === 1
                                font.pixelSize: Theme.fontSizeSmall
                                color: modeStack.currentIndex === 1 ? Theme.onPrimary : Theme.surfaceText
                                opacity: modeStack.currentIndex === 1 ? 1.0 : (tabCustBtn.containsMouse ? 0.9 : 0.6)
                            }
                        }
                    }
                }
            }

            StackLayout {
                id: modeStack
                width: parent.width
                height: parent.height - 24 - 32 - (Theme.spacingS * 3)

                // Page 0: System Apps
                Column {
                    spacing: Theme.spacingS
                    
                    DankTextField {
                        id: searchField
                        width: parent.width
                        placeholderText: i18n("Search apps...")
                        onTextChanged: updateAppModel()
                    }

                    Rectangle {
                        width: parent.width
                        height: parent.height - searchField.height - Theme.spacingS
                        color: "transparent"
                        radius: Theme.cornerRadius - 2
                        border.color: Theme.withAlpha(Theme.outline, 0.1)
                        border.width: 1
                        clip: true

                        ListModel { id: appModel }

                        ListView {
                            id: appListView
                            anchors.fill: parent
                            model: appModel
                            boundsBehavior: Flickable.StopAtBounds
                            delegate: Rectangle {
                                width: parent.width
                                height: 56
                                color: appMouse.containsMouse ? Theme.withAlpha(Theme.primary, 0.1) : "transparent"
                                
                                Row {
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingS
                                    spacing: Theme.spacingS
                                    
                                    Image {
                                        id: appImg
                                        source: model.appIcon ? Quickshell.iconPath(model.appIcon) : ""
                                        width: 36
                                        height: 36
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: model.appIcon !== ""
                                        fillMode: Image.PreserveAspectFit
                                        asynchronous: true
                                    }
                                    
                                    DankIcon {
                                        name: "widgets"
                                        size: 36
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: !appImg.visible || appImg.status === Image.Error
                                        color: Theme.primary
                                    }

                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 50
                                        spacing: 2
                                        StyledText {
                                            text: model.appName
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.bold: true
                                            color: Theme.surfaceText
                                        }
                                        StyledText {
                                            text: model.appExec
                                            font.pixelSize: Theme.fontSizeTiny
                                            color: Theme.surfaceVariantText
                                            elide: Text.ElideRight
                                            maximumLineCount: 2
                                            wrapMode: Text.WrapAnywhere
                                            width: parent.width
                                        }
                                    }
                                }

                                MouseArea {
                                    id: appMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        createAppDialog.createSystemAppShortcut(model.appName, model.appExec, model.appIcon);
                                    }
                                }
                            }
                        }

                        // Custom scrollbar — matches conky/launcher/AppLauncherContent.qml pattern (lines 930-934)
                        Item { width: 16; anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom; z: 10; visible: appListView.contentHeight > appListView.height
                            Rectangle { id: appSB; width: 6; radius: 3; anchors.right: parent.right; anchors.rightMargin: 2; height: Math.max(20, parent.height * appListView.visibleArea.heightRatio); color: Theme.withAlpha(Theme.primary, 0.2); y: appListView.contentY / appListView.contentHeight * parent.height }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; preventStealing: true; property real _py: 0
                                onPressed: mouse => { _py = mouse.y - appSB.y }
                                onPositionChanged: mouse => { var lv = appListView; if (lv.contentHeight > lv.height) { var ny = Math.max(0, Math.min(parent.height - appSB.height, mouse.y - _py)); appSB.y = ny; lv.contentY = ny / parent.height * lv.contentHeight } } }
                        }

                        // Fast scroll overlay — matches conky/launcher/AppLauncherContent.qml pattern
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: false
                            propagateComposedEvents: true
                            onWheel: wheel => {
                                wheel.accepted = true
                                if (appListView.contentHeight > appListView.height) {
                                    appListView.contentY = Math.max(0, Math.min(
                                        appListView.contentY - wheel.angleDelta.y,
                                        appListView.contentHeight - appListView.height))
                                }
                            }
                            onPressed: mouse => mouse.accepted = false
                            onReleased: mouse => mouse.accepted = false
                            onClicked: mouse => mouse.accepted = false
                        }
                    }
                }

                // Page 1: Custom App
                Column {
                    spacing: Theme.spacingS

                    DankTextField {
                        id: nameField
                        width: parent.width
                        placeholderText: i18n("App name...")
                        onAccepted: execField.forceActiveFocus()
                    }

                    DankTextField {
                        id: execField
                        width: parent.width
                        placeholderText: i18n("Command...")
                        onAccepted: iconField.forceActiveFocus()
                    }

                    DankTextField {
                        id: iconField
                        width: parent.width
                        placeholderText: i18n("Icon (optional)...")
                        onAccepted: createAppDialog.performCreate()
                    }

                    Item { width: 1; height: Theme.spacingM }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS
                        layoutDirection: Qt.RightToLeft

                        DankButton {
                            text: i18n("Create")
                            backgroundColor: Theme.primary
                            textColor: Theme.primaryText
                            onClicked: createAppDialog.performCreate()
                        }

                        DankButton {
                            text: i18n("Cancel")
                            backgroundColor: Theme.surfaceContainerHigh
                            textColor: Theme.surfaceText
                            onClicked: createAppDialog.close()
                        }
                    }
                }
            }
        }
    }

    function show() {
        createAppDialog.open();
    }

    function getTargetFolder() {
        let pathStr = String(createAppDialog.targetFolderUrl);
        if (pathStr.startsWith("file://")) {
            pathStr = pathStr.substring(7);
        }
        if (pathStr.startsWith("localhost/")) {
            pathStr = pathStr.substring(9);
        }
        return pathStr;
    }

    function createSystemAppShortcut(appName, appExec, appIcon) {
        let pathStr = getTargetFolder();
        let safeName = appName.replace(/[^a-zA-Z0-9_-]/g, "_");
        const targetPath = pathStr + "/" + safeName + ".desktop";
        const content = "[Desktop Entry]\nType=Application\nName=" + appName + "\nExec=" + appExec + "\nIcon=" + appIcon + "\nTerminal=false\n";
        try {
            const escapedContent = content.replace(/'/g, "'\\''");
            const escapedPath = targetPath.replace(/'/g, "'\\''");
            const shellCmd = "printf '%s' '" + escapedContent + "' > '" + escapedPath + "'";
            Quickshell.execDetached(["sh", "-c", shellCmd]);
        } catch (e) {
            ToastService.showToast("Create error: " + e.message, ToastService.levelError);
        }
        createAppDialog.close();
    }

    function performCreate() {
        const name = nameField.text.trim();
        const execVal = execField.text.trim();
        let iconVal = iconField.text.trim();

        if (name.length === 0 || execVal.length === 0) {
            ToastService.showToast(i18n("App name and Command are required"), ToastService.levelWarning);
            return;
        }

        if (iconVal.length === 0) {
            iconVal = "application-x-executable";
        }

        let pathStr = getTargetFolder();
        const fileName = name.endsWith(".desktop") ? name : name + ".desktop";
        const targetPath = pathStr + "/" + fileName;

        const content = "[Desktop Entry]\nType=Application\nName=" + name + "\nExec=" + execVal + "\nIcon=" + iconVal + "\nTerminal=false\n";

        try {
            // Write to file cleanly using POSIX printf, removing dependency on python3 for writing files
            const escapedContent = content.replace(/'/g, "'\\''");
            const escapedPath = targetPath.replace(/'/g, "'\\''");
            const shellCmd = "printf '%s' '" + escapedContent + "' > '" + escapedPath + "'";
            Quickshell.execDetached(["sh", "-c", shellCmd]);
        } catch (e) {
            ToastService.showToast("Create error: " + e.message, ToastService.levelError);
        }
        createAppDialog.close();
    }
}
