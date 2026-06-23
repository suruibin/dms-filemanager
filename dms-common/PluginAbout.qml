import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Common
import qs.Widgets

// PluginAbout.qml
// All-in-one About section: header, GitHub link, and contributors list.
// Usage:
//   PluginAbout {
//       pluginName: "My Plugin"
//       pluginIcon: "extension"
//       repoUrl:    "https://github.com/hthienloc/dms-my-plugin"
//   }
SettingsCard {
    id: root

    property string repoUrl: ""
    // Extra links shown below the GitHub link, e.g. [{label: "Source", url: "..."}]
    property var extraLinks: []
    // Text overrides — set from parent to use plugin-specific i18n
    property string contributorsText: "Contributors"
    property string loadingContributorsText: "Loading contributors..."
    property color githubSvgColor: Theme.surfaceText
    Behavior on githubSvgColor { ColorAnimation { duration: 150 } }
    readonly property string svgTemplate: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="%COLOR%"><path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z"/></svg>'
    readonly property string githubSvgSource: "data:image/svg+xml;utf8," + svgTemplate.replace("%COLOR%", String(githubSvgColor).replace("#", "%23"))

    property var _contributors: []
    property bool _loading: false

    // Collect all GitHub repo paths from repoUrl + extraLinks
    function _githubRepos() {
        var repos = [];
        if (root.repoUrl) {
            var p = root.repoUrl.replace("https://github.com/", "").replace(/\/+$/, "");
            if (p) repos.push(p);
        }
        for (var i = 0; i < root.extraLinks.length; i++) {
            var url = root.extraLinks[i].url;
            if (url && url.indexOf("github.com/") !== -1) {
                var ep = url.replace(/^https?:\/\/github.com\//, "").replace(/\/+$/, "");
                if (ep && repos.indexOf(ep) === -1) repos.push(ep);
            }
        }
        return repos;
    }

    function _fetchContributors() {
        var repos = root._githubRepos();
        if (repos.length === 0) return;

        root._loading = true;
        root._contributors = [];
        var pending = repos.length;

        for (var r = 0; r < repos.length; r++) {
            // IIFE captures each repoPath + xhr per iteration (var is function-scoped)
            (function(repoPath) {
                var xhr = new XMLHttpRequest();
                xhr.onreadystatechange = function() {
                    if (xhr.readyState !== XMLHttpRequest.DONE) return;
                    if (!root) return;

                    if (xhr.status === 200) {
                        try {
                            var data = JSON.parse(xhr.responseText);
                            if (Array.isArray(data)) {
                                var existing = {};
                                for (var e = 0; e < root._contributors.length; e++)
                                    existing[root._contributors[e].name] = true;
                                for (var d = 0; d < data.length; d++) {
                                    if (!existing[data[d].login]) {
                                        root._contributors = root._contributors.concat([{
                                            name:   data[d].login,
                                            avatar: data[d].avatar_url,
                                            url:    data[d].html_url
                                        }]);
                                        existing[data[d].login] = true;
                                    }
                                }
                            }
                        } catch (e) {
                            console.error("[PluginAbout] parse error:", e);
                        }
                    }
                    pending--;
                    if (pending === 0) root._loading = false;
                };
                xhr.open("GET", "https://api.github.com/repos/" + repoPath + "/contributors");
                xhr.send();
            })(repos[r]);
        }
    }

    Component.onCompleted: _fetchContributors()
    onRepoUrlChanged:      _fetchContributors()
    onExtraLinksChanged:   _fetchContributors()

    // ── Contributors ────────────────────────────────────────────────────────
    // Title Row: Link to GitHub if repoUrl is present, otherwise show generic title
    Item {
        height: 32
        width: parent.width

        MouseArea {
            id: headerLink
            height: parent.height
            width: contentRow.implicitWidth
            anchors.centerIn: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            visible: root.repoUrl !== ""
            onClicked: {
                Quickshell.execDetached(["gio", "open", root.repoUrl])
            }
            onContainsMouseChanged: {
                root.githubSvgColor = containsMouse ? Theme.primary : Theme.surfaceText;
            }

            Row {
                id: contentRow
                spacing: Theme.spacingS
                height: parent.height

                Image {
                    source: root.githubSvgSource
                    width: 20
                    height: 20
                    anchors.verticalCenter: parent.verticalCenter
                    fillMode: Image.PreserveAspectFit
                }

                StyledText {
                    text: root.contributorsText
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    color: root.githubSvgColor
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        Row {
            spacing: Theme.spacingS
            height: parent.height
            anchors.centerIn: parent
            visible: root.repoUrl === ""

            DankIcon {
                name: "groups"
                size: 18
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.contributorsText
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Bold
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    StyledText {
        text: root.loadingContributorsText
        visible: root._loading && root._contributors.length === 0
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    Flow {
        width: parent.width
        spacing: Theme.spacingL
        visible: !root._loading || root._contributors.length > 0

        Repeater {
            model: root._contributors
            delegate: Row {
                spacing: Theme.spacingS
                height: 32

                Rectangle {
                    width: 32; height: 32; radius: 16
                    color: Theme.surfaceContainerHigh
                    clip: true
                    anchors.verticalCenter: parent.verticalCenter
                    Image {
                        source: modelData.avatar
                        anchors.fill: parent
                        fillMode: Image.PreserveAspectCrop
                    }
                }

                StyledText {
                    text: modelData.name
                    font.bold: true
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    // ── Extra Links ──────────────────────────────────────────────────────────
    Repeater {
        model: root.extraLinks
        delegate: Item {
            height: 32
            width: parent.width

            MouseArea {
                height: parent.height
                width: row.implicitWidth
                anchors.centerIn: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Quickshell.execDetached(["gio", "open", modelData.url])

                property color _color: Theme.surfaceText
                Behavior on _color { ColorAnimation { duration: 150 } }

                onContainsMouseChanged: _color = containsMouse ? Theme.primary : Theme.surfaceText

                Row {
                    id: row
                    spacing: Theme.spacingS
                    height: parent.height

                    DankIcon {
                        name: modelData.icon || "link"
                        size: 18
                        color: parent.parent._color
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: modelData.label
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Bold
                        color: parent.parent._color
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }
    }
}
