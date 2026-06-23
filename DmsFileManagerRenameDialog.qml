import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Common
import qs.Widgets
import "./dms-common"

Popup {
    id: renameDialog
    width: 260
    height: 156
    padding: 0
    modal: false
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) { close(); event.accepted = true; }
    }

    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0

    property string filePath: ""
    property string oldName: ""
    property string fileExt: ""
    property bool isDir: false
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
            renameDialog._pluginFlatTranslations = ({});
            renameDialog._pluginI18nReady = false;
            __i18nTick++;
            return;
        }
        pluginI18nLoader.path = Qt.resolvedUrl("translations/i18n/" + locale + ".json");
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
                renameDialog._pluginFlatTranslations = JSON.parse(text());
                renameDialog._pluginI18nReady = true;
                renameDialog.__i18nTick++;
            } catch (e) {
                console.warn("RenameDialog I18n: error parsing:", e);
            }
        }
        onLoadFailed: error => {
            console.warn("RenameDialog I18n: failed to load:", error);
        }
    }

    Component.onCompleted: _loadPluginTranslations(pluginLanguage)

    onOpened: {
        Qt.callLater(() => {
            if (renameDialog.inputField) {
                renameDialog.inputField.forceActiveFocus();
                renameDialog.inputField.selectAll();
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

            StyledText {
                text: i18n("Rename")
                font.bold: true
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankTextField {
                    id: renameField
                    width: parent.width - (extLabel.visible ? extLabel.implicitWidth + Theme.spacingS : 0)
                    placeholderText: i18n("Enter new name...")
                    focus: true
                    onAccepted: renameDialog.performRename()

                    Component.onCompleted: {
                        renameDialog.inputField = renameField;
                    }
                }

                StyledText {
                    id: extLabel
                    text: renameDialog.fileExt
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    opacity: 0.6
                    anchors.verticalCenter: parent.verticalCenter
                    visible: text !== ""
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS
                layoutDirection: Qt.RightToLeft

                DankButton {
                    text: i18n("Rename")
                    backgroundColor: Theme.primary
                    textColor: Theme.primaryText
                    onClicked: renameDialog.performRename()
                }

                DankButton {
                    text: i18n("Cancel")
                    backgroundColor: Theme.surfaceContainerHigh
                    textColor: Theme.surfaceText
                    onClicked: renameDialog.close()
                }
            }
        }
    }

    function showFor(path, name, isDirectory) {
        let cleanPath = String(path);
        let isVirtualStack = cleanPath.startsWith("stack://");
        if (!isVirtualStack) {
            if (cleanPath.startsWith("file://")) {
                cleanPath = cleanPath.substring(7);
            }
            if (cleanPath.startsWith("localhost/")) {
                cleanPath = cleanPath.substring(9);
            }
        }
        renameDialog.filePath = cleanPath;
        renameDialog.oldName = name;
        renameDialog.isDir = !!isDirectory;

        let baseName = name;
        let extension = "";
        if (!renameDialog.isDir) {
            const lastDot = name.lastIndexOf(".");
            if (lastDot > 0) {
                baseName = name.substring(0, lastDot);
                extension = name.substring(lastDot);
            }
        }
        renameDialog.fileExt = extension;

        if (renameDialog.inputField) {
            renameDialog.inputField.text = baseName;
        }
        renameDialog.open();
    }

    function performRename() {
        if (renameDialog.inputField && parent && typeof parent.applyRename === "function") {
            parent.applyRename(renameDialog.filePath, renameDialog.oldName, renameDialog.isDir, renameDialog.inputField.text);
        }
        renameDialog.close();
    }
}
