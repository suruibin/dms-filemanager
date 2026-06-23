import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Services
import "./dms-common"

Popup {
    id: createStackDialog
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

    property var selectedPaths: []
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
            createStackDialog._pluginFlatTranslations = ({});
            createStackDialog._pluginI18nReady = false;
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
                createStackDialog._pluginFlatTranslations = JSON.parse(text());
                createStackDialog._pluginI18nReady = true;
                createStackDialog.__i18nTick++;
            } catch (e) {
                console.warn("CreateStackDialog I18n: error parsing:", e);
            }
        }
        onLoadFailed: error => {
            console.warn("CreateStackDialog I18n: failed to load:", error);
        }
    }

    Component.onCompleted: _loadPluginTranslations(pluginLanguage)

    onOpened: {
        Qt.callLater(() => {
            if (createStackDialog.inputField) {
                createStackDialog.inputField.forceActiveFocus();
                createStackDialog.inputField.selectAll();
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
                text: i18n("Create Stack")
                font.bold: true
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankTextField {
                    id: stackNameField
                    width: parent.width
                    placeholderText: i18n("Stack name...")
                    focus: true
                    onAccepted: createStackDialog.performCreate()

                    Component.onCompleted: {
                        createStackDialog.inputField = stackNameField;
                    }
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS
                layoutDirection: Qt.RightToLeft

                DankButton {
                    text: i18n("Create")
                    backgroundColor: Theme.primary
                    textColor: Theme.primaryText
                    onClicked: createStackDialog.performCreate()
                }

                DankButton {
                    text: i18n("Cancel")
                    backgroundColor: Theme.surfaceContainerHigh
                    textColor: Theme.surfaceText
                    onClicked: createStackDialog.close()
                }
            }
        }
    }

    function showFor(paths) {
        createStackDialog.selectedPaths = paths || [];
        if (createStackDialog.inputField) {
            createStackDialog.inputField.text = "New Stack";
        }
        createStackDialog.open();
    }

    function performCreate() {
        if (!createStackDialog.inputField) {
            createStackDialog.close();
            return;
        }
        const name = createStackDialog.inputField.text.trim();
        if (name.length === 0) {
            createStackDialog.close();
            return;
        }

        root.createStack(name, createStackDialog.selectedPaths);
        createStackDialog.close();
    }
}
