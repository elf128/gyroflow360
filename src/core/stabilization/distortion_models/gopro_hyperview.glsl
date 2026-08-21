// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2022 Adrian <adrian.eddy at gmail>

vec2 hyperview(vec2 uv) {
    float x2 = uv.x * uv.x;
    float y2 = uv.y * uv.y;
    return vec2(
        uv.x * (1.5805143 + x2 * (-8.1668825 + x2 * (74.5198746 + x2 * (-451.5002441 + x2 * (1551.2922363 + x2 * (-2735.5422363 + x2 * 1923.1572266))))) + y2 * -0.1086027),
        uv.y * (1.0238225 + y2 * -0.1025671 + x2 * (-0.2639930 + x2 * 0.2979266))
    );
}

// uv in [-1, 1] centered at zero; hyperview works in [-0.5, 0.5]
vec2 digital_undistort_point(vec2 uv) {
    uv = uv * 0.5;
    uv = hyperview(uv);
    uv.x = uv.x / 1.555555555;
    return uv * 2.0;
}
vec2 digital_distort_point(vec2 uv) {
    vec2 size = vec2(params.width, params.height);
    uv = (uv / size) - 0.5;
    uv.x = uv.x * 1.555555555;

    vec2 P = uv;
    for (int i = 0; i < 12; ++i) {
        vec2 diff = hyperview(P) - uv;
        if (abs(diff.x) < 1e-6 && abs(diff.y) < 1e-6) {
            break;
        }
        P -= diff;
    }

    uv = (P + 0.5) * size;

    return uv;
}
