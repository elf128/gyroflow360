// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2024 Gyroflow contributors

import QtQuick

import "../components/"

MenuItem {
    text: qsTr("View Settings");
    iconName: "fov-overview";
    objectName: "viewSettings";

    Label {
        position: Label.LeftPosition;
        text: qsTr("Preview aspect ratio");

        ComboBox {
            id: previewAspectRatio;
            model: [QT_TRANSLATE_NOOP("Popup", "Source"), "1:1", "4:3", "16:9", "2.39:1"];
            font.pixelSize: 12 * dpiScale;
            width: parent.width;
            currentIndex: 0;
            Component.onCompleted: {
                if (settings.value("previewAspectRatio", -1) != -1)
                    currentIndex = +settings.value("previewAspectRatio", -1);
            }
            onCurrentIndexChanged: {
                const ratios = [0.0, 1.0, 4.0 / 3.0, 16.0 / 9.0, 2.39];
                controller.set_preview_aspect_ratio(ratios[currentIndex]);
                settings.setValue("previewAspectRatio", currentIndex);
            }
        }
    }
}
