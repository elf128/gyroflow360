// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2021-2022 Adrian <adrian.eddy at gmail>

import QtQuick
import QtQuick.Dialogs

import "../components/"

MenuItem {
    id: root;
    text: qsTr("Camera Lens Profile");
    iconName: "lens";
    objectName: "lens";

    property int calibWidth: 0;
    property int calibHeight: 0;

    property int videoWidth: 0;
    property int videoHeight: 0;

    property real input_horizontal_stretch: 1;
    property real input_vertical_stretch: 1;

    property real cropFactor: 0;

    property bool lensProfilesListPrepared: false;
    property var distortionCoeffs: [];
    property string profileName;
    property string profileOriginalJson;
    property string profileChecksum;

    property bool fetched_from_github: false;
    property bool selected_manually: false;
    // Whether the loaded profile declares a second lens - read by other files (e.g.
    // VideoArea.qml's is360Camera, VideoInformation.qml's secondary-lens info section) as
    // window.lensProfile.isDualLens. The secondary file itself (path, browse UI, its own
    // media info) lives in VideoInformation.qml now, alongside the primary file's info.
    property bool isDualLens: false;

    FileDialog {
        id: fileDialog;
        property var extensions: ["json"];

        title: qsTr("Choose a lens profile")
        nameFilters: [qsTr("Lens profiles") + " (*.json" + (Qt.platform.os == "ios"? " *.txt" : "") + ")"];
        type: "lens";
        onAccepted: loadFile(fileDialog.selectedFile);
    }
    function loadFile(url: url): void {
        root.selected_manually = true;
        controller.load_lens_profile(url.toString());
    }

    FileDialog {
        id: saveFileDialog;
        fileMode: FileDialog.SaveFile;
        defaultSuffix: "json";

        title: qsTr("Save lens profile");
        nameFilters: Qt.platform.os == "android"? undefined : [qsTr("Lens profiles") + " (*.json)"];
        type: "output-preset";
        onAccepted: controller.save_lens_profile(selectedFile);
        Component.onCompleted: {
            if (Qt.platform.os != "android" && Qt.platform.os != "ios") {
                currentFolder = filesystem.path_to_url(settings.dataDir("lens_profiles"));
            }
        }
    }

    function loadGyroflow(obj: var): void {
        if (typeof obj.light_refraction_coefficient !== "undefined") {
            isUnderwater.checked = Math.round(+obj.light_refraction_coefficient * 1000) == 1330;
        }
    }

    // Declared at root scope (not inside either AdvancedSection) so both the lens-1 and
    // lens-2 Advanced sections below can use it.
    component SmallNumberField: NumberField {
        property bool preventChange2: true;
        width: parent.width / 2;
        precision: 12;
        property string param: "  ";
        property bool isLens2: false;
        tooltip: param[0] + "<font size=\"1\">" + param[1] + "</font>"
        font.pixelSize: 11 * dpiScale;
        onValueChanged: {
            if (!preventChange2) {
                if (isLens2) controller.set_lens2_param(param, value);
                else controller.set_lens_param(param, value);
            }
        }
        function setInitialValue(v: real): void {
            preventChange2 = true;
            value = v;
            preventChange2 = false;
        }
    }

    Component.onCompleted: {
        controller.load_profiles(true);

        QT_TRANSLATE_NOOP("TableList", "Camera");
        QT_TRANSLATE_NOOP("TableList", "Lens");
        QT_TRANSLATE_NOOP("TableList", "Setting");
        QT_TRANSLATE_NOOP("TableList", "Additional info");
        QT_TRANSLATE_NOOP("TableList", "Dimensions");
        QT_TRANSLATE_NOOP("TableList", "Calibrated by");
        QT_TRANSLATE_NOOP("TableList", "Focal length");
        QT_TRANSLATE_NOOP("TableList", "Crop factor");
        QT_TRANSLATE_NOOP("TableList", "Asymmetrical");
        QT_TRANSLATE_NOOP("TableList", "Distortion model");
        QT_TRANSLATE_NOOP("TableList", "Digital lens");
    }
    Timer {
        id: profilesUpdateTimer;
        interval: 1000;
        property bool fromDisk: true;
        onTriggered: controller.load_profiles(fromDisk);
    }
    Connections {
        target: controller;
        function onAll_profiles_loaded(): void {
            if (!lensProfilesListPrepared) { // If it's the first load
                controller.request_profile_ratings();
            }

            lensProfilesListPrepared = true;

            root.loadFavorites();
            if (!root.fetched_from_github) {
                root.fetched_from_github = true;
                controller.fetch_profiles_from_github();
            }
        }
        function onLens_profiles_updated(fromDisk: bool): void {
            profilesUpdateTimer.fromDisk = fromDisk;
            profilesUpdateTimer.start();
        }
        function onLens_profile_loaded(json_str: string, filepath: string, checksum: string): void {
            if (json_str) {
                const obj = JSON.parse(json_str);
                if (obj) {
                    // Lens-level fields (calibration, distortion, etc.) live in obj.lens[0] in
                    // the current format; legacy single-lens profiles have no "lens" array at
                    // all and keep everything flattened at the top, so fall back to obj itself.
                    const lens0 = (obj.lens && obj.lens.length > 0) ? obj.lens[0] : obj;

                    let lensInfo = {
                        "Camera":          obj.camera_brand + " " + obj.camera_model,
                        "Lens":            lens0.lens_model,
                        "Setting":         obj.camera_setting,
                        "Additional info": obj.note,
                        "Dimensions":      lens0.calib_dimension.w + "x" + lens0.calib_dimension.h,
                        "Calibrated by":   obj.calibrated_by
                    };

                    if (+lens0.focal_length > 0) lensInfo["Focal length"] = lens0.focal_length.toFixed(2) + " mm";
                    if (+lens0.crop_factor  > 0) lensInfo["Crop factor"]  = lens0.crop_factor.toFixed(2) + "x";
                    if (lens0.asymmetrical) lensInfo["Asymmetrical"] = qsTr("Yes");
                    if (lens0.distortion_model && lens0.distortion_model != "opencv_fisheye") lensInfo["Distortion model"] = lens0.distortion_model;
                    if (lens0.digital_lens) lensInfo["Digital lens"] = lens0.digital_lens;

                    info.model = lensInfo;

                    root.cropFactor = +lens0.crop_factor;

                    if (!root.selected_manually &&
                           (obj.calibrated_by == "Eddy" ||
                            obj.calibrated_by == "GoPro" ||
                            obj.calibrated_by == "DJI" ||
                            obj.calibrated_by == "Xtra" ||
                            obj.calibrated_by == "Insta360" ||
                            obj.calibrated_by == "Canon" ||
                            obj.calibrated_by == "Sony")) {
                        root.opened = false;
                        window.motionData.opened = false;
                    }

                    officialInfo.show = !obj.official && !settings.value("rated-profile-" + checksum, false);
                    officialInfo.canRate = true;
                    officialInfo.thankYou = false;
                    root.isDualLens = !!(obj.lens && obj.lens.length > 1);
                    root.profileName = (filepath || obj.name || "").replace(/^.*?[\/\\]([^\/\\]+?)$/, "$1");
                    root.profileOriginalJson = json_str;
                    root.profileChecksum = checksum;

                    if (obj.output_dimension && obj.output_dimension.w > 0 && (window.exportSettings.outWidth != obj.output_dimension.w || window.exportSettings.outHeight != obj.output_dimension.h)) {
                        Qt.callLater(window.exportSettings.lensProfileLoaded, obj.output_dimension.w, obj.output_dimension.h);
                    }
                    if (+lens0.frame_readout_time && Math.abs(+lens0.frame_readout_time) > 0) {
                        window.stab.setFrameReadoutTime(lens0.frame_readout_time, lens0.frame_readout_direction);
                    }
                    if (+obj.gyro_lpf && Math.abs(+obj.gyro_lpf) > 0) {
                        window.motionData.setGyroLpf(obj.gyro_lpf);
                    }
                    if (lens0.sync_settings && Object.keys(lens0.sync_settings).length > 0) {
                        window.sync.loadGyroflow({
                            synchronization: lens0.sync_settings
                        });
                    }

                    root.input_horizontal_stretch = lens0.input_horizontal_stretch > 0.01? lens0.input_horizontal_stretch : 1.0;
                    root.input_vertical_stretch   = lens0.input_vertical_stretch   > 0.01? lens0.input_vertical_stretch   : 1.0;

                    root.calibWidth  = lens0.calib_dimension.w / root.input_horizontal_stretch;
                    root.calibHeight = lens0.calib_dimension.h / root.input_vertical_stretch;
                    const coeffs = lens0.fisheye_params.distortion_coeffs;
                    root.distortionCoeffs = coeffs;
                    const mtrx = lens0.fisheye_params.camera_matrix;
                    k1.setInitialValue(coeffs[0] || 0.0);
                    k2.setInitialValue(coeffs[1] || 0.0);
                    k3.setInitialValue(coeffs[2] || 0.0);
                    k4.setInitialValue(coeffs[3] || 0.0);
                    fx.setInitialValue(mtrx[0][0]);
                    fy.setInitialValue(mtrx[1][1]);
                    cx.setInitialValue(mtrx[0][2]);
                    cy.setInitialValue(mtrx[1][2]);

                    const lens2 = (obj.lens && obj.lens.length > 1) ? obj.lens[1] : null;
                    if (lens2) {
                        let lens2Info = {
                            "Lens":       lens2.lens_model,
                            "Dimensions": lens2.calib_dimension.w + "x" + lens2.calib_dimension.h
                        };
                        if (lens2.distortion_model && lens2.distortion_model != "opencv_fisheye") lens2Info["Distortion model"] = lens2.distortion_model;
                        info2.model = lens2Info;

                        const coeffs2 = lens2.fisheye_params.distortion_coeffs;
                        const mtrx2 = lens2.fisheye_params.camera_matrix;
                        k1_2.setInitialValue(coeffs2[0] || 0.0);
                        k2_2.setInitialValue(coeffs2[1] || 0.0);
                        k3_2.setInitialValue(coeffs2[2] || 0.0);
                        k4_2.setInitialValue(coeffs2[3] || 0.0);
                        fx2.setInitialValue(mtrx2[0][0]);
                        fy2.setInitialValue(mtrx2[1][1]);
                        cx2.setInitialValue(mtrx2[0][2]);
                        cy2.setInitialValue(mtrx2[1][2]);

                        const rot = lens2.rotation_offset || [1.0, 0.0, 0.0, 0.0];
                        rotationEditor.setInitialValue(rot[0], rot[1], rot[2], rot[3]);
                    } else {
                        info2.model = ({});
                    }

                    // Set asymmetrical lens center bias
                    /*if (lens0.asymmetrical) {
                        console.log(-((mtrx[0][2] / (lens0.calib_dimension.w / 2.0)) - 1.0));
                        console.log(-((mtrx[1][2] / (lens0.calib_dimension.h / 2.0)) - 1.0));
                    }*/
                    // If focal length in pixels is large, it's more likely that Almeida pose estimator will yield better results
                    if (mtrx[0][0] > 10000) {
                        window.sync.poseMethod.currentIndex = 1; // Almeida
                    }
                }
                Qt.callLater(controller.recompute_threaded);
            }
        }
    }

    property int currentVideoAspectRatio: Math.round((root.videoWidth / Math.max(1, root.videoHeight)) * 1000);
    property int currentVideoAspectRatioSwapped: Math.round((root.videoHeight / Math.max(1, root.videoWidth)) * 1000);

    property var favorites: ({});
    function loadFavorites(): void {
        const list = settings.value("lensProfileFavorites", "");
        let fav = {};
        for (const x of list.split(",")) {
            if (x)
                fav[x] = 1;
        }
        favorites = fav;
    }
    function updateFavorites(): void {
        settings.setValue("lensProfileFavorites", Object.keys(favorites).filter(v => v).join(","));
    }

    SearchField {
        id: search;
        placeholderText: qsTr("Search...");
        height: 25 * dpiScale;
        width: parent.width;
        topPadding: 5 * dpiScale;
        profilesMenu: root;
        onSelected: (item) => {
            const lensPathOrId = item[1];
            if (lensPathOrId.endsWith(".gyroflow")) {
                window.videoArea.loadGyroflowData(JSON.parse(controller.get_preset_contents(lensPathOrId)), 0);
            } else {
                root.selected_manually = true;
                controller.load_lens_profile(lensPathOrId);
            }
        }
        popup.lv.delegate: LensProfileSearchDelegate {
            popup: search.popup;
            profilesMenu: root;
        }
    }
    Row {
        anchors.horizontalCenter: parent.horizontalCenter;
        spacing: 10 * dpiScale;
        Button {
            text: qsTr("Open file");
            iconName: "file-empty"
            onClicked: fileDialog.open2();
        }
        Button {
            text: qsTr("Save");
            iconName: "save";
            enabled: controller.lens_loaded;
            onClicked: saveFileDialog.open2();
        }
        Button {
            text: qsTr("Create new");
            iconName: "plus";
            icon.width: 15 * dpiScale;
            icon.height: 15 * dpiScale;
            property var calibratorWnd: null;
            onClicked: {
                if (!calibratorWnd) {
                    ui_tools.init_calibrator();
                    calibratorWnd = Qt.createComponent("../Calibrator.qml").createObject(main_window)
                    calibratorWnd.show();
                    calibratorWnd.closing.connect(function(e) {
                        calibratorWnd.destroy();
                        calibratorWnd = null;
                    })
                }
            }
        }
    }

    InfoMessageSmall {
        id: officialInfo;
        type: InfoMessage.Warning;
        show: false;
        property bool canRate: true;
        property bool thankYou: false;
        text: qsTr("This lens profile is unofficial, we can't guarantee its correctness. Use at your own risk.") + (canRate? "<br>" +
              qsTr("Rate this profile: [Good] | [Bad]")
              .replace(/\[(.*?)\]/, "<a href=\"#good\">$1</a>")
              .replace(/\[(.*?)\]/, "<a href=\"#bad\">$1</a>") : (thankYou? "<br>" + qsTr("Thank you for rating this profile.") : ""));

        MouseArea {
            anchors.fill: parent;
            cursorShape: parent.t.hoveredLink? Qt.PointingHandCursor : Qt.ArrowCursor;
            acceptedButtons: Qt.NoButton;
        }
        Connections {
            target: officialInfo.t;
            function onLinkActivated(link: url): void {
                controller.rate_profile(root.profileName, root.profileOriginalJson, root.profileChecksum, link === "#good");
                if (link === "#good")
                    settings.setValue("rated-profile-" + root.profileChecksum, true);
                officialInfo.thankYou = true;
                officialInfo.canRate = false;
                tyTimer.start();
            }
        }
        Timer {
            id: tyTimer;
            interval: 5000;
            onTriggered: officialInfo.thankYou = false;
        }
    }

    InfoMessageSmall {
        type: lensRatio != videoRatio? InfoMessage.Error : InfoMessage.Warning;
        show: root.calibWidth > 0 && root.videoWidth > 0 && (root.calibWidth != root.videoWidth || root.calibHeight != root.videoHeight);
        property string lensRatio: (root.calibWidth / Math.max(1, root.calibHeight)).toFixed(3);
        property string videoRatio: (root.videoWidth / Math.max(1, root.videoHeight)).toFixed(3);
        text: lensRatio != videoRatio? qsTr("Lens profile aspect ratio doesn't match the file aspect ratio. The result will not look correct.") :
                                       qsTr("Lens profile dimensions don't match the file dimensions. The result may not look correct.");
    }

    // Dual-lens secondary file status + browse UI moved to VideoInformation.qml, alongside
    // the primary file's own info (see Controller::load_secondary_video). root.isDualLens
    // above is the only thing other files still read from here.

    TableList {
        id: info;
        copyable: true;
        model: ({ })
    }

    AdvancedSection {
        btn.text: qsTr("Advanced");
        visible: Object.keys(info.model).length > 0

        CheckBox {
            id: isUnderwater;
            text: qsTr("Lens is under water");
            checked: false;
            tooltip: qsTr("Enable if you're filming under water. This will adjust the refraction coefficient.");
            property bool keyframesEnabled: false;

            onCheckedChanged: {
                controller.light_refraction_coefficient = checked? 1.33 : 1.0;
                if (keyframesEnabled) {
                    controller.set_keyframe("LightRefractionCoeff", window.videoArea.timeline.getTimestampUs(), checked? 1.33 : 1.0);
                }
            }
            ContextMenuMouseArea {
                cursorShape: Qt.ibeam;
                underlyingItem: isUnderwater;
                onContextMenu: (isHold, x, y) => menuLoader.popup(isUnderwater, x, y);
            }

            Component {
                id: isUnderwaterMenu;
                Menu {
                    font.pixelSize: 11.5 * dpiScale;
                    Action {
                        iconName: "keyframe";
                        text: qsTr("Enable keyframing");
                        checked: isUnderwater.keyframesEnabled;
                        onTriggered: {
                            checked = !checked;
                            isUnderwater.keyframesEnabled = checked;
                            if (!checked) {
                                controller.clear_keyframes_type("LightRefractionCoeff");
                            }
                        }
                    }
                    Action {
                        iconName: "plus";
                        enabled: isUnderwater.keyframesEnabled;
                        text: qsTr("Add keyframe");
                        onTriggered: controller.set_keyframe("LightRefractionCoeff", window.videoArea.timeline.getTimestampUs(), isUnderwater.checked? 1.33 : 1.0);
                    }
                }
            }
            ContextMenuLoader {
                id: menuLoader;
                sourceComponent: isUnderwaterMenu
            }
        }

        Label {
            text: qsTr("Pixel focal length");

            Row {
                spacing: 4 * dpiScale;
                width: parent.width;
                SmallNumberField { id: fx; param: "fx"; }
                SmallNumberField { id: fy; param: "fy"; }
            }
        }
        Label {
            text: qsTr("Focal center");

            Row {
                spacing: 4 * dpiScale;
                width: parent.width;
                SmallNumberField { id: cx; param: "cx"; }
                SmallNumberField { id: cy; param: "cy"; }
            }
        }
        Label {
            text: qsTr("Distortion coefficients");

            Column {
                spacing: 4 * dpiScale;
                width: parent.width;
                Row {
                    spacing: 4 * dpiScale;
                    width: parent.width;
                    SmallNumberField { id: k1; param: "k1"; precision: 16; }
                    SmallNumberField { id: k2; param: "k2"; precision: 16; }
                }
                Row {
                    spacing: 4 * dpiScale;
                    width: parent.width;
                    SmallNumberField { id: k3; param: "k3"; precision: 16; }
                    SmallNumberField { id: k4; param: "k4"; precision: 16; }
                }
            }
        }
        LinkButton {
            anchors.horizontalCenter: parent.horizontalCenter;
            text: qsTr("Export STMap");
            OutputPathField { id: opf; visible: false; }
            enabled: controller.video_loaded;
            onClicked: {
                opf.selectFolder("", function(folder_url) {
                    if (controller.has_per_frame_lens_data()) {
                        messageBox(Modal.Question, qsTr("This file contains per-frame lens metadata. Do you want to export an STMap sequence or a single frame?"), [
                            { text: qsTr("Single frame"), accent: true, clicked: () => { controller.export_stmap(folder_url, false); } },
                            { text: qsTr("STMap sequence"), clicked: () => { controller.export_stmap(folder_url, true); } },
                        ]);
                    } else {
                        controller.export_stmap(folder_url, false);
                    }
                });
            }

            Connections {
                target: controller;
                function onStmap_progress(progress: real, ready: int, total: int): void {
                    window.videoArea.videoLoader.active = progress < 1;
                    window.videoArea.videoLoader.currentFrame = ready;
                    window.videoArea.videoLoader.totalFrames = total;
                    window.videoArea.videoLoader.text = progress < 1? qsTr("Exporting %1...") : "";
                    window.videoArea.videoLoader.progress = progress < 1? progress : -1;
                    window.videoArea.videoLoader.cancelable = true;
                }
            }
        }
    }

    // Dual-lens calibration setup. The secondary video *file* (path, browse UI) stays in
    // VideoInformation.qml - this is only about lens 2's optical calibration, which lives on
    // profile.lens[1] (see Controller::add_second_lens/load_lens2_profile/set_lens2_param/
    // set_lens2_rotation_offset).
    AdvancedSection {
        btn.text: qsTr("Dual Lens");
        visible: Object.keys(info.model).length > 0;

        Button {
            visible: !root.isDualLens;
            anchors.horizontalCenter: parent.horizontalCenter;
            text: qsTr("Add second lens");
            iconName: "plus";
            onClicked: controller.add_second_lens();
        }

        Column {
            visible: root.isDualLens;
            spacing: 8 * dpiScale;
            width: parent.width;

            Row {
                anchors.horizontalCenter: parent.horizontalCenter;
                spacing: 10 * dpiScale;
                Button {
                    text: qsTr("Load lens 2 profile file");
                    iconName: "file-empty";
                    onClicked: lens2FileDialog.open2();
                }
                Button {
                    text: qsTr("Remove second lens");
                    iconName: "bin";
                    onClicked: messageBox(Modal.Question, qsTr("This will discard lens 2's calibration data. Continue?"), [
                        { text: qsTr("Yes"), accent: true, clicked: () => controller.remove_second_lens() },
                        { text: qsTr("No"), clicked: () => {} },
                    ]);
                }
            }
            FileDialog {
                id: lens2FileDialog;
                title: qsTr("Choose a lens profile for the second lens");
                nameFilters: [qsTr("Lens profiles") + " (*.json" + (Qt.platform.os == "ios"? " *.txt" : "") + ")"];
                type: "lens";
                onAccepted: controller.load_lens2_profile(lens2FileDialog.selectedFile.toString());
            }

            TableList {
                id: info2;
                copyable: true;
                model: ({ })
            }

            Label {
                text: qsTr("Pixel focal length");
                Row {
                    spacing: 4 * dpiScale;
                    width: parent.width;
                    SmallNumberField { id: fx2; param: "fx"; isLens2: true; }
                    SmallNumberField { id: fy2; param: "fy"; isLens2: true; }
                }
            }
            Label {
                text: qsTr("Focal center");
                Row {
                    spacing: 4 * dpiScale;
                    width: parent.width;
                    SmallNumberField { id: cx2; param: "cx"; isLens2: true; }
                    SmallNumberField { id: cy2; param: "cy"; isLens2: true; }
                }
            }
            Label {
                text: qsTr("Distortion coefficients");
                Column {
                    spacing: 4 * dpiScale;
                    width: parent.width;
                    Row {
                        spacing: 4 * dpiScale;
                        width: parent.width;
                        SmallNumberField { id: k1_2; param: "k1"; precision: 16; isLens2: true; }
                        SmallNumberField { id: k2_2; param: "k2"; precision: 16; isLens2: true; }
                    }
                    Row {
                        spacing: 4 * dpiScale;
                        width: parent.width;
                        SmallNumberField { id: k3_2; param: "k3"; precision: 16; isLens2: true; }
                        SmallNumberField { id: k4_2; param: "k4"; precision: 16; isLens2: true; }
                    }
                }
            }

            Label {
                text: qsTr("Lens 2 rotation, relative to lens 1 (back-to-back = 180° about Y)");

                Column {
                    id: rotationEditor;
                    spacing: 4 * dpiScale;
                    width: parent.width;
                    // Guards both directions of the Euler<->quaternion sync below from
                    // re-triggering each other (and from notifying the controller during
                    // programmatic initialization via setInitialValue).
                    property bool preventChange3: true;

                    function setInitialValue(w: real, x: real, y: real, z: real): void {
                        preventChange3 = true;
                        quatW.value = w; quatX.value = x; quatY.value = y; quatZ.value = z;
                        quatToEulerFields();
                        preventChange3 = false;
                    }
                    function quatToEulerFields(): void {
                        const e = rotationEditor.quatToEuler(quatW.value, quatX.value, quatY.value, quatZ.value);
                        rotX.value = e.x; rotY.value = e.y; rotZ.value = e.z;
                    }
                    function eulerToQuatFields(): void {
                        const q = rotationEditor.eulerToQuat(rotX.value, rotY.value, rotZ.value);
                        quatW.value = q.w; quatX.value = q.x; quatY.value = q.y; quatZ.value = q.z;
                    }
                    function onEulerEdited(): void {
                        if (preventChange3) return;
                        preventChange3 = true;
                        eulerToQuatFields();
                        preventChange3 = false;
                        controller.set_lens2_rotation_offset(quatW.value, quatX.value, quatY.value, quatZ.value);
                    }
                    function onQuatEdited(): void {
                        if (preventChange3) return;
                        preventChange3 = true;
                        quatToEulerFields();
                        preventChange3 = false;
                        controller.set_lens2_rotation_offset(quatW.value, quatX.value, quatY.value, quatZ.value);
                    }

                    // Standard ZYX Tait-Bryan (X, Y, Z axis order) <-> quaternion [w,x,y,z].
                    // Implemented directly rather than via Qt's QML quaternion helpers, whose
                    // exact availability/behavior isn't something we can verify without a
                    // build - this is a well-known, independently-verifiable formula, and only
                    // needs to be internally self-consistent since nothing outside this editor
                    // interprets the X/Y/Z fields directly (only the resulting quaternion is
                    // ever sent to the controller).
                    function eulerToQuat(xDeg: real, yDeg: real, zDeg: real): var {
                        const rx = xDeg * Math.PI / 180, ry = yDeg * Math.PI / 180, rz = zDeg * Math.PI / 180;
                        const cx = Math.cos(rx*0.5), sx = Math.sin(rx*0.5);
                        const cy = Math.cos(ry*0.5), sy = Math.sin(ry*0.5);
                        const cz = Math.cos(rz*0.5), sz = Math.sin(rz*0.5);
                        return {
                            w: cx*cy*cz + sx*sy*sz,
                            x: sx*cy*cz - cx*sy*sz,
                            y: cx*sy*cz + sx*cy*sz,
                            z: cx*cy*sz - sx*sy*cz
                        };
                    }
                    function quatToEuler(w: real, x: real, y: real, z: real): var {
                        const sinr_cosp = 2*(w*x + y*z);
                        const cosr_cosp = 1 - 2*(x*x + y*y);
                        const rx = Math.atan2(sinr_cosp, cosr_cosp);
                        const sinp = 2*(w*y - z*x);
                        const ry = Math.abs(sinp) >= 1 ? (Math.sign(sinp) * Math.PI/2) : Math.asin(sinp);
                        const siny_cosp = 2*(w*z + x*y);
                        const cosy_cosp = 1 - 2*(y*y + z*z);
                        const rz = Math.atan2(siny_cosp, cosy_cosp);
                        return { x: rx*180/Math.PI, y: ry*180/Math.PI, z: rz*180/Math.PI };
                    }

                    BasicText { text: qsTr("Euler angles (°)"); font.pixelSize: 10 * dpiScale; opacity: 0.7; }
                    Row {
                        spacing: 4 * dpiScale;
                        width: parent.width;
                        NumberField { id: rotX; width: parent.width / 3; precision: 3; font.pixelSize: 11 * dpiScale; tooltip: "X"; onValueChanged: rotationEditor.onEulerEdited(); }
                        NumberField { id: rotY; width: parent.width / 3; precision: 3; font.pixelSize: 11 * dpiScale; tooltip: "Y"; onValueChanged: rotationEditor.onEulerEdited(); }
                        NumberField { id: rotZ; width: parent.width / 3; precision: 3; font.pixelSize: 11 * dpiScale; tooltip: "Z"; onValueChanged: rotationEditor.onEulerEdited(); }
                    }
                    BasicText { text: qsTr("Quaternion (w, x, y, z)"); font.pixelSize: 10 * dpiScale; opacity: 0.7; }
                    Row {
                        spacing: 4 * dpiScale;
                        width: parent.width;
                        NumberField { id: quatW; width: parent.width / 4; precision: 6; font.pixelSize: 11 * dpiScale; tooltip: "w"; onValueChanged: rotationEditor.onQuatEdited(); }
                        NumberField { id: quatX; width: parent.width / 4; precision: 6; font.pixelSize: 11 * dpiScale; tooltip: "x"; onValueChanged: rotationEditor.onQuatEdited(); }
                        NumberField { id: quatY; width: parent.width / 4; precision: 6; font.pixelSize: 11 * dpiScale; tooltip: "y"; onValueChanged: rotationEditor.onQuatEdited(); }
                        NumberField { id: quatZ; width: parent.width / 4; precision: 6; font.pixelSize: 11 * dpiScale; tooltip: "z"; onValueChanged: rotationEditor.onQuatEdited(); }
                    }
                    Button {
                        anchors.horizontalCenter: parent.horizontalCenter;
                        text: qsTr("Reset to back-to-back (180°)");
                        onClicked: {
                            rotationEditor.preventChange3 = true;
                            quatW.value = 0.0; quatX.value = 0.0; quatY.value = 1.0; quatZ.value = 0.0;
                            rotationEditor.quatToEulerFields();
                            rotationEditor.preventChange3 = false;
                            controller.set_lens2_rotation_offset(0.0, 0.0, 1.0, 0.0);
                        }
                    }
                }
            }
        }
    }

    DropTarget {
        parent: root.innerItem;
        color: styleBackground2;
        z: 999;
        anchors.rightMargin: -28 * dpiScale;
        anchors.topMargin: 35 * dpiScale;
        anchors.bottomMargin: -35 * dpiScale;
        extensions: fileDialog.extensions;
        onLoadFile: (url) => root.loadFile(url);
    }

    // -------------------------------------------------------------------
    // ---------------------- Maintenance functions ----------------------
    // -------------------------------------------------------------------
    /*
    property int fileno: 0;
    property var files: [
        ... // dir /b | clip
    ];
    Shortcut {
        sequences: ["F8"];
        onActivated: {
            root.fileno = Math.abs(++fileno % files.length);
            console.log(root.fileno);
            controller.load_lens_profile("file:///d:/lens_review/" + root.files[root.fileno]);
        }
    }
    Shortcut {
        sequences: ["F7"];
        onActivated: {
            root.fileno = Math.abs(--fileno % files.length);
            console.log(root.fileno);
            controller.load_lens_profile("file:///d:/lens_review/" + root.files[root.fileno]);
        }
    }
    Shortcut {
        sequences: ["Delete"];
        onActivated: {
            console.log("deleting " + root.files[root.fileno]);
            filesystem.move_to_trash("file:///d:/lens_review/" + root.files[root.fileno]);
        }
    }
    */
}
