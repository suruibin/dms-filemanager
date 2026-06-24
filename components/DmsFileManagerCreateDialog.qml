import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Services
import "../dms-common"

Popup {
    id: createDialog
    width: 260
    height: 140
    padding: 0
    modal: false
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) { close(); event.accepted = true; }
    }

    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0

    property string targetFolderUrl: ""
    property bool isFolder: true
    property var inputField: null

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
            createDialog._pluginFlatTranslations = ({});
            createDialog._pluginI18nReady = false;
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
                createDialog._pluginFlatTranslations = JSON.parse(text());
                createDialog._pluginI18nReady = true;
                createDialog.__i18nTick++;
            } catch (e) {
                console.warn("CreateDialog I18n: error parsing:", e);
            }
        }
        onLoadFailed: error => {
            console.warn("CreateDialog I18n: failed to load:", error);
        }
    }

    Component.onCompleted: _loadPluginTranslations(pluginLanguage)

    onOpened: {
        Qt.callLater(() => {
            if (createDialog.inputField) {
                createDialog.inputField.forceActiveFocus();
                createDialog.inputField.selectAll();
            }
        });
    }

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

            // File/Folder toggle
            Row {
                width: parent.width
                spacing: 0

                Rectangle {
                    width: parent.width / 2
                    height: 28
                    radius: Theme.cornerRadius
                    color: !createDialog.isFolder ? Theme.primary : "transparent"
                    border.color: Theme.withAlpha(Theme.outline, 0.2)
                    border.width: 1

                    StyledText {
                        anchors.centerIn: parent
                        text: i18n("New Document")
                        font.bold: !createDialog.isFolder
                        font.pixelSize: Theme.fontSizeSmall
                        color: !createDialog.isFolder ? Theme.primaryText : Theme.surfaceText
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            createDialog.isFolder = false;
                            if (createDialog.inputField) {
                                createDialog.inputField.text = "New Document.txt";
                                createDialog.inputField.placeholderText = i18n("File name...");
                                createDialog.inputField.forceActiveFocus();
                                createDialog.inputField.selectAll();
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width / 2
                    height: 28
                    radius: Theme.cornerRadius
                    color: createDialog.isFolder ? Theme.primary : "transparent"
                    border.color: Theme.withAlpha(Theme.outline, 0.2)
                    border.width: 1

                    StyledText {
                        anchors.centerIn: parent
                        text: i18n("New Folder")
                        font.bold: createDialog.isFolder
                        font.pixelSize: Theme.fontSizeSmall
                        color: createDialog.isFolder ? Theme.primaryText : Theme.surfaceText
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            createDialog.isFolder = true;
                            if (createDialog.inputField) {
                                createDialog.inputField.text = "New Folder";
                                createDialog.inputField.placeholderText = i18n("Folder name...");
                                createDialog.inputField.forceActiveFocus();
                                createDialog.inputField.selectAll();
                            }
                        }
                    }
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankTextField {
                    id: createField
                    width: parent.width
                    placeholderText: createDialog.isFolder ? i18n("Folder name...") : i18n("File name...")
                    focus: true
                    onAccepted: createDialog.performCreate()

                    Component.onCompleted: {
                        createDialog.inputField = createField;
                    }
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS
                layoutDirection: Qt.RightToLeft

                DankButton {
                    text: i18n("Create")
                    buttonHeight: 28
                    backgroundColor: Theme.primary
                    textColor: Theme.primaryText
                    onClicked: createDialog.performCreate()
                }

                DankButton {
                    text: i18n("Cancel")
                    buttonHeight: 28
                    backgroundColor: Theme.surfaceContainerHigh
                    textColor: Theme.surfaceText
                    onClicked: createDialog.close()
                }
            }
        }
    }

    function showFor(folderOnly) {
        createDialog.isFolder = !!folderOnly;
        if (createDialog.inputField) {
            createDialog.inputField.text = createDialog.isFolder ? "New Folder" : "New Document.txt";
        }
        createDialog.open();
    }

    function performCreate() {
        if (!createDialog.inputField) {
            createDialog.close();
            return;
        }
        const name = createDialog.inputField.text.trim();
        if (name.length === 0) {
            createDialog.close();
            return;
        }

        let pathStr = String(createDialog.targetFolderUrl);
        if (pathStr.startsWith("file://")) {
            pathStr = pathStr.substring(7);
        }
        if (pathStr.startsWith("localhost/")) {
            pathStr = pathStr.substring(9);
        }
        
        const targetPath = pathStr + "/" + name;
        
        try {
            if (createDialog.isFolder) {
                Quickshell.execDetached(["mkdir", "-p", targetPath]);
            } else {
                Quickshell.execDetached(["touch", targetPath]);
            }
        } catch (e) {
            ToastService.showToast("Create error: " + e.message, ToastService.levelError);
        }
        createDialog.close();
    }
}
