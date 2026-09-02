// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2021-2022 Adrian <adrian.eddy at gmail>

import QtQuick

import "components/"
import "menu/" as Menu
import "Util.js" as Util

Item {
    id: root;
    width: parent.width;
    height: parent.height;
    anchors.horizontalCenter: parent.horizontalCenter;

    property alias mdkSourceContainer: mdkSourceContainer;
    property alias timeline: timeline;
    property alias durationMs: timeline.durationMs;
    property alias videoLoader: videoLoader;
    property alias stabEnabledBtn: stabEnabledBtn;
    property alias fovOverviewBtn: fovOverviewBtn;
    property alias queue: queue.item;
    property alias statistics: statistics;
    property alias infoMessages: infoMessages;
    property alias gridGuide: gridGuide;
    property alias secondPreview: secondPreview;

    property int outWidth: window? window.exportSettings.outWidth : 0;
    property int outHeight: window? window.exportSettings.outHeight : 0;

    property alias dropRect: dropRect;
    property bool isCalibrator: false;

    property var pendingGyroflowData: null;
    property int pendingQueueJobId: 0;
    property url loadedFileUrl;

    property int fullScreen: 0;
    property string detectedCamera: "";
    property real additionalTopMargin: 0;
    property var mergedFiles: [];

    property Menu.VideoInformation vidInfo: null;
    property bool is360Camera: window.lensProfile && window.lensProfile.isDualLens;

    // Rotate the virtual 360° viewport by dragging. Called from the DragHandler inside vidParent.
    // dx/dy are pixel deltas; positive dx = drag right (look right), positive dy = drag down (look up,
    // matching YouTube-style 360 viewer convention). Coordinate space: X=right, Y=down, Z=forward.
    function rotateViewport360(dx_px, dy_px) {
        const SENSITIVITY = 0.25; // degrees per pixel
        const ts = controller.video_timestamp;

        // Read current look-at; default to straight-forward (0, 0, 1)
        const raw_x = controller.keyframe_value_at_video_timestamp("ViewportLookAtX", ts);
        const raw_y = controller.keyframe_value_at_video_timestamp("ViewportLookAtY", ts);
        const raw_z = controller.keyframe_value_at_video_timestamp("ViewportLookAtZ", ts);
        let lx = (raw_x !== undefined && raw_x !== null) ? +raw_x : 0.0;
        let ly = (raw_y !== undefined && raw_y !== null) ? +raw_y : 0.0;
        let lz = (raw_z !== undefined && raw_z !== null) ? +raw_z : 1.0;

        // Normalise (defensive)
        let len = Math.sqrt(lx*lx + ly*ly + lz*lz);
        if (len < 1e-9) { lx=0; ly=0; lz=1; len=1; }
        lx /= len; ly /= len; lz /= len;

        // Yaw: rotate around world-Y (down) axis. Ry(θ): X'=cos·X+sin·Z, Z'=−sin·X+cos·Z
        const yaw = dx_px * SENSITIVITY * Math.PI / 180;
        const cy = Math.cos(yaw), sy = Math.sin(yaw);
        let rx = cy*lx + sy*lz;
        let ry = ly;
        let rz = -sy*lx + cy*lz;

        // Right axis = forward × world_up where world_up=(0,−1,0)  →  (rz, 0, −rx), normalised
        const rl = Math.sqrt(rx*rx + rz*rz);
        const kx = rl > 1e-9 ? rz/rl : 1.0; // ky = 0
        const kz = rl > 1e-9 ? -rx/rl : 0.0;

        // Pitch: Rodrigues rotation of (rx,ry,rz) around k=(kx,0,kz) by pitch angle
        const pitch = dy_px * SENSITIVITY * Math.PI / 180;
        const cp = Math.cos(pitch), sp = Math.sin(pitch);
        const dot = kx*rx + kz*rz;
        // cross = k × v
        const crx = -kz*ry;
        const cry = kz*rx - kx*rz;
        const crz = kx*ry;

        let fx = rx*cp + crx*sp + kx*dot*(1-cp);
        let fy = ry*cp + cry*sp;               // ky=0 → no dot term
        let fz = rz*cp + crz*sp + kz*dot*(1-cp);

        // Normalise result
        const fl = Math.sqrt(fx*fx + fy*fy + fz*fz);
        if (fl > 1e-9) { fx/=fl; fy/=fl; fz/=fl; }

        // Store as a single keyframe at t=0 (constant for entire clip). Uses the "live" setter
        // (no recompute) since this fires on every drag-move pixel — see viewportDragHandler's
        // onActiveChanged for where the deferred recompute actually gets triggered, once the drag ends.
        controller.set_keyframe_live("ViewportLookAtX", 0, fx);
        controller.set_keyframe_live("ViewportLookAtY", 0, fy);
        controller.set_keyframe_live("ViewportLookAtZ", 0, fz);
        controller.force_video_redraw();
    }

    function loadGyroflowData(obj: var, queueJobId: var): void {
        root.pendingGyroflowData = null;
        root.pendingQueueJobId = 0;

        if (controller.loading_gyro_in_progress) {
            root.pendingGyroflowData = obj;
            root.pendingQueueJobId = +queueJobId;
            controller.cancel_current_operation();
            // we'll get called again from telemetry_loaded
            return;
        }

        let urls = null;
        let project_version = +obj.version;

        if (obj.toString() != '[object Object]') { // obj is url
            urls = controller.get_urls_from_gyroflow_file(obj);
            project_version = controller.get_version_from_gyroflow_file(obj);
        } else if (obj.project_file) {
            urls = controller.get_urls_from_gyroflow_file(obj.project_file);
            project_version = controller.get_version_from_gyroflow_file(obj.project_file);
        } else {
            urls = [
                obj.videofile,
                obj.gyro_source?.filepath || ""
            ];
        }
        if ((!urls || !urls[0]) && !vidInfo.filename) {
            messageBox(Modal.Error, qsTr("Preset can be applied only after loading a video."), [ { text: qsTr("Ok") } ]);
            return;
        }

        const isCorrectVideoLoaded = urls[0] && vidInfo.filename == filesystem.get_filename(urls[0]);
        const isCorrectGyroLoaded  = urls[1] && window.motionData.filename == filesystem.get_filename(urls[1]);
        console.log("Video path:", urls[0], "(" + (isCorrectVideoLoaded? "loaded" : "not loaded") + ")", "Gyro path:", urls[1], "(" + (isCorrectGyroLoaded? "loaded" : "not loaded") + ")");

        if (urls[0] && !isCorrectVideoLoaded) {
            root.pendingGyroflowData = obj;
            root.pendingQueueJobId = +queueJobId;
            console.log("Loading video file", urls[0]);
            loadFile(urls[0], false, +queueJobId);
            if (controller.image_sequence_fps > 0) {
                controller.set_video_frame_rate(controller.image_sequence_fps);
            }
            return;
        }
        if (urls[1] && !isCorrectGyroLoaded && filesystem.exists(urls[1])) {
            root.pendingGyroflowData = obj;
            root.pendingQueueJobId = +queueJobId;
            console.log("Loading gyro file", urls[1]);
            window.motionData.lastSelectedFile = urls[1];
            controller.load_telemetry(urls[1], urls[0] == urls[1] || window.motionData.allMetadata, -1, project_version);
            return;
        }

        controller.set_prevent_recompute(true);
        if (obj.toString() != '[object Object]') {
            // obj is url
            controller.import_gyroflow_file(obj);
        } else if (obj.project_file) {
            controller.import_gyroflow_file(obj.project_file);
        } else {
            controller.import_gyroflow_data(JSON.stringify(obj));
        }
        render_queue.editing_job_id = +queueJobId;
    }
    Connections {
        target: controller;
        function onGyroflow_file_loaded(obj: var): void {
            if (obj) {
                let duration_ms = controller.video_duration;
                const info = obj.video_info || { };
                if (info && Object.keys(info).length > 0) {
                    if (info.hasOwnProperty("vfr_fps") && Math.round(+info.vfr_fps * 1000) != Math.round(+info.fps * 1000)) {
                        vidInfo.updateEntryWithTrigger("Frame rate", +info.vfr_fps);
                    }
                    if (info.hasOwnProperty("rotation")) {
                        vidInfo.updateEntryWithTrigger("Rotation", +info.rotation);
                    }
                    if (info.hasOwnProperty("duration_ms")) {
                        duration_ms = info.duration_ms;
                    }
                }

                for (const ts in obj.offsets) {
                    controller.set_offset(ts, obj.offsets[ts]);
                }
                if (obj.hasOwnProperty("trim_start")) {
                    timeline.setTrimRanges([[obj.trim_start, obj.trim_end]]);
                }
                if (obj.hasOwnProperty("trim_ranges_ms")) {
                    timeline.setTrimRanges(obj.trim_ranges_ms.map(x => [x[0] / duration_ms, (x[1] < 0? duration_ms + x[1] : x[1]) / duration_ms]));
                } else if (obj.hasOwnProperty("trim_ranges")) {
                    timeline.setTrimRanges(obj.trim_ranges);
                }
                window.motionData.loadGyroflow(obj);
                window.stab.loadGyroflow(obj);
                window.advanced.loadGyroflow(obj);
                window.sync.loadGyroflow(obj);
                window.lensProfile.loadGyroflow(obj);
                Qt.callLater(window.exportSettings.loadGyroflow, obj);

                if (obj.hasOwnProperty("image_sequence_start") && +obj.image_sequence_start > 0) {
                    controller.image_sequence_start = +obj.image_sequence_start;
                }
                if (obj.hasOwnProperty("image_sequence_fps") && +obj.image_sequence_fps > 0.0) {
                    controller.set_video_frame_rate(+obj.image_sequence_fps);
                    controller.image_sequence_fps = +obj.image_sequence_fps;
                }
                if (obj.hasOwnProperty("playback_speed")) {
                    let i = 0;
                    const speed = +obj.playback_speed;
                    for (const x of playbackRateCb.model) {
                        const rate = +x.replace("x", "");
                        if (Math.abs(rate - speed) < 0.01) {
                            playbackRateCb.currentIndex = i;
                            break;
                        }
                        ++i;
                    }
                }
                if (obj.hasOwnProperty("muted")) {
                    controller.video_muted = !!obj.muted;
                }
            }
            controller.set_prevent_recompute(false);
            Qt.callLater(controller.recompute_gyro);
            Qt.callLater(controller.recompute_threaded);
            Qt.callLater(timeline.updateDurations);
        }
        function onExternal_sdk_progress(percent: real, sdk_name: string, error_string: string, url: string): void {
            if (externalSdkModal !== null && externalSdkModal.loader !== null) {
                externalSdkModal.loader.visible = percent < 1;
                externalSdkModal.loader.active = percent < 1;
                externalSdkModal.loader.progress = percent;
                externalSdkModal.loader.text = qsTr("Downloading %1 (%2)").arg(sdk_name);
                if (percent >= 1) {
                    externalSdkModal.close();
                    externalSdkModal = null;
                    window.isDialogOpened = false;
                    if (!error_string) {
                        if (url == "ffmpeg_gpl") {
                            messageBox(Modal.Success, qsTr("Component was installed successfully.\nYou need to restart Gyroflow for changes to take effect.\nYour render queue and current file is saved automatically."), [ { text: qsTr("Ok") } ]);
                        } else {
                            loadFile(url, false);
                        }
                    } else {
                        if (Qt.platform.os == "osx") {
                            error_string += "\n" + qsTr("This is often caused by read-only file system.\nMake sure you copied the Gyroflow app to your Applications folder, instead of running from the .dmg directly.");
                        }
                        if (Qt.platform.os == "windows") {
                            error_string += "\n" + qsTr("This is often caused by read-only file system.\nIf you have Gyroflow in C:\\Program Files\\, then you'll need to run Gyroflow as Administrator in order to extract the SDK to the Gyroflow folder.");
                        }
                        messageBox(Modal.Error, error_string, [ { text: qsTr("Ok") } ]);
                    }
                }
            }
        }

        function onMp4_merge_progress(percent: real, error_string: string, url: url): void {
            if (externalSdkModal !== null && externalSdkModal.loader !== null) {
                externalSdkModal.loader.visible = percent < 1;
                externalSdkModal.loader.active = percent < 1;
                externalSdkModal.loader.progress = percent;
                externalSdkModal.loader.text = qsTr("Merging files to %1 (%2)").arg("<b>" + filesystem.display_url(url) + "</b>");
                if (percent >= 1) {
                    externalSdkModal.close();
                    externalSdkModal = null;
                    window.isDialogOpened = false;
                    if (!error_string) {
                        loadFile(url, true);
                    } else {
                        messageBox(Modal.Error, error_string, [ { text: qsTr("Ok") } ]);
                    }
                }
            }
        }
        function onTelemetry_loaded(is_main_video: bool, filename: string, camera: string, additional_data: var): void {
            console.log("Telemetry additional data:", JSON.stringify(additional_data));
            if (is_main_video) {
                root.detectedCamera = camera;
                vidInfo.updateEntry("Detected camera", camera || "---");

                let lens = "";
                if (additional_data.camera_identifier) {
                    const camera_id = additional_data.camera_identifier;
                    if (camera_id) {
                        if (camera_id.lens_model) { lens += camera_id.lens_model; }
                        if (camera_id.lens_info)  { lens += (lens? " " : "") + camera_id.lens_info; }
                    }
                }
                vidInfo.updateEntry("Detected lens", lens || "---");
                vidInfo.updateEntry("Contains gyro", additional_data.contains_motion? "Yes" : "No");
                // If source was detected, but gyro data is empty
                if (camera) {
                    if (!additional_data.contains_motion && !additional_data.contains_quats) {
                        messageBox(Modal.Warning, qsTr("File format was detected, but no motion data was found.\nThe camera probably doesn't record motion data in this particular shooting mode."), [ { "text": qsTr("Ok") } ]);
                    }
                    if (additional_data.unsupported_lens) {
                        messageBox(Modal.Warning, qsTr("This video cannot be stabilized, because this lens doesn't support OSS metadata.\nDisable lens stabilization (Optical SteadyShot) in order to use Gyroflow."), [ { "text": qsTr("Ok") } ]);
                    }
                    if (additional_data.contains_raw_gyro && !additional_data.contains_quats) timeline.setDisplayMode(0); // Switch to gyro view
                    if (!additional_data.contains_raw_gyro && additional_data.contains_quats) timeline.setDisplayMode(3); // Switch to quaternions view
                }

                if (additional_data.hasOwnProperty("cam_posture") && additional_data.camera_type == "Insta360 GO 3S") {
                    vidInfo.updateEntryWithTrigger("Rotation", 360 - (+additional_data.cam_posture.replace("CameraRotate", "") + 90));
                } else if (additional_data.hasOwnProperty("cam_posture") && Math.abs(+additional_data.cam_posture.replace("CameraRotate", "")) > 0) {
                    vidInfo.updateEntryWithTrigger("Rotation", +additional_data.cam_posture.replace("CameraRotate", ""));
                }
                if (additional_data.hasOwnProperty("realtime_fps") && +additional_data.realtime_fps > 0) {
                    vidInfo.updateEntryWithTrigger("Frame rate", +additional_data.realtime_fps);
                }
                if (additional_data.hasOwnProperty("recording_settings") && Object.keys(additional_data.recording_settings).length > 0) {
                    vidInfo.cleanupModel();
                    let model = vidInfo.infoList.model;
                    model[""] = " ";
                    for (const x in additional_data.recording_settings) {
                        model[x] = additional_data.recording_settings[x];
                    }
                    vidInfo.infoList.model = model;
                    vidInfo.infoList.modelChanged();
                }
            }
            if (+additional_data.sample_rate > 0.0 && Math.round(+additional_data.sample_rate) < 50) {
                messageBox(Modal.Warning, qsTr("Motion data sampling rate is too low (%1 Hz).\n50 Hz is an absolute minimum and we recommend at least 200 Hz.").arg(additional_data.sample_rate.toFixed(0)), [ { "text": qsTr("Ok") } ]);
            }
            if (root.pendingGyroflowData) {
                Qt.callLater(loadGyroflowData, root.pendingGyroflowData, root.pendingQueueJobId);
            } else {
                Qt.callLater(controller.recompute_threaded);
                if (is_main_video) {
                    controller.load_default_preset();
                }
            }
            if (is_main_video && window.pendingLoadPreset) {
                Qt.callLater(loadGyroflowData, JSON.parse(window.pendingLoadPreset), 0);
                window.pendingLoadPreset = "";
            }
        }
        function onChart_data_changed(): void {
            timeline.triggerUpdateChart("");
        }
        function onZooming_data_changed(): void {
            timeline.triggerUpdateChart("8");
        }
        function updateKeyframesView(): void {
            controller.update_keyframes_view(timeline.getKeyframesView());
            controller.update_keyframe_values(controller.video_timestamp);
        }
        function onKeyframes_changed(): void {
            Qt.callLater(updateKeyframesView);
        }
        function onCompute_progress(id: real, progress: real): void {
            videoLoader.active = progress < 1;
            videoLoader.cancelable = false;
        }
        function onSync_progress(progress: real, ready: int, total: int): void {
            videoLoader.active = progress < 1;
            videoLoader.currentFrame = ready;
            videoLoader.totalFrames = total;
            videoLoader.additional = "";
            videoLoader.text = videoLoader.active? qsTr("Analyzing %1...") : "";
            videoLoader.progress = videoLoader.active? progress : -1;
            videoLoader.cancelable = true;
        }
        function onLoading_gyro_progress(progress: real): void {
            videoLoader.active = progress < 1;
            videoLoader.currentFrame = 0;
            videoLoader.totalFrames = 0;
            videoLoader.additional = "";
            videoLoader.text = videoLoader.active? qsTr("Loading gyro data %1...") : "";
            videoLoader.progress = videoLoader.active? progress : -1;
            videoLoader.cancelable = true;
        }
    }
    property Modal externalSdkModal: null;

    // Video-source event handling. Declared at root level (not inside vidParent's subtree)
    // because callers like stabEnabledBtn/fovOverviewBtn live in a sibling branch of the tree
    // (the toolbar, not the video preview area) — bare calls only resolve via the ancestor
    // scope chain, so these need to be reachable from anywhere in the file.
    function fovChanged(): void {
        const fov = controller.current_fov;
        const focal_length = controller.current_focal_length;
        const crop_factor = window.lensProfile?.cropFactor || 1.0;
        // const ratio = controller.get_scaling_ratio(); // this shouldn't be called every frame because it locks the params mutex
        currentFovText.text = qsTr("Zoom: %1").arg(fov > 0? (100 / fov).toFixed(2) + "%" : "---");

        if (+focal_length > 0) {
            const fl = +focal_length / fov;
            currentFovText.text += "\n" + qsTr("Focal length: %1 mm").arg(fl.toFixed(2));
            if (crop_factor && crop_factor != 1.0) {
                currentFovText.text += " (" + qsTr("full frame equiv.: %1 mm").arg((fl * crop_factor).toFixed(2)) + ")";
            }
        }
    }

    function updateTurnSpeed(): void {
        const turnSpeed = controller.get_turn_speed(controller.video_timestamp);
        if (isNaN(turnSpeed)) {
            turnSpeedValue.text = "---";
        } else {
            const xAngle = controller.get_x_angle(controller.video_timestamp);
            turnSpeedValue.text = turnSpeed.toFixed(2) + "°/s (" + xAngle.toFixed(2) + "°)";
        }
    }

    function fileLoaded(md: var): void {
        videoLoader.active = false;
        vidInfo.loader = false;
        timeline.resetTrim();
        timeline.resetZoom();

        controller.video_file_loaded();
        window.motionData.filename = "";

        if (root.pendingGyroflowData) {
            Qt.callLater(root.loadGyroflowData, root.pendingGyroflowData, root.pendingQueueJobId);
        } else {
            controller.load_telemetry(root.loadedFileUrl, true, -1, 0);
        }
        vidInfo.loadFromVideoMetadata(md, controller.video_width, controller.video_height);
        window.sync.customSyncTimestamps = [];

        if (root.mergedFiles.length > 1) {
            if (controller.video_loaded) {
                const copy = [...root.mergedFiles];
                messageBox(Modal.Question, qsTr("Files merged successfully, do you want to delete the original ones?"), [
                    { text: qsTr("Yes"), clicked: function() {
                        for (const x of copy) {
                            filesystem.move_to_trash(x);
                        }
                        return true;
                    } },
                    { text: qsTr("No"), accent: true },
                ], null, undefined, "delete-after-join");
            }
            root.mergedFiles = [];
        }

        window.lensProfile.selected_manually = false;

        // for (var i in md) console.info(i, md[i]);
    }
    property bool errorShown: false;
    Timer {
        id: bufferTrigger;
        interval: 150;
        onTriggered: {
            if (!controller.video_width) bufferTrigger.start();
            Qt.callLater(() => {
                controller.video_current_frame++;
                Qt.callLater(() => controller.video_current_frame = 0);
                if (controller.video_width) {
                    stabEnabledBtn.checked = true;
                    controller.set_video_volume(volumeSlider.value / 100.0);
                }
            });
        }
    }
    Connections {
        target: controller;
        function onVideo_current_frame_changed(): void {
            fovChanged();
            controller.update_keyframe_values(controller.video_timestamp);
            window.motionData.orientationIndicator.updateOrientation(timeline.position * timeline.durationMs * 1000);
            updateTurnSpeed();
        }
        function onVideo_metadata_loaded(md: var): void {
            Qt.callLater(fileLoaded, md);
        }
        function onVideo_metadata_changed(): void {
            if (controller.video_width > 0) {
                // Trigger seek to buffer the video frames
                if (controller.video_duration == 0) {
                    controller.play_video();
                    Qt.callLater(function() {
                        stabEnabledBtn.checked = true;
                        controller.set_video_volume(volumeSlider.value / 100.0);
                    })
                } else {
                    bufferTrigger.start();
                }
            } else if (!errorShown) {
                messageBox(Modal.Error, qsTr("Failed to load the selected file, it may be unsupported or invalid."), [ { "text": qsTr("Ok") } ]);
                errorShown = true;
                dropText.loadingFile = "";
                root.pendingGyroflowData = null;
                stabEnabledBtn.checked = true;
            }
        }
    }

    function loadFile(url: url, skip_detection: bool, queueJobId: int): void {
        let filename = filesystem.get_filename(url);
        let folder = filesystem.get_folder(url);

        if (filename.endsWith(".gyroflow")) {
            return loadGyroflowData(url, queueJobId);
        }
        if (filename.endsWith(".RDC")) {
            // Assumes regular filesystem
            let parts = url.toString().split("/");
            parts.push(filename.replace(".RDC", "_001.R3D"));
            url = parts.join("/");
            filename = filesystem.get_filename(url);
            folder = filesystem.get_folder(url);
        }

        if (isMobile || filename.toLowerCase().endsWith(".r3d") || filename.toLowerCase().endsWith(".nev") || filename.toLowerCase().endsWith(".braw")) {
            // Preview resolution to 1080p
            if (isCalibrator && calibrator_window.lensCalib) {
                if (calibrator_window.lensCalib.previewResolution == 0) {
                    calibrator_window.lensCalib.previewResolution = 2;
                }
            } else {
                if (settings.value("previewResolution", -1) == -1 && window.advanced.previewResolution == 0) {
                    window.advanced.previewResolution = 2;
                }
            }
        }

        stabEnabledBtn.checked = false;

        if (controller.check_external_sdk(filename)) {
            const dlg = messageBox(Modal.Info, qsTr("This format requires an external SDK. Do you want to download it now?"), [
                { text: qsTr("Yes"), accent: true, clicked: function() {
                    dlg.btnsRow.children[0].enabled = false;
                    controller.install_external_sdk(url.toString());
                    return false;
                } },
                { text: qsTr("Cancel"), clicked: function() {
                    externalSdkModal = null;
                } },
            ]);
            externalSdkModal = dlg;
            dlg.addLoader();
            return;
        }

        window.motionData.lastSelectedFile = "";
        if (!(/\.(png|jpg|exr|dng)$/i.test(filename) && filename.includes("%0"))) {
            root.loadedFileUrl = url;
        }

        if (isStorePackage && Qt.platform.os == "osx" && filename.toLowerCase().endsWith(".r3d") && folder.toString().length < 3) {
            messageBox(Modal.Info, qsTr("In order to load all R3D parts, you need to select the entire .RDC folder."), [
                { text: qsTr("OK"), accent: true, clicked: function() {
                    opf.selectFolder("", function(_) {
                        root.loadFile(root.loadedFileUrl);
                    });
                } },
            ], null, undefined, "open-rdc-folder");
            return;
        }

        if (!skip_detection) {
            let newUrl;
            if (newUrl = detectImageSequence(folder, filename)) {
                const dlg = messageBox(Modal.Info, qsTr("Image sequence has been detected.\nPlease provide frame rate: "), [
                    { text: qsTr("Ok"), accent: true, clicked: function() {
                        const fps = dlg.mainColumn.children[1].value;
                        settings.setValue("imageSequenceFps", fps);
                        controller.image_sequence_fps = fps;
                        loadFile(newUrl, true);
                        controller.set_video_frame_rate(fps);
                    } },
                    { text: qsTr("Cancel") },
                ]);
                const nf = Qt.createComponent("components/NumberField.qml").createObject(dlg.mainColumn, { precision: 3, unit: "fps", value: +settings.value("imageSequenceFps", "30") });
                nf.anchors.horizontalCenter = dlg.mainColumn.horizontalCenter;
                return;
            }
            let sequenceList;
            if (sequenceList = detectVideoSequence(folder, filename)) {
                const list = "<b>" + sequenceList.join(", ") + "</b>";
                const dlg = messageBox(Modal.Info, qsTr("Split recording has been detected, do you want to automatically join the files (%1) to create one full clip?").arg(list), [
                    { text: qsTr("Yes"), accent: true, clicked: function() {
                        dlg.btnsRow.children[0].enabled = false;
                        getOutputFile(folder, sequenceList[0], "_joined", "", true, function(outFolder, outFilename, outFullFileUrl) {
                            root.mergedFiles = sequenceList.map(x => filesystem.get_file_url(folder, x, false).toString());
                            controller.mp4_merge(sequenceList.map(x => filesystem.get_file_url(folder, x, false).toString()), outFolder, outFilename);
                        });
                        return false;
                    } },
                    { text: qsTr("No"), clicked: function() {
                        externalSdkModal = null;
                        loadFile(url, true);
                    } },
                ])
                externalSdkModal = dlg;
                dlg.addLoader();
                return;
            }
        }
        vidInfo.hasAccessToInputDirectory = folder.toString().length > 3;

        window.stab.fovSlider.value = 1.0;
        // controller.load_video() below resets video_loaded itself, matching the eager reset
        // this file used to do on `vid` directly, before video_loaded became a Controller-owned,
        // Rust-driven property.
        videoLoader.active = true;
        vidInfo.loader = true;
        errorShown = false;
        render_queue.editing_job_id = 0;
        controller.load_video(url);
        if (!isCalibrator) {
            const suffix = window.advanced.defaultSuffix.text;
            window.outputFile.setFilename(filesystem.filename_with_suffix(filename, suffix).replace(/%0[0-9]+d/, ""));

            const preservedPath = settings.value("preservedOutputPath", "");
            if (window.exportSettings.preserveOutputPath.checked && preservedPath) {
                window.outputFile.setFolder(preservedPath);
            } else {
                window.outputFile.setFolder(folder);
            }
            window.exportSettings.updateCodecParams();
        }
        if (!root.pendingGyroflowData) {
            const gfFilename = filesystem.filename_with_extension(filename, "gyroflow");
            if (filesystem.exists_in_folder(folder, gfFilename)) {
                messageBox(Modal.Question, qsTr("There's a %1 file associated with this video, do you want to load it?").arg("<b>" + gfFilename + "</b>"), [
                    { text: qsTr("Yes"), clicked: function() {
                        Qt.callLater(() => loadFile(filesystem.get_file_url(folder, gfFilename, false), true));
                    } },
                    { text: qsTr("No"), accent: true },
                ]);
            }
        }

        dropText.loadingFile = filename;
        vidInfo.cleanupModel();
        vidInfo.updateEntry("File name", filename);
        vidInfo.updateEntry("Detected camera", "---");
        vidInfo.updateEntry("Detected lens", "---");
        vidInfo.updateEntry("Contains gyro", "---");
        timeline.editingSyncPoint = false;
    }
    function loadMultipleFiles(urls: list<url>, skip_detection: bool): void {
        if (urls.length == 1) {
            root.loadFile(urls[0], skip_detection);
        } else if (urls.length > 1) {
            const urlsCopy = [...urls];
            if (urlsCopy[0].toString().toLowerCase().endsWith(".r3d")) {
                return root.loadFile(urlsCopy[0], true);
            }
            const dlg = messageBox(Modal.Question, qsTr("You have opened multiple files. What do you want to do?"), [
                { text: qsTr("Add to render queue"), clicked: () => {
                    queue.item.dt.loadFiles(urlsCopy);
                    queue.item.shown = true;
                } },
                { text: qsTr("Merge them into one video"), clicked: () => {
                    dlg.btnsRow.children[0].enabled = false;
                    dlg.btnsRow.children[1].enabled = false;
                    dlg.btnsRow.children[2].enabled = false;
                    const filename = filesystem.get_filename(urlsCopy[0]);
                    const folder = filesystem.get_folder(urlsCopy[0]);
                    getOutputFile(folder, filename, "_joined", "", true, function(outFolder, outFilename, outFullFileUrl) {
                        root.mergedFiles = urlsCopy.map(x => x.toString());
                        controller.mp4_merge(urlsCopy.map(x => x.toString()), outFolder, outFilename);
                    });
                    return false;
                } },
                { text: qsTr("Open the first file"), clicked: () => {
                    root.loadFile(urlsCopy[0], skip_detection);
                } },
                { text: qsTr("Cancel") },
            ]);
            externalSdkModal = dlg;
            dlg.addLoader();
        }
    }

    function askForOutputLocation(folder: url, filename: string, choice: bool, cb: var): void {
        const dlg = messageBox(Modal.Question, qsTr("Please enter the output path:"), [
            { text: qsTr("Ok"), accent: true, clicked: function() {
                if (choice) {
                    if (dlg.mainColumn.children[1].children[0].checked) { cb("", ""); }
                    if (dlg.mainColumn.children[1].children[1].checked) { const opf = dlg.mainColumn.children[1].children[3]; cb(opf.folderUrl, opf.filename, opf.fullFileUrl); }
                } else {
                    const opf = dlg.mainColumn.children[1];
                    if (!opf.folderUrl.toString() && !opf.fullFileUrl.toString()) {
                        opf.prompt();
                        return false;
                    }
                    cb(opf.folderUrl, opf.filename, opf.fullFileUrl);
                }
            } },
            { text: qsTr("Cancel") },
        ]);

        if (choice) {
            let col = Qt.createQmlObject(`import QtQuick; import "components/";
                Column {
                    width: parent.width;
                    RadioButton { checked: true; }
                    RadioButton { id: custom; }
                    Item { height: 10 * dpiScale; width: 1; }
                    OutputPathField { enabled: custom.checked; folderOnly: true; }
                }`, dlg.mainColumn, "dlgRadios");
            col.children[0].text = qsTr("Same as the original file");
            col.children[1].text = qsTr("Custom path");
            col.children[3].setFolder(folder);
        } else {
            const opf = Qt.createComponent("components/OutputPathField.qml").createObject(dlg.mainColumn, { });
            opf.setFolder(folder);
            opf.setFilename(filename);
        }
    }
    function getOutputFile(folder: url, filename: string, suffix: string, extension: string, ask: bool, cb: var): void {
        if (suffix) filename = filesystem.filename_with_suffix(filename, suffix);
        if (extension) filename = filesystem.filename_with_extension(filename, extension);
        if (ask) {
            askForOutputLocation(folder, filename, false, cb);
        } else {
            cb(folder, filename);
        }
    }

    function detectImageSequence(folder: url, filename: string): var {
        if (!filename.includes("%0")) {
            controller.image_sequence_start = 0;
            controller.image_sequence_fps = 0;
        }
        if (/\d+\.(png|jpg|exr|dng)$/i.test(filename)) {
            let firstNum = filename.match(/(\d+)\.(png|jpg|exr|dng)$/i);
            if (firstNum[1]) {
                const ext = firstNum[2];
                firstNum = firstNum[1];
                const firstNumNum = parseInt(firstNum, 10);
                for (let i = firstNumNum + 1; i < firstNumNum + 5; ++i) { // At least 5 frames
                    const newNum = i.toString().padStart(firstNum.length, '0');
                    const newName = filename.replace(firstNum + "." + ext, newNum + "." + ext);
                    if (!filesystem.exists_in_folder(folder, newName)) {
                        return false;
                    }
                }
                controller.image_sequence_start = firstNumNum;
                return filesystem.get_file_url(folder, filename.replace(`${firstNum}.${ext}`, `%0${firstNum.length}d.${ext}`), false);
            }
        }
        return false;
    }
    function detectVideoSequence(folder: url, filename: string): var {
        // url pattern, 1st file index, new path function
        const patterns = [
            // GoPro 1-5
            [/((?:GOPR|GP\d{2})(\d{4})\.MP4)$/i, 0, function(match, i) {
                return (i == 0 ? "GOPR" : "GP" + i.toString().padStart(2, '0')) + match.substring(4);
            }],
            // GoPro 6+
            [/(G[XH]\d{2}(\d{4})\.MP4)$/i, 1, function(match, i) {
                return match.substring(0, 2) + i.toString().padStart(2, '0') + match.substring(4);
            }],
            // DJI Action
            [/(DJI_\d+_(\d+)\.MP4)$/i, null, function(match, i) {
                return match.substring(0, 9) + i.toString().padStart(3, '0') + match.substring(12);
            }],
        ];
        for (const x of patterns) {
            let match = filename.match(x[0]);
            if (match && match[1]) {
                let list = [];
                const firstNum = (x[1] !== null ? x[1] : parseInt(match[2], 10));
                for (let i = firstNum; i < firstNum + 99; ++i) { // Max 99 parts
                    const newName = filename.replace(match[1], x[2](match[1], i));
                    if (filesystem.exists_in_folder(folder, newName)) {
                        list.push(newName);
                    } else {
                        break;
                    }
                }
                if (list.length > 1)
                    return list;
            }
        }
        return false;
    }
    OutputPathField { id: opf; visible: false; }

    Item {
        id: vidParentParent;
        width: parent.width;
        height: parent.height - (root.fullScreen || window.isMobileLayout? 0 : tlcol.height);

        Grid {
            readonly property bool vertical: vidParentParent.height - vidParent.height * 2 > vidParentParent.width - vidParent.width * 2;
            columns: secondPreview.visible? (vertical? 1 : 2) : 1;
            rows:    secondPreview.visible? (vertical? 2 : 1) : 1;
            anchors.centerIn: parent;
            spacing: 10 * dpiScale;
            Item {
                id: vidParent;
                readonly property real orgW: (stabEnabledBtn.checked && root.outWidth > 0? root.outWidth : (controller.video_width * window.lensProfile.input_horizontal_stretch));
                readonly property real orgH: (stabEnabledBtn.checked && root.outHeight > 0? root.outHeight : (controller.video_height * window.lensProfile.input_vertical_stretch));
                readonly property real ratio: orgW / Math.max(1, orgH);
                readonly property real w: vidParentParent.width  / parent.columns - (root.fullScreen? 0 : 20 * dpiScale);
                readonly property real h: vidParentParent.height / parent.rows    - (root.fullScreen? 0 : 20 * dpiScale);

                width:  (ratio * h) > w ? w : (ratio * h)
                height: (ratio * h) > w ? (w / ratio) : h
                opacity: da.containsDrag? 0.5 : 1.0;

                /*Image {
                    // Transparency grid
                    fillMode: Image.Tile;
                    anchors.fill: parent;
                    source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='14' height='14'><rect fill='%23fff' x='0' y='0' width='7' height='7'/><rect fill='%23aaa' x='7' y='0' width='7' height='7'/><rect fill='%23aaa' x='0' y='7' width='7' height='7'/><rect fill='%23fff' x='7' y='7' width='7' height='7'/></svg>"
                }*/

                // Headless decoder / texture source — never displayed directly, never declared
                // in QML. controller.init_video_source() creates and owns the actual MDKVideoItem
                // entirely from Rust (mirrors controller.init_viewport() below); this container
                // only exists to give it somewhere in the window's item tree to be parented into.
                // gyroflowViewportContainer (below) is the only thing ever shown; everywhere else
                // in this file, state/control goes through controller.video_* instead of a `vid`
                // reference, since QML no longer has (or needs) one.
                Item {
                    id: mdkSourceContainer;
                    anchors.fill: parent;
                    Component.onCompleted: {
                        controller.init_video_source(this, 0);
                        controller.set_background_color("#111111");
                    }
                }

                // Second headless decoder, for a dual-lens profile's secondary video file (lens
                // 1) — same MDKVideoItem machinery as mdkSourceContainer above, just a separate
                // instance so both lenses decode independently and symmetrically. Only ever
                // loaded with a file once a dual-lens profile is active (see
                // Controller::load_secondary_video); otherwise it just sits idle.
                Item {
                    id: mdkSourceContainer2;
                    anchors.fill: parent;
                    Component.onCompleted: {
                        controller.init_video_source(this, 1);
                    }
                }

                // NOTE: the raw/unstabilized preview (stabEnabledBtn unchecked) that used to be
                // produced by transforming vid directly is not currently reproduced — the shader
                // pipeline has no pass-through mode yet. See Big Picture notes: this needs to
                // become part of the stabilization pass itself, not a QML-side transform on a
                // raw decoder texture that no longer exists.

                Rectangle {
                    border.color: styleVideoBorderColor;
                    border.width: 1 * dpiScale;
                    color: "transparent";
                    radius: 5 * dpiScale;
                    anchors.fill: parent;
                    anchors.margins: -border.width;
                }

                TapHandler {
                    onTapped: timeline.focus = true;
                    onDoubleTapped: root.fullScreen = root.fullScreen? 0 : 1;
                }
                // 360° viewport drag — only active when a dual-lens / 360° profile is loaded
                DragHandler {
                    id: viewportDragHandler;
                    target: null; // prevents the handler from physically moving vidParent
                    enabled: root.is360Camera && controller.video_loaded;
                    cursorShape: active ? Qt.ClosedHandCursor : Qt.OpenHandCursor;

                    property real prevX: 0;
                    property real prevY: 0;

                    onActiveChanged: {
                        if (active) {
                            prevX = centroid.position.x;
                            prevY = centroid.position.y;
                        } else {
                            // Drag ended — commit the FOV/smoothing recompute that rotateViewport360's
                            // per-pixel set_keyframe_live calls deferred throughout the drag.
                            controller.commit_keyframe_recompute();
                        }
                    }
                    onCentroidChanged: {
                        if (active) {
                            const dx = centroid.position.x - prevX;
                            const dy = centroid.position.y - prevY;
                            prevX = centroid.position.x;
                            prevY = centroid.position.y;
                            if (Math.abs(dx) > 0.01 || Math.abs(dy) > 0.01) {
                                root.rotateViewport360(dx, dy);
                            }
                        }
                    }
                }
                // Viewport display: the shader writes here. GridGuide is declared after this
                // so it composites on top as an overlay.
                Item {
                    id: gyroflowViewportContainer;
                    anchors.fill: parent;
                    Component.onCompleted: {
                        controller.init_viewport(this);
                        controller.set_viewport_display_size(width, height);
                    }
                    onWidthChanged:  controller.set_viewport_display_size(width, height);
                    onHeightChanged: controller.set_viewport_display_size(width, height);
                }

                GridGuide {
                    id: gridGuide;
                    anchors.fill: parent;
                    canShow: controller.video_loaded;
                }
            }
            Item {
                id: secondPreview;
                property bool show: false;
                onShowChanged: settings.setValue("stabOverviewSplit", show);
                Component.onCompleted: show = settings.value("stabOverviewSplit", false);
                visible: show && fovOverviewBtn.checked;
                readonly property real ratio: 1 + 1 / window.stab.fovSlider.value;
                onRatioChanged: {
                    if (visible) {
                        controller.force_video_redraw();
                        vidParent.widthChanged();
                    }
                }
                width: vidParent.width;
                height: vidParent.height;
                ShaderEffectSource {
                    id: secondPreviewSource;
                    live: secondPreview.visible;
                    width: parent.width; height: parent.height;
                    sourceItem: vidParent;
                    sourceRect: Qt.rect((vidParent.width - (vidParent.width / secondPreview.ratio)) / 2, (vidParent.height - (vidParent.height / secondPreview.ratio)) / 2, vidParent.width / secondPreview.ratio, vidParent.height / secondPreview.ratio);
                }
                TapHandler {
                    onTapped: timeline.focus = true;
                    onDoubleTapped: root.fullScreen = root.fullScreen? 0 : 1;
                }
            }
        }

        Rectangle {
            id: dropRect;
            border.width: controller.video_loaded? 0 : (3 * dpiScale);
            border.color: style === "light"? Qt.darker(styleBackground, 1.3) : Qt.lighter(styleBackground, 2);
            anchors.fill: parent;
            anchors.margins: controller.video_loaded? 0 : (20 * dpiScale);
            anchors.topMargin: controller.video_loaded? 0 : (50 * dpiScale);
            anchors.bottomMargin: controller.video_loaded? 0 : (50 * dpiScale);
            color: styleBackground;
            radius: 5 * dpiScale;
            opacity: da.containsDrag? (controller.video_loaded? 0.8 : 0.3) : controller.video_loaded? 0 : 1.0;
            Ease on opacity { duration: 300; }
            visible: opacity > 0;
            onVisibleChanged: if (!visible) dropText.loadingFile = "";

            BasicText {
                id: dropText;
                property string loadingFile: "";
                text: loadingFile? qsTr("Loading %1...").arg(loadingFile) : (Qt.platform.os == "ios" || Qt.platform.os == "android"? qsTr("Click here to open a video file") : qsTr("Drop video file here"));
                font.pixelSize: (window.isMobileLayout? 23 : 30) * dpiScale;
                anchors.centerIn: parent;
                leftPadding: 0;
                scale: dropText.contentWidth > (parent.width - 50 * dpiScale)? (parent.width - 50 * dpiScale) / dropText.contentWidth : 1.0;
            }
            ItemLoader {
                anchors.fill: dropText;
                anchors.margins: -30 * dpiScale;
                visible: !dropText.loadingFile && !controller.video_loaded;
                scale: dropText.scale;
                sourceComponent: Component { DropTargetRect { } }
            }
            ItemLoader {
                anchors.fill: parent;
                anchors.margins: 5 * dpiScale;
                visible: !dropText.loadingFile && controller.video_loaded;
                sourceComponent: Component { DropTargetRect { } }
            }
            MouseArea {
                visible: !controller.video_loaded;
                anchors.fill: parent;
                cursorShape: Qt.PointingHandCursor;
                onClicked: vidInfo.selectFileRequest();
            }
        }
        DropArea {
            id: da;
            anchors.fill: dropRect;
            enabled: queue.item && !queue.item.shown && !queue.item.isDragging;

            onEntered: (drag) => {
                if (!drag.urls.length) return;
                const ext = drag.urls[0].toString().split(".").pop().toLowerCase();
                drag.accepted = fileDialog.extensions.indexOf(ext) > -1 || ext == "rdc";
            }
            onDropped: (drop) => {
                if (isCalibrator) {
                    calibrator_window.loadFiles(drop.urls);
                } else {
                    root.loadMultipleFiles(drop.urls, false);
                }
            }
        }
    }

    Column {
        id: tlcol;
        width: parent.width;
        anchors.horizontalCenter: parent.horizontalCenter;
        anchors.bottom: parent.bottom;
        anchors.bottomMargin: areButtonsUp? 0 : 5 * dpiScale;
        spacing: root.fullScreen || window.isMobileLayout? 0 : 10 * dpiScale;
        property bool areButtonsUp: !window.isMobileLayout;
        onAreButtonsUpChanged: {
            buttonsArea.parent = null;
            bottomPanel.parent = null;
            if (areButtonsUp) {
                buttonsArea.parent = tlcol;
                bottomPanel.parent = tlcol;
            } else {
                bottomPanel.parent = tlcol;
                buttonsArea.parent = tlcol;
            }
        }
        Component.onCompleted: areButtonsUpChanged();

        Item {
            id: buttonsArea;
            width: parent? parent.width : 0;
            height: 40 * dpiScale;
            visible: !root.fullScreen;

            Rectangle {
                visible: window.isMobileLayout || !middleButtons.willFit;
                color: styleBackground;
                opacity: 0.8;
                radius: 5 * dpiScale;
                anchors.fill: textCol;
                anchors.margins: -4 * dpiScale;
            }
            Column {
                id: textCol;
                enabled: controller.video_loaded;
                y: middleButtons.willFit? ((parent.height - height) / 2) : -buttonsArea.y - tlcol.y + 7 * dpiScale + ((main_window.safeAreaMargins.top || 0) * 0.8);
                anchors.left: parent.left;
                anchors.leftMargin: 10 * dpiScale;
                spacing: 3 * dpiScale;
                property real widthPadded: Math.ceil(width / (20 * dpiScale)) * (20 * dpiScale);
                Row {
                    BasicText {
                        text: timeline.timeAtPosition((controller.video_current_frame + 1) / Math.max(1, controller.video_frame_count));
                        leftPadding: 0;
                        font.pixelSize: 14 * dpiScale;
                        anchors.verticalCenter: parent.verticalCenter;
                    }
                    BasicText {
                        text: `(${controller.video_current_frame+1}/${controller.video_frame_count})`;
                        leftPadding: 5 * dpiScale;
                        font.pixelSize: 11 * dpiScale;
                        anchors.verticalCenter: parent.verticalCenter;
                    }
                }
                Row {
                    visible: window.stab.automaticHorizonLock;
                    BasicText {
                        text: qsTr("Turn Speed (Roll):");
                        leftPadding: 0;
                        font.pixelSize: 11 * dpiScale;
                        anchors.verticalCenter: parent.verticalCenter;
                    }
                    BasicText {
                        id: turnSpeedValue;
                        text: "---";
                        leftPadding: 5 * dpiScale;
                        font.pixelSize: 11 * dpiScale;
                        anchors.verticalCenter: parent.verticalCenter;
                    }
                }
                BasicText {
                    id: currentFovText;
                    font.pixelSize: 11 * dpiScale;
                    leftPadding: 0;
                }
            }

            Item {
                id: middleButtons;
                property real availableWidth: parent.width - textCol.widthPadded - rightButtons.width - 40 * dpiScale;
                width: parent.width - (willFit? textCol.widthPadded + rightButtons.width + 40 * dpiScale : 0);
                height: parent.height;
                x: willFit? textCol.x + textCol.widthPadded + 10 * dpiScale : 0;
                property bool willFit: availableWidth > children[0].width;
                Row {
                    anchors.centerIn: parent;
                    spacing: 5 * dpiScale;
                    enabled: controller.video_loaded;
                    Button { text: "["; font.bold: true; onClicked: timeline.setTrimStart(timeline.closestTrimRange(timeline.position, true), timeline.position); tooltip: qsTr("Trim start"); transparentOnMobile: true; }
                    Button {
                        iconName: "chevron-left";
                        tooltip: qsTr("Previous frame");
                        transparentOnMobile: true;
                        MouseArea {
                            anchors.fill: parent;
                            onClicked: mouse => {
                                if (mouse.modifiers & Qt.ShiftModifier) {
                                    timeline.jumpToPrevKeyframe("");
                                } else if (mouse.modifiers & Qt.ControlModifier) {
                                    controller.seek_to_frame_delta(-10);
                                } else {
                                    controller.seek_to_frame_delta(-1);
                                }
                            }
                        }
                    }
                    Button {
                        onClicked: { if (controller.video_playing) controller.pause_video(); else controller.play_video(); }
                        tooltip: controller.video_playing? qsTr("Pause") : qsTr("Play");
                        iconName: controller.video_playing? "pause" : "play";
                        transparentOnMobile: true;
                    }
                    Button {
                        iconName: "chevron-right";
                        tooltip: qsTr("Next frame");
                        transparentOnMobile: true;
                        MouseArea {
                            anchors.fill: parent;
                            onClicked: mouse => {
                                if (mouse.modifiers & Qt.ShiftModifier) {
                                    timeline.jumpToNextKeyframe("");
                                } else if (mouse.modifiers & Qt.ControlModifier) {
                                    controller.seek_to_frame_delta(10);
                                } else {
                                    controller.seek_to_frame_delta(1);
                                }
                            }
                        }
                    }
                    Button { text: "]"; font.bold: true; onClicked: timeline.setTrimEnd(timeline.closestTrimRange(timeline.position, false), timeline.position); tooltip: qsTr("Trim end"); transparentOnMobile: true; }
                    Button { visible: isMobile; iconName: "menu"; onClicked: timeline.toggleContextMenu(this); tooltip: qsTr("Show timeline menu"); transparentOnMobile: true; leftPadding: 10 * dpiScale; rightPadding: 10 * dpiScale; }
                }
            }
            Rectangle {
                visible: window.isMobileLayout || !middleButtons.willFit;
                color: styleBackground;
                opacity: 0.8;
                radius: 5 * dpiScale;
                anchors.fill: rightButtons;
                anchors.margins: -4 * dpiScale;
            }
            Row {
                id: rightButtons;
                enabled: controller.video_loaded;
                spacing: 5 * dpiScale;
                y: middleButtons.willFit? ((parent.height - height) / 2) : -buttonsArea.y - tlcol.y + ((main_window.safeAreaMargins.top || 0) * 0.8);
                onYChanged: root.additionalTopMargin = middleButtons.willFit? 0 : Math.max(height, textCol.height) + 2*4 * dpiScale + ((main_window.safeAreaMargins.top || 0) * 0.8);
                anchors.right: parent.right;
                anchors.rightMargin: 10 * dpiScale;
                height: parent.height;

                component SmallLinkButton: LinkButton {
                    height: Math.round(parent.height);
                    anchors.verticalCenter: parent.verticalCenter;
                    textColor: !checked? styleTextColor : styleAccentColor;
                    onClicked: checked = !checked;
                    opacity: checked? 1 : 0.5;
                    checked: true;
                    leftPadding: 6 * dpiScale;
                    rightPadding: 6 * dpiScale;
                    topPadding: 8 * dpiScale;
                    bottomPadding: 8 * dpiScale;
                }

                SmallLinkButton {
                    id: fovOverviewBtn;
                    iconName: "fov-overview";
                    checked: false;
                    onCheckedChanged: { controller.fov_overview = checked; controller.force_video_redraw(); }
                    tooltip: qsTr("Toggle stabilization overview");
                    TapHandler {
                        acceptedModifiers: Qt.ControlModifier
                        onTapped: { if (fovOverviewBtn.checked) { secondPreview.show = !secondPreview.show; fovOverviewBtn.checked = false; controller.force_video_redraw(); } }
                    }
                }

                SmallLinkButton {
                    id: stabEnabledBtn;
                    iconName: "gyroflow";
                    onCheckedChanged: { controller.stab_enabled = checked; controller.force_video_redraw(); fovChanged(); }
                    tooltip: qsTr("Toggle stabilization");
                }

                SmallLinkButton {
                    id: muteBtn;
                    iconName: checked? "sound" : "sound-mute";
                    tooltip: checked? qsTr("Mute") : qsTr("Unmute");
                    checked: !controller.video_muted;

                    ContextMenuMouseArea {
                        underlyingItem: muteBtn;
                        cursorShape: Qt.PointingHandCursor;
                        onContextMenu: (isHold, x, y) => { volumePopup.open(); if (isHold) controller.video_muted = !controller.video_muted; }
                    }
                    onClicked: () => { controller.video_muted = !controller.video_muted; }
                    Popup {
                        id: volumePopup;
                        width: volumeLabel.width + 25 * dpiScale;
                        height: 30 * dpiScale;
                        x: -width + muteBtn.width;
                        y: -height;
                        Label {
                            id: volumeLabel;
                            anchors.centerIn: parent;
                            text: qsTr("Volume");
                            position: Label.LeftPosition;
                            width: t.width + volumeSlider.width;
                            Slider {
                                id: volumeSlider;
                                width: 200 * dpiScale;
                                unit: "%";
                                from: 0;
                                to: 100;
                                value: settings.value("volume", 100);
                                precision: 0;
                                onValueChanged: { controller.set_video_volume(value / 100.0); settings.setValue("volume", value); }
                            }
                        }
                    }
                }

                ComboBox {
                    id: playbackRateCb;
                    model: ["0.13x", "0.25x", "0.5x", "1x", "2x", "4x", "5x", "8x", "10x", "20x", "50x"];
                    width: 60 * dpiScale;
                    currentIndex: 3;
                    height: 25 * dpiScale;
                    itemHeight: 25 * dpiScale;
                    font.pixelSize: 11 * dpiScale;
                    anchors.verticalCenter: parent.verticalCenter;
                    onCurrentTextChanged: {
                        const rate = +currentText.replace("x", ""); // hacky but simple and it works
                        controller.video_playback_rate = rate;
                    }
                    tooltip: qsTr("Playback speed");
                }
            }
        }

        ResizablePanel {
            id: bottomPanel;
            direction: ResizablePanel.HandleUp;
            width: parent? parent.width : 0;
            color: "transparent";
            hr.height: 30 * dpiScale;
            hr.opacity: root.fullScreen || window.isMobileLayout? 0.1 : 1.0;
            additionalHeight: timeline.additionalHeight;
            defaultHeight: (window.isMobileLayout? 50 : 165) * dpiScale;
            minHeight: (root.fullScreen || window.isMobileLayout? 50 : 100) * dpiScale;
            lastHeight: settings.value("bottomPanelSize" + (root.fullScreen? "-full" : ""), defaultHeight);
            onHeightAdjusted: settings.setValue("bottomPanelSize" + (root.fullScreen? "-full" : ""), height);
            Connections {
                target: root;
                function onFullScreenChanged(): void {
                    bottomPanel.lastHeight = settings.value("bottomPanelSize" + (root.fullScreen? "-full" : ""), bottomPanel.defaultHeight);
                    if (root.fullScreen == 2) {
                        main_window.visibility = Window.FullScreen;
                    } else {
                        if (main_window.visibility == Window.FullScreen) main_window.visibility = Window.Windowed;
                    }
                }
            }
            visible: root.fullScreen != 2;
            maxHeight: root.height - 50 * dpiScale;
            Timeline {
                id: timeline;
                durationMs: controller.video_duration;
                scaledFps: controller.video_frame_rate;
                anchors.fill: parent;
                fullScreen: root.fullScreen;
                visible: controller.video_loaded || !window.isMobileLayout;
                property bool prevRestrictTrim: false;
                Component.onCompleted: prevRestrictTrim = restrictTrim;

                onTrimRangesChanged: {
                    controller.set_trim_ranges(timeline.trimRanges.map(x => x[0] + ":" + x[1]).join(";"));
                    restrictTrimChanged();
                }
                onRestrictTrimChanged: {
                    if (restrictTrim) {
                        const ranges = timeline.getTrimRanges();
                        controller.set_video_playback_range(ranges[0][0] * controller.video_duration, ranges[ranges.length - 1][1] * controller.video_duration);
                    } else if (prevRestrictTrim != restrictTrim) {
                        controller.set_video_playback_range(0, -1);
                    }
                    prevRestrictTrim = restrictTrim;
                }
            }
        }
    }
    Item {
        width: vidParentParent.width;
        height: vidParentParent.height;
        LoaderOverlay {
            id: videoLoader;
            background: styleBackground;
            verticalOffset: window.isMobileLayout? -bottomPanel.height / 2 : 0;
            onActiveChanged: { controller.force_video_redraw(); fovChanged(); }
            canHide: render_queue.main_job_id > 0;
            onCancel: {
                if (render_queue.main_job_id > 0) {
                    render_queue.cancel_job(render_queue.main_job_id);
                } else {
                    controller.cancel_current_operation();
                }
            }
            onHide: {
                render_queue.main_job_id = 0;
                videoLoader.active = false;
            }
        }
        Column {
            id: infoMessages;
            width: parent.width;
            spacing: 5 * dpiScale;
            visible: children.length > 0;
            y: root.additionalTopMargin;
            InfoMessage {
                type: InfoMessage.Warning;
                visible: controller.video_loaded && !controller.lens_loaded && !isCalibrator;
                text: qsTr("Lens profile is not loaded, the results will not look correct. Please load a lens profile for your camera.");
            }
        }
    }
    Loader {
        id: queue;
        asynchronous: true;
        anchors.fill: vidParentParent;
        anchors.margins: 10 * dpiScale;
        sourceComponent: Component {
            RenderQueue {
                onShownChanged: if (statistics.item) statistics.item.shown &= !shown;
            }
        }
    }
    Loader {
        id: statistics;
        asynchronous: true;
        active: false;
        anchors.fill: vidParentParent;
        anchors.margins: 10 * dpiScale;
        onStatusChanged: if (status == Loader.Ready) statistics.item.shown = true;
        sourceComponent: Component {
            Statistics {
                onShownChanged: queue.item.shown &= !shown;
            }
        }
    }
}
