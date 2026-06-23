import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "./dms-common"

PluginSettings {
    id: root
    pluginId: "dmsfilemanager"

    // ── Reactive i18n from instance config ──
    // Reads translation map published by FolderView.qml when language changes.
    // instanceData is set via Qt.binding from PluginDesktopWidgetSettings,
    // so changes propagate reactively through the SettingsData chain.
    property var _i18nMap: instanceData && instanceData.config ? instanceData.config.i18nMap || {} : ({})
    property int _i18nToken: instanceData && instanceData.config ? Number(instanceData.config.i18nToken || 0) : 0

    // ── Plugin-aware i18n ──
    // Checks plugin translations first (published by FolderView.qml via i18nMap),
    // falls back to system i18n().  Reads _i18nToken so any QML binding that
    // calls i18n("...") re-evaluates when translations reload.
    function i18n(term, context) {
        if (_i18nToken < 0) {}
        if (_i18nMap && _i18nMap[term])
            return _i18nMap[term];
        return I18n.tr(term, context);
    }

    SettingsCard {
        id: appearanceSection
        SectionTitle { 
            text: i18n("Appearance")
            icon: "palette" 
            showReset: backgroundOpacity.isDirty || borderOpacity.isDirty || folderDropdownOpacity.isDirty || cellSize.isDirty || viewMode.isDirty || headerPosition.isDirty || showHeader.isDirty || showHidden.isDirty || emptyColor.isDirty || folderColor.isDirty
            onResetClicked: {
                backgroundOpacity.resetToDefault();
                borderOpacity.resetToDefault();
                folderDropdownOpacity.resetToDefault();
                cellSize.resetToDefault();
                viewMode.resetToDefault();
                headerPosition.resetToDefault();
                showHeader.resetToDefault();
                showHidden.resetToDefault();
                emptyColor.resetToDefault();
                folderColor.resetToDefault();
            }
        }

        SliderSettingPlus {
            id: backgroundOpacity
            settingKey: "backgroundOpacity"
            label: i18n("Background Opacity")
            defaultValue: 80
            minimum: 0
            maximum: 100
            unit: "%"
            leftLabel: "0%"
            rightLabel: "100%"
        }

        Separator {}

        SliderSettingPlus {
            id: borderOpacity
            settingKey: "borderOpacity"
            label: i18n("Border Opacity")
            defaultValue: 0
            minimum: 0
            maximum: 100
            unit: "%"
            leftLabel: "0%"
            rightLabel: "100%"
        }

        Separator {}

        SliderSettingPlus {
            id: folderDropdownOpacity
            settingKey: "folderDropdownOpacity"
            label: i18n("SideBar Opacity")
            defaultValue: 95
            minimum: 0
            maximum: 100
            unit: "%"
            leftLabel: "0%"
            rightLabel: "100%"
        }

        Separator {}

        SliderSettingPlus {
            id: cellSize
            settingKey: "cellSize"
            label: i18n("Icon Size")
            description: i18n("Adjust the size of file and folder icons.")
            defaultValue: 84
            minimum: 64
            maximum: 128
            unit: "px"
            leftLabel: "64"
            rightLabel: "128"
        }

        Separator {}

        ButtonGroupSettingPlus {
            id: viewMode
            settingKey: "viewMode"
            label: i18n("View Mode")
            options: [
                { label: i18n("Grid View"), value: "grid" },
                { label: i18n("List View"), value: "list" },
                { label: i18n("Compact View"), value: "compact" }
            ]
            defaultValue: "grid"
        }

        Separator {}

        ButtonGroupSettingPlus {
            id: headerPosition
            settingKey: "headerPosition"
            label: i18n("Header Position")
            options: [
                // Raw keys — resolved through translateMap dynamically
                { label: "Top",    value: "top"    },
                { label: "Bottom", value: "bottom" }
            ]
            defaultValue: "top"
            translateMap: root._i18nMap
            translateToken: root._i18nToken
        }

        Separator {}

        ToggleSettingPlus {
            id: showHeader
            settingKey: "showHeader"
            label: i18n("Show Folder Header")
            defaultValue: true
        }

        Separator {}

        ToggleSettingPlus {
            id: showHidden
            settingKey: "showHidden"
            label: i18n("Show Hidden Files")
            defaultValue: false
        }

        Separator {}

        Item {
            id: emptyColor
            width: parent.width
            implicitHeight: 50

            readonly property string value: pluginData?.emptyColor ?? "#FF1744"
            readonly property bool isDirty: false

            function resetToDefault() {
                if (pluginService)
                    pluginService.savePluginData("dmsfilemanager", "emptyColor", "#FF1744");
            }

            StyledText {
                text: i18n("Empty File Color")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Medium
                color: Theme.surfaceText
                anchors.left: parent.left
                anchors.top: parent.top
            }

            Row {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                spacing: 6

                Repeater {
                    model: ["#FF1744", "#00E676", "#FFEA00", "#448AFF", "#D500F9", "#00BFA5", "#FF9100", "#E91E63", "#00BCD4", "#795548"]

                    delegate: Rectangle {
                        width: 14; height: 14; radius: 2
                        color: modelData
                        border.width: emptyColor.value === modelData ? 2 : 1
                        border.color: emptyColor.value === modelData ? Theme.surfaceText : Theme.withAlpha(Theme.outline, 0.3)

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (pluginService)
                                    pluginService.savePluginData("dmsfilemanager", "emptyColor", modelData);
                            }
                        }
                    }
                }

                // Color picker
                Rectangle {
                    width: 18; height: 18; radius: 4
                    color: "white"
                    border.width: 1
                    border.color: Theme.withAlpha(Theme.outline, 0.3)

                    StyledText {
                        anchors.centerIn: parent
                        text: "+"
                        font.pixelSize: 16
                        color: "red"
                        font.bold: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: emptyColorDialog.open()
                    }
                }

                ColorDialog {
                    id: emptyColorDialog
                    title: i18n("Empty File Color")
                    selectedColor: emptyColor.value
                    onAccepted: {
                        if (pluginService) pluginService.savePluginData("dmsfilemanager", "emptyColor", selectedColor.toString());
                    }
                }
            }
        }

        Separator {}

        Item {
            id: folderColor
            width: parent.width
            implicitHeight: 50

            readonly property string value: pluginData?.folderColor ?? ""
            readonly property bool isDirty: false

            function resetToDefault() {
                if (pluginService)
                    pluginService.savePluginData("dmsfilemanager", "folderColor", "");
            }

            StyledText {
                text: i18n("Folder Icon Color")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Medium
                color: Theme.surfaceText
                anchors.left: parent.left
                anchors.top: parent.top
            }

            Row {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                spacing: 6

                Repeater {
                    model: ["", "#FF1744", "#00E676", "#FFEA00", "#448AFF", "#D500F9", "#00BFA5", "#FF9100", "#E91E63", "#00BCD4"]

                    delegate: Rectangle {
                        width: 14; height: 14; radius: modelData === "" ? 7 : 2
                        color: modelData || Theme.primary
                        border.width: folderColor.value === modelData ? 2 : 1
                        border.color: folderColor.value === modelData ? Theme.surfaceText : Theme.withAlpha(Theme.outline, 0.3)

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (pluginService)
                                    pluginService.savePluginData("dmsfilemanager", "folderColor", modelData);
                            }
                        }
                    }
                }

                // Color picker
                Rectangle {
                    width: 18; height: 18; radius: 4
                    color: "white"
                    border.width: 1
                    border.color: Theme.withAlpha(Theme.outline, 0.3)

                    StyledText {
                        anchors.centerIn: parent
                        text: "+"
                        font.pixelSize: 16
                        color: "red"
                        font.bold: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: folderColorDialog.open()
                    }
                }

                ColorDialog {
                    id: folderColorDialog
                    title: i18n("Folder Icon Color")
                    selectedColor: folderColor.value || Theme.primary
                    onAccepted: {
                        if (pluginService) pluginService.savePluginData("dmsfilemanager", "folderColor", selectedColor.toString());
                    }
                }
            }
        }
    }

    SettingsCard {
        SectionTitle {
            text: i18n("Language")
            icon: "language"
            collapsible: true
            settingKey: "languageSectionExpanded"
        }

        SelectionSettingPlus {
            settingKey: "pluginLanguage"
            label: i18n("Language")
            defaultValue: "system"
            options: [
                { label: i18n("System Default"), value: "system" },
                { label: "中文", value: "zh_CN" },
                { label: "English", value: "en" },
                { label: "Deutsch", value: "de" },
                { label: "Español", value: "es" },
                { label: "Français", value: "fr" },
                { label: "日本語", value: "ja" },
                { label: "한국어", value: "ko" },
                { label: "Русский", value: "ru" },
                { label: "Tiếng Việt", value: "vi" }
            ]
        }
    }

    SettingsCard {
        SectionTitle { 
            id: usageTitle
            text: i18n("Usage Guide")
            icon: "menu_book" 
            collapsible: true
            settingKey: "usageGuideExpanded"
        }

        UsageGuide {
            expanded: usageTitle.isExpanded
            items: [
                i18n("<b>Left-click</b> the folder title to switch between system directories."),
                i18n("<b>Left-click</b> the <b>+ icon</b> to create new folders, documents, or <b>app shortcuts</b>."),
                i18n("<b>Double-click</b> any item to open it with the system default application."),
                i18n("<b>Middle-click</b> an item to open the <b>context menu</b> for file actions."),
                i18n("<b>Middle-click</b> empty space to <b>Paste</b> files or images from clipboard."),
                i18n("Use <b>Ctrl</b> and <b>Shift</b> for multi-selection operations.")
            ]
        }
    }

    PluginAbout {
        repoUrl: "https://github.com/suruibin/dms-conky"
        extraLinks: [
            { label: "Source", url: "https://github.com/hthienloc/dms-folder-view", icon: "link" }
        ]
        contributorsText: i18n("Contributors")
        loadingContributorsText: i18n("Loading contributors...")
    }
}
