// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2022 Adrian <adrian.eddy at gmail>

vec2 distort_point(vec3 dir, vec4 k1, vec4 k2, vec4 k3) {
    // Coefficient naming here follows the Unified Sphere Model convention (k1,k2,k3 radial,
    // p1,p2 tangential, xi sphere offset) packed into params.k1/k2 - unrelated to (and
    // shadowed by, hence read inline below rather than as locals) the k1/k2/k3 arguments.
    vec3 P = dir / length(dir);

    float x = P.x / (P.z + k2.y); // xi
    float y = P.y / (P.z + k2.y); // xi

    float r2 = x*x + y*y;
    float r4 = r2 * r2;
    float r6 = r4 * r2;

    float radial = 1.0 + k1.x*r2 + k1.y*r4 + k1.z*r6; // 1 + k1*r2 + k2*r4 + k3*r6

    return vec2(
        x * radial + 2.0*k1.w*x*y + k2.x*(r2 + 2.0*x*x), // p1, p2
        y * radial + 2.0*k2.x*x*y + k1.w*(r2 + 2.0*y*y)  // p2, p1
    );
}

vec2 undistort_point(vec2 p) {
    vec2 P = p;

    for (int i = 0; i < 200; i++) {
        vec2 diff = distort_point(vec3(P.x, P.y, 1.0), params.k1, params.k2, params.k3) - p;
        if (abs(diff.x) < 1e-6 && abs(diff.y) < 1e-6) {
            break;
        }
        P -= diff;
    }

    return P;
}
