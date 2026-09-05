import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Services
import "../dms-common"

Popup {
    id: infoDialog
    width: 340
    height: contentColumn.implicitHeight + Theme.spacingM * 2
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
    property string fileName: ""
    property bool isDir: false
    // Custom background color injected from the plugin root (empty = theme)
    property string popupColor: ""
    
    // Info fields
    property string fileType: ""
    property string filePermissions: ""
    property string fileModified: ""
    property string fileSize: ""
    property string fileOwner: ""

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
            infoDialog._pluginFlatTranslations = ({});
            infoDialog._pluginI18nReady = false;
            __i18nTick++;
            return;
        }
        // Reset before loading new file so stale translations aren't shown
        infoDialog._pluginFlatTranslations = ({});
        infoDialog._pluginI18nReady = false;
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
                infoDialog._pluginFlatTranslations = JSON.parse(text());
                infoDialog._pluginI18nReady = true;
                infoDialog.__i18nTick++;
            } catch (e) {
                console.warn("InfoDialog I18n: error parsing:", e);
            }
        }
        onLoadFailed: error => {
            console.warn("InfoDialog I18n: failed to load:", error);
        }
    }

    Component.onCompleted: _loadPluginTranslations(pluginLanguage)

    background: Rectangle {
        color: "transparent"
    }

    contentItem: Rectangle {
        color: popupColor !== "" ? popupColor : Theme.withAlpha(Theme.surfaceContainer, 0.95)
        radius: Theme.cornerRadius
        border.color: Theme.withAlpha(Theme.outline, 0.15)
        border.width: 1

        Column {
            id: contentColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingM

            // Header with Icon and Name
            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankIcon {
                    name: infoDialog.isDir ? "folder" : "description"
                    size: 28
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: infoDialog.fileName
                    font.bold: true
                    font.pixelSize: Theme.fontSizeLarge
                    color: Theme.surfaceText
                    width: parent.width - 40
                    elide: Text.ElideMiddle
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.withAlpha(Theme.outline, 0.1)
            }

            // Info List
            Column {
                width: parent.width
                spacing: Theme.spacingS

                readonly property int labelWidth: 90

                // Rows helper component
                component InfoRow: Item {
                    width: parent.width
                    height: Math.max(label.implicitHeight, value.implicitHeight)
                    property alias labelText: label.text
                    property alias valueText: value.text

                    StyledText {
                        id: label
                        text: ""
                        width: parent.parent.labelWidth
                        font.pixelSize: Theme.fontSizeSmall
                        font.bold: true
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        id: value
                        anchors.left: label.right
                        anchors.right: parent.right
                        text: ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        wrapMode: Text.Wrap
                    }
                }

                InfoRow { labelText: i18n("Type:"); valueText: infoDialog.fileType }
                InfoRow { labelText: i18n("Size:"); valueText: infoDialog.fileSize }
                InfoRow { labelText: i18n("Modified:"); valueText: infoDialog.fileModified }
                InfoRow { labelText: i18n("Owner:"); valueText: infoDialog.fileOwner }
                InfoRow { labelText: i18n("Permissions:"); valueText: infoDialog.filePermissions }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.withAlpha(Theme.outline, 0.1)
            }

            // Path Section
            Column {
                width: parent.width
                spacing: 4
                
                StyledText {
                    text: i18n("Location:")
                    font.pixelSize: Theme.fontSizeSmall
                    font.bold: true
                    color: Theme.surfaceVariantText
                }

                Rectangle {
                    width: parent.width
                    height: pathText.implicitHeight + 16
                    color: "transparent"

                    StyledText {
                        id: pathText
                        anchors.fill: parent
                        anchors.margins: 8
                        anchors.rightMargin: 30
                        text: infoDialog.filePath
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WrapAnywhere
                        font.family: "monospace"
                    }

                    // Green check after copying (stays visible until dialog reopens)
                    DankIcon {
                        id: pathCheck
                        name: "check_circle"
                        size: 16
                        color: Theme.success
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 8
                        visible: false
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Quickshell.execDetached(["dms", "cl", "copy", infoDialog.filePath]);
                            pathCheck.visible = true;
                        }
                    }
                }
            }
        }
    }

    function showFor(path, name, isDirectory) {
        let cleanPath = String(path);
        if (cleanPath.startsWith("file://")) {
            cleanPath = cleanPath.substring(7);
        }
        if (cleanPath.startsWith("localhost/")) {
            cleanPath = cleanPath.substring(9);
        }
        
        infoDialog.filePath = cleanPath;
        infoDialog.fileName = name;
        infoDialog.isDir = !!isDirectory;
        
        // Reset fields
        infoDialog.fileType = "..."
        infoDialog.filePermissions = "..."
        infoDialog.fileModified = "..."
        infoDialog.fileSize = "..."
        infoDialog.fileOwner = "..."
        pathCheck.visible = false
        
        infoDialog.open();
        fetchInfo();
    }

    // Map stat's C-locale %F output to translated type labels
    function mapFileType(raw) {
        const t = raw.toLowerCase();
        if (t.indexOf("directory") !== -1) return i18n("Folder");
        if (t.indexOf("symbolic link") !== -1) return i18n("Symbolic Link");
        if (t.indexOf("regular empty file") !== -1) return i18n("Empty File");
        if (t.indexOf("regular file") !== -1) return i18n("File");
        if (t.indexOf("block") !== -1) return i18n("Block Device");
        if (t.indexOf("character") !== -1) return i18n("Character Device");
        if (t.indexOf("fifo") !== -1) return i18n("FIFO");
        if (t.indexOf("socket") !== -1) return i18n("Socket");
        return raw;
    }

    function fetchInfo() {
        const path = infoDialog.filePath;
        // %F|%A|%y|%s|%U|%G — LC_ALL=C keeps %F unlocalized; labels are translated via i18n
        const statCmd = ["sh", "-c", "LC_ALL=C stat -c '%F|%A|%y|%s|%U|%G' \"$1\"", "sh", path];

        Proc.runCommand("get-file-info-structured", statCmd, (output, exitCode) => {
            if (exitCode === 0) {
                const parts = output.trim().split('|');
                if (parts.length >= 6) {
                    infoDialog.fileType = mapFileType(parts[0]);
                    infoDialog.filePermissions = parts[1];
                    infoDialog.fileModified = parts[2].split('.')[0]; // Remove nanoseconds
                    infoDialog.fileOwner = parts[4] + ":" + parts[5];
                    
                    const rawSize = parts[3];
                    
                    if (infoDialog.isDir) {
                        Proc.runCommand("get-dir-size", ["du", "-sh", path], (duOutput, duExit) => {
                            if (duExit === 0) {
                                infoDialog.fileSize = duOutput.trim().split(/\s+/)[0];
                            } else {
                                infoDialog.fileSize = rawSize + " bytes";
                            }
                        });
                    } else {
                        Proc.runCommand("get-file-size", ["ls", "-lh", path], (lsOutput, lsExit) => {
                            if (lsExit === 0) {
                                const lsParts = lsOutput.trim().split(/\s+/);
                                if (lsParts.length >= 5) {
                                    infoDialog.fileSize = lsParts[4];
                                } else {
                                    infoDialog.fileSize = rawSize + " bytes";
                                }
                            } else {
                                infoDialog.fileSize = rawSize + " bytes";
                            }
                        });
                    }
                }
            } else {
                infoDialog.fileType = "Error fetching info";
            }
        });
    }
}
