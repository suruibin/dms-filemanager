import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Common
import qs.Widgets
import "./dms-common"

Popup {
    id: renameDialog
    width: 260
    height: 100
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

    TextMetrics {
        id: _dialogMetrics
        font.pixelSize: Theme.fontSizeMedium
    }

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

            DankTextField {
                id: renameField
                width: parent.width
                placeholderText: i18n("Enter new name...")
                focus: true
                onAccepted: renameDialog.performRename()

                Component.onCompleted: {
                    renameDialog.inputField = renameField;
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS
                layoutDirection: Qt.RightToLeft

                DankButton {
                    text: i18n("Rename")
                    buttonHeight: 28
                    backgroundColor: Theme.primary
                    textColor: Theme.primaryText
                    onClicked: renameDialog.performRename()
                }

                DankButton {
                    text: i18n("Cancel")
                    buttonHeight: 28
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

        renameDialog.fileExt = "";

        // Auto-size width based on full filename text length
        _dialogMetrics.text = name;
        let nameW = _dialogMetrics.advanceWidth;
        let totalW = nameW + 88; // margins + padding + spacings
        renameDialog.width = Math.max(200, Math.min(420, totalW));

        if (renameDialog.inputField) {
            renameDialog.inputField.text = name;
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
