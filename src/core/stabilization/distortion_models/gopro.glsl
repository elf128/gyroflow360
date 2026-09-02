// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Adrian <adrian.eddy at gmail>
//
// GoPro native radial lens model. Raw POLY radial coeffs r0..r6 in params.k1/k2.
// The Superview/Hyperview MAPX/MAPY warp is a separate digital lens (gopro_warp).

float gopro_poly_eval(float p, vec4 k1, vec4 k2) {
    return k1.x + p * (k1.y + p * (k1.z + p * (k1.w + p * (k2.x + p * (k2.y + p * k2.z)))));
}
float gopro_poly_deriv(float p, vec4 k1, vec4 k2) {
    return k1.y + p * (2.0 * k1.z + p * (3.0 * k1.w + p * (4.0 * k2.x + p * (5.0 * k2.y + p * (6.0 * k2.z)))));
}
float gopro_poly_invert(float theta, vec4 k1, vec4 k2) {
    float p = (theta - k1.x) / k1.y;
    for (int i = 0; i < 10; ++i) {
        float d = gopro_poly_deriv(p, k1, k2);
        if (abs(d) < 1e-12) break;
        float fix = (gopro_poly_eval(p, k1, k2) - theta) / d;
        p -= fix;
        if (abs(fix) < 1e-7) break;
    }
    return p;
}

vec2 undistort_point(vec2 pos) {
    if (params.k1.y == 0.0) return pos;
    float r_norm = length(pos);
    if (r_norm < 1e-9) return pos;
    float p = r_norm / params.k1.y;
    float theta = gopro_poly_eval(p, params.k1, params.k2);
    // Clamp the angle just under tan()'s 90° asymptote and continue the radius linearly past it so over-FOV
    // rays stay large & monotonic (no wrap/fold -> r_limit clips them to background). See gopro.rs.
    const float TMAX = 1.5533; const float tt = 57.14902; // TMAX ≈ 89°, tt = tan(TMAX)
    float rr = theta < TMAX ? tan(theta) : tt + (theta - TMAX) * (1.0 + tt * tt);
    float scale = rr / r_norm;
    return pos * scale;
}

vec2 distort_point(vec3 dir, vec4 k1, vec4 k2, vec4 k3) {
    if (dir.z <= 0.0) return vec2(-99999.0, -99999.0);
    vec2 pos = dir.xy / dir.z;
    if (k1.y == 0.0) return pos;
    float r = length(pos);
    // Inverse of undistort_point's angle clamp (see gopro.rs / gopro.glsl undistort_point).
    const float TMAX = 1.5533; const float tt = 57.14902;
    float theta = r < tt ? atan(r) : TMAX + (r - tt) / (1.0 + tt * tt);
    float p = gopro_poly_invert(theta, k1, k2);
    float r_norm = k1.y * p;
    float scale = r == 0.0 ? 1.0 : r_norm / r;
    return pos * scale;
}
