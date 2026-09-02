// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2021-2022 Adrian <adrian.eddy at gmail>

import QtQuick
import QtQuick.Dialogs

import "../"
import "../components/"

MenuItem {
    id: root;
    text: qsTr("Video information");
    iconName: "info";
    objectName: "info";

    property real videoRotation: 0;
    property real fps: 0;
    property real org_fps: 0;
    property string filename: "";
    property bool isCalibrator: false;
    property string pixelFormat: "";
    property bool hasAccessToInputDirectory: true;
    property alias infoList: list;
    property var orgModel: [];

    // Dual-lens secondary file - path/browse state lives here now, alongside the primary
    // file's own info (moved from LensProfile.qml, which only still owns isDualLens).
    property string dualLensSecondaryPath: "";

    FileDialog {
        id: secondaryFileDialog;
        title: qsTr("Choose secondary lens video file");
        nameFilters: Qt.platform.os === "android" ? undefined : [qsTr("Video files") + " (*.insv *.mp4 *.mov *.mkv *)"];
        onAccepted: controller.open_dual_lens_file(secondaryFileDialog.selectedFile.toString());
    }

    Component.onCompleted: {
        QT_TRANSLATE_NOOP("TableList", "Created at");
        const fields = [
            QT_TRANSLATE_NOOP("TableList", "File name"),
            QT_TRANSLATE_NOOP("TableList", "Detected camera"),
            QT_TRANSLATE_NOOP("TableList", "Detected lens"),
            QT_TRANSLATE_NOOP("TableList", "Dimensions"),
            QT_TRANSLATE_NOOP("TableList", "Duration"),
            QT_TRANSLATE_NOOP("TableList", "Frame rate"),
            QT_TRANSLATE_NOOP("TableList", "Codec"),
            QT_TRANSLATE_NOOP("TableList", "Pixel format"),
            QT_TRANSLATE_NOOP("TableList", "Audio"),
            QT_TRANSLATE_NOOP("TableList", "Rotation"),
            QT_TRANSLATE_NOOP("TableList", "Contains gyro"),
        ];
        let model = {};
        for (const x of fields) model[x] = "---";
        list.model = model;

        orgModel = JSON.parse(JSON.stringify(model));
        orgModel["Created at"] = "---";

        // Secondary (dual-lens) file info - same fields as the primary file's table above,
        // minus the ones that don't apply to a raw video file with no gyro/camera detection
        // of its own (Detected camera/lens, Contains gyro) - see loadFromVideoMetadata2.
        let model2 = {};
        for (const x of ["File name", "Dimensions", "Duration", "Frame rate", "Codec", "Pixel format", "Audio", "Rotation", "Created at"]) {
            model2[x] = "---";
        }
        list2.model = model2;

        QT_TRANSLATE_NOOP("TableList", "Shutter angle");
        QT_TRANSLATE_NOOP("TableList", "Shutter speed");
        QT_TRANSLATE_NOOP("TableList", "Exposure");
        QT_TRANSLATE_NOOP("TableList", "ISO");
        QT_TRANSLATE_NOOP("TableList", "Color primaries");
        QT_TRANSLATE_NOOP("TableList", "Gamma equation");
        QT_TRANSLATE_NOOP("TableList", "White balance mode");
        QT_TRANSLATE_NOOP("TableList", "White balance");
        QT_TRANSLATE_NOOP("TableList", "Iris");
        QT_TRANSLATE_NOOP("TableList", "Focal length");
        QT_TRANSLATE_NOOP("TableList", "Focus mode");
    }

    function cleanupModel() {
        let model = list.model;
        for (const x in model) {
            if (!orgModel[x])
                delete model[x];
        }
        list.model = model;
        list.modelChanged();
    }

    signal selectFileRequest();

    function loadFromVideoMetadata(md: var, org_w: int, org_h: int): void {
        const framerate = +md["stream.video[0].codec.frame_rate"] || 0;
        const w = org_w || md["stream.video[0].codec.width"] || 0;
        const h = org_h || md["stream.video[0].codec.height"] || 0;
        const bitrate = +md["stream.video[0].codec.bit_rate"]? ((+md["stream.video[0].codec.bit_rate"] / 1024 / 1024)) : 200;

        if (window) {
            window.lensProfile.videoWidth   = w;
            window.lensProfile.videoHeight  = h;
        }
        if (typeof calibrator_window !== "undefined") {
            calibrator_window.lensCalib.setVideoSize(w, h);
            calibrator_window.lensCalib.fps = framerate;
        }

        root.pixelFormat = getPixelFormat(md) || "---";

        root.videoRotation = (360 - (md["stream.video[0].rotation"] || 0)) % 360; // Constrain to 0-360

        list.model["Dimensions"]   = w && h? w + "x" + h : "---";
        list.model["Duration"]     = getDuration(md) || "---";
        list.model["Frame rate"]   = framerate? framerate.toFixed(3) + " fps" : "---";
        list.model["Codec"]        = getCodec(md) || "---";
        list.model["Pixel format"] = root.pixelFormat;
        list.model["Rotation"]     = (root.videoRotation) + " °";
        list.model["Audio"]        = getAudio(md) || "---";
        if (md["metadata.creation_time"]) {
            const created_at = (new Date(Date.parse(md["metadata.creation_time"])));
            list.model["Created at"] = created_at.toLocaleString();
            controller.set_video_created_at(created_at.getTime() / 1000);
        } else {
            delete list.model["Created at"];
        }

        list.modelChanged();

        root.fps = framerate;
        root.org_fps = framerate;

        controller.set_video_rotation(root.videoRotation)

        Qt.callLater(window.exportSettings.videoInfoLoaded, w, h, bitrate);
    }
    // Secondary (dual-lens) lens's own probed metadata - md comes from that lens's own real
    // MDKPlayer (see Controller::init_video_source/wire_video_signals), same flattened
    // "stream.video[0]..." key format as the primary file's md above. Reuses the same
    // getDuration/getCodec/getPixelFormat/getAudio helpers; doesn't touch window.lensProfile
    // or window.exportSettings - those apply to the primary file only.
    function loadFromVideoMetadata2(md: var): void {
        const framerate = +md["stream.video[0].codec.frame_rate"] || 0;
        const w = md["stream.video[0].codec.width"] || 0;
        const h = md["stream.video[0].codec.height"] || 0;
        const rotation = (360 - (md["stream.video[0].rotation"] || 0)) % 360;

        list2.model["Dimensions"]   = w && h? w + "x" + h : "---";
        list2.model["Duration"]     = getDuration(md) || "---";
        list2.model["Frame rate"]   = framerate? framerate.toFixed(3) + " fps" : "---";
        list2.model["Codec"]        = getCodec(md) || "---";
        list2.model["Pixel format"] = getPixelFormat(md) || "---";
        list2.model["Rotation"]     = rotation + " °";
        list2.model["Audio"]        = getAudio(md) || "---";
        if (md["metadata.creation_time"]) {
            list2.model["Created at"] = (new Date(Date.parse(md["metadata.creation_time"]))).toLocaleString();
        } else {
            list2.model["Created at"] = "---";
        }
        list2.modelChanged();
    }
    function updateEntry(key: string, value: string): void {
        if (key == "File name") root.filename = value;
        list.updateEntry(key, value);
    }
    function updateEntryWithTrigger(key: string, value: string): void {
        list.updateEntryWithTrigger(key, value);
    }

    function getDuration(md): string {
        const s = +md["stream.video[0].duration"] / 1000;
        if (s > 60) {
            return Math.floor(s / 60) + " m " + Math.floor(s % 60) + " s";
        } else if (s > 0) {
            return s.toFixed(2) + " s";
        }
        return "";
    }
    function getCodec(md): string {
        const c = md["stream.video[0].codec.name"] || "";
        const bitrate = +md["stream.video[0].codec.bit_rate"]? ((+md["stream.video[0].codec.bit_rate"] / 1024 / 1024).toFixed(2) + " Mbps") : "";

        return c.toUpperCase() + (c? " " : "") + bitrate;
    }
    function getPixelFormat(md): string {
        let pt = md["stream.video[0].codec.format_name"] || "";
        let bits = "8 bit";
        if (pt.indexOf("10le") > -1) { bits = "10 bit"; pt = pt.replace("p10le", "").replace("10le", ""); }
        if (pt.indexOf("12le") > -1) { bits = "12 bit"; pt = pt.replace("p12le", "").replace("12le", ""); }
        if (pt.indexOf("14le") > -1) { bits = "14 bit"; pt = pt.replace("p14le", "").replace("14le", ""); }
        if (pt.indexOf("16le") > -1) { bits = "16 bit"; pt = pt.replace("p16le", "").replace("16le", ""); }
        if (pt.indexOf("f32le") > -1) { bits = "32 bit float"; pt = pt.replace("f32le", ""); }
        if (pt.indexOf("f16le") > -1) { bits = "16 bit float"; pt = pt.replace("f16le", ""); }

        return pt.toUpperCase() + (pt? " " : "") + bits;
    }
    function getAudio(md): string {
        const format = md["stream.audio[0].codec.name"]? (md["stream.audio[0].codec.name"].replace("_", " ").replace("pcm", "PCM").replace("aac", "AAC")) : "";
        const rate = md["stream.audio[0].codec.sample_rate"]? (md["stream.audio[0].codec.sample_rate"] + " Hz") : "";

        return format + (format? " " : "") + rate;
    }

    Button {
        text: qsTr("Open file");
        iconName: "video"
        anchors.horizontalCenter: parent.horizontalCenter;
        onClicked: root.selectFileRequest();
    }

    InfoMessageSmall {
        show: !root.hasAccessToInputDirectory;
        type: InfoMessage.Info;
        text: qsTr("In order to detect project files, video sequences or image sequences, click here and select the directory with input files.");
        OutputPathField { id: opf; visible: false; }
        MouseArea {
            anchors.fill: parent;
            cursorShape: Qt.PointingHandCursor;
            onClicked: {
                opf.selectFolder("", function(_) {
                    window.videoArea.loadFile(window.videoArea.loadedFileUrl);
                });
            }
        }
    }

    TableList {
        id: list;
        columnSpacing: 6 * dpiScale;
        editableFields: isCalibrator? ({}) : ({
            "Rotation": {
                "unit": "°",
                "from": -360,
                "to": 360,
                "value": function() { return root.videoRotation; },
                "keyframe": "VideoRotation",
                "onChange": function(value) {
                    root.videoRotation = value;
                    root.updateEntry("Rotation", root.videoRotation + " °");
                    controller.set_video_rotation(root.videoRotation);
                }
            },
            "Frame rate": {
                "unit": "fps",
                "precision": 3,
                "width": 70,
                "value": function() { return root.fps; },
                "onChange": function(value) {
                    root.fps = +value;
                    root.updateEntry("Frame rate", (+value).toFixed(3) + " fps");
                    controller.override_video_fps(+value, true);

                    const scale = root.fps / root.org_fps;
                    window.sync.everyNthFrame.value = Math.max(1, Math.floor(scale));

                    window.videoArea.timeline.updateDurations();
                }
            }
        });
    }

    Connections {
        target: controller;
        function onDual_lens_file_changed(path: string): void {
            root.dualLensSecondaryPath = path;
            list2.model["File name"] = path ? path.replace(/^.*[\/\\]/, "") : "---";
            list2.modelChanged();
        }
        function onVideo2_metadata_loaded(md: var): void {
            root.loadFromVideoMetadata2(md);
        }
    }

    // Secondary (dual-lens) video file info - only shown once the loaded lens profile
    // declares a second lens. Same shape as the primary file's "Open file" + TableList
    // above (same button, both direct children of the Column MenuItem wraps its content
    // in - Column collapses invisible children on its own, no manual height juggling
    // needed): populated from that lens's own real MDKVideoItem (see
    // Controller::init_video_source, load_secondary_video). "File name" is the first
    // row of list2's own table (see the Connections handler above), same as lens1.
    Button {
        text: qsTr("Open file");
        iconName: "video"
        anchors.horizontalCenter: parent.horizontalCenter;
        visible: window.lensProfile && window.lensProfile.isDualLens;
        onClicked: secondaryFileDialog.open2();
    }

    TableList {
        id: list2;
        columnSpacing: 6 * dpiScale;
        visible: window.lensProfile && window.lensProfile.isDualLens;
    }

    DropTarget {
        parent: root.innerItem;
        color: styleBackground2;
        z: 999;
        anchors.rightMargin: -28 * dpiScale;
        anchors.topMargin: 35 * dpiScale;
        anchors.bottomMargin: -35 * dpiScale;
        extensions: fileDialog.extensions;
        onLoadFile: (path) => window.videoArea.loadFile(path, false)
    }
}
