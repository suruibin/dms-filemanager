import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Services
import "./dms-common"

Item {
    id: root
    property string filePath: ""
    property string fileName: ""
    property bool isDir: false
    property double sizeScale: 1.0
    property bool hover: false
    property string appIcon: ""
    property string iconName: "insert_drive_file"
    property string iconColor: ""
    property string itemType: "other"

    readonly property bool isImage: root.itemType === "image"
    readonly property bool isAudio: root.itemType === "audio"
    readonly property bool isPDF: root.itemType === "pdf"
    readonly property bool isVideo: root.itemType === "video"

    property string artSource: ""
    property bool showThumbnail: (isImage || isAudio || isPDF || isVideo || root.appIcon !== "") && !isDir && artSource !== "failed"

    DankIcon {
        anchors.centerIn: parent
        name: root.iconName
        size: parent.width * 0.8
        color: root.iconColor !== "" ? root.iconColor : Theme.surfaceText
        visible: !root.showThumbnail || img.status !== Image.Ready
        scale: root.hover ? 1.08 : 1.0
        Behavior on scale { NumberAnimation { duration: 150 } }
    }

    Image {
        id: img
        anchors.centerIn: parent
        width: parent.width - 4
        height: parent.height - 4
        source: {
            if (root.appIcon !== "") {
                if (root.appIcon.startsWith("file://")) return root.appIcon;
                return Quickshell.iconPath(root.appIcon);
            }
            if (root.artSource.startsWith("file://")) return root.artSource;
            if (root.isImage && root.filePath !== "") {
                return root.filePath.startsWith("file://") ? root.filePath : "file://" + root.filePath;
            }
            return "";
        }
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        sourceSize.width: 64
        sourceSize.height: 64
        visible: root.showThumbnail
        opacity: status === Image.Ready ? 1.0 : 0.0
        scale: root.hover ? 1.08 : 1.0
        Behavior on opacity { NumberAnimation { duration: 200 } }
        Behavior on scale { NumberAnimation { duration: 150 } }

        onStatusChanged: {
            if (status === Image.Error && root.isImage) {
                root.artSource = "failed";
            }
        }
    }

    function djb2Hash(str) {
        let hash = 5381;
        for (let i = 0; i < str.length; i++) {
            hash = ((hash << 5) + hash) + str.charCodeAt(i);
            hash = hash & 0x7FFFFFFF;
        }
        return hash.toString(16).padStart(8, '0');
    }

    function _cleanPath(url) {
        let path = String(url);
        if (path.startsWith("file://")) path = path.substring(7);
        if (path.startsWith("localhost/")) path = path.substring(9);
        return path;
    }

    function requestThumbnail() {
        if (isDir || artSource !== "" || filePath === "" || artSource === "failed") return;
        
        // Use a timer to stagger requests and ensure properties are settled
        loadTimer.restart();
    }

    Timer {
        id: loadTimer
        interval: 50 + Math.random() * 500 // Random delay to spread load
        repeat: false
        onTriggered: {
            if (isDir || artSource !== "" || filePath === "") return;
            
            const rawPath = _cleanPath(filePath);
            const cacheDir = Paths.strip(Paths.cache) + "/dmsfilemanager/thumbs";
            const hash = djb2Hash(rawPath);
            const cachePath = cacheDir + "/" + hash + ".jpg";
            
            if (isAudio) {
                extractAudioArt(rawPath, cacheDir, cachePath, hash);
            } else if (isPDF) {
                extractPDFThumb(rawPath, cacheDir, cachePath, hash);
            } else if (isVideo) {
                extractVideoThumb(rawPath, cacheDir, cachePath, hash);
            }
        }
    }

    function extractAudioArt(rawPath, cacheDir, cachePath, hash) {
        Quickshell.execDetached(["mkdir", "-p", cacheDir]);
        
        Proc.runCommand("check-art-" + hash, ["test", "-f", cachePath], (out, code) => {
            if (!root) return;
            if (code === 0) {
                root.artSource = "file://" + cachePath;
            } else {
                const cmd = ["ffmpeg", "-y", "-i", rawPath, "-an", "-frames:v", "1", "-f", "image2", cachePath];
                Proc.runCommand("extract-art-" + hash, cmd, (out2, code2) => {
                    if (!root) return;
                    if (code2 === 0) {
                        root.artSource = "file://" + cachePath;
                    } else {
                        root.artSource = "failed";
                    }
                }, 100);
            }
        });
    }

    function extractPDFThumb(rawPath, cacheDir, cachePath, hash) {
        Quickshell.execDetached(["mkdir", "-p", cacheDir]);
        
        Proc.runCommand("check-pdf-" + hash, ["test", "-f", cachePath], (out, code) => {
            if (!root) return;
            if (code === 0) {
                root.artSource = "file://" + cachePath;
            } else {
                const prefix = cacheDir + "/" + hash;
                const cmd = ["pdftoppm", "-jpeg", "-singlefile", "-scale-to", "128", rawPath, prefix];
                Proc.runCommand("extract-pdf-" + hash, cmd, (out2, code2) => {
                    if (!root) return;
                    if (code2 === 0) {
                        root.artSource = "file://" + cachePath;
                    } else {
                        root.artSource = "failed";
                    }
                }, 100);
            }
        });
    }

    function extractVideoThumb(rawPath, cacheDir, cachePath, hash) {
        Quickshell.execDetached(["mkdir", "-p", cacheDir]);
        
        Proc.runCommand("check-video-" + hash, ["test", "-f", cachePath], (out, code) => {
            if (!root) return;
            if (code === 0) {
                root.artSource = "file://" + cachePath;
            } else {
                const cmd = ["ffmpeg", "-y", "-ss", "00:00:02", "-i", rawPath, "-vf", "scale=128:-1", "-frames:v", "1", "-f", "image2", cachePath];
                Proc.runCommand("extract-video-" + hash, cmd, (out2, code2) => {
                    if (!root) return;
                    if (code2 === 0) {
                        root.artSource = "file://" + cachePath;
                    } else {
                        root.artSource = "failed";
                    }
                }, 100);
            }
        });
    }

    onFilePathChanged: requestThumbnail()
    onIsAudioChanged: requestThumbnail()
    onIsPDFChanged: requestThumbnail()
    onIsVideoChanged: requestThumbnail()

    Component.onCompleted: requestThumbnail()
    Component.onDestruction: loadTimer.stop()
}
