// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2021-2022 Adrian <adrian.eddy at gmail>
// Converted into 3D space to support 360 variants
// by Vlad A < elf128 at gmail>

// Adapted from OpenCV: initUndistortRectifyMap
// https://github.com/opencv/opencv/blob/2b60166e5c65f1caccac11964ad760d847c536e4/modules/calib3d/src/fisheye.cpp#L465-L567

#version 420

layout(location = 0) in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

layout(binding = 1) uniform sampler2D texIn;

layout(std140, binding = 2) uniform KernelParams
{
    int width;             // 4
    int height;            // 8
    int stride;            // 12
    int output_width;      // 16

    int output_height;     // 4
    int output_stride;     // 8
    int matrix_count;      // 12 - for rolling shutter correction. 1 = no correction, only main matrix
    int interpolation;     // 16

    int background_mode;   // 4
    int flags;             // 8
    int bytes_per_pixel;   // 12
    int pix_element_count; // 16

    vec4 background;    // 16

    vec2 f;             // 8  - focal length in pixels
    vec2 c;             // 16 - lens center
    vec4 k1, k2, k3;    // 16, 16, 16 - distortion coefficients

    float fov;          // 4
    float r_limit;      // 8
    float lens_correction_amount;   // 12
    float input_vertical_stretch;   // 16

    float input_horizontal_stretch; // 4
    float background_margin;        // 8
    float background_margin_feather;// 12
    float canvas_scale;             // 16

    float input_rotation;           // 4
    float output_rotation;          // 8
    vec2 translation2d;             // 16

    vec4 translation3d;             // 16
    ivec4 source_rect;              // 16 - x, y, w, h - unused in this kernel
    ivec4 output_rect;              // 16 - x, y, w, h - unused in this kernel
    vec4 digital_lens_params[4];    // 16,16,16,16
    vec4 safe_area_rect;            // 16

    float max_pixel_value;          // 4
    int distortion_model;           // 8
    int digital_lens;               // 12
    float pixel_value_limit;        // 16

    float light_refraction_coefficient; // 4
    int plane_index;                // 8
    float reserved1;                // 12
    float reserved2;                // 16

    vec4 ewa_coefs_p;               // 16
    vec4 ewa_coefs_q;               // 16
} params;

LENS_MODEL_FUNCTIONS;

layout(binding = 3) uniform sampler2D texParams;
layout(binding = 4) uniform sampler2D texCanvas;
layout(binding = 5) uniform sampler2D texMeshData;

const vec4 colors[9] = vec4[9](
    vec4(0.0,   0.0,   0.0,     0.0), // None
    vec4(255.0, 0.0,   0.0,   255.0), // Red
    vec4(0.0,   255.0, 0.0,   255.0), // Green
    vec4(0.0,   0.0,   255.0, 255.0), // Blue
    vec4(254.0, 251.0, 71.0,  255.0), // Yellow
    vec4(200.0, 200.0, 0.0,   255.0), // Yellow2
    vec4(255.0, 0.0,   255.0, 255.0), // Magenta
    vec4(0.0,   128.0, 255.0, 255.0), // Blue2
    vec4(0.0,   200.0, 200.0, 255.0)  // Blue3
);

const float alphas[4] = float[4](1.0, 0.75, 0.50, 0.25);

void draw_pixel(inout vec4 out_pix, float x, float y, bool isInput)
{
    if ( (params.flags & 8) == 0 )
    { // Drawing not enabled
        return;
    }

    int width = max(params.width, params.output_width);
    int height = max(params.height, params.output_height);

    int data = int(ceil(texture(texCanvas, vec2(x / width, y / height)).r * 255.0));

    if (data > 0)
    {
        int color = (data & 0xF8) >> 3;
        int alpha = (data & 0x06) >> 1;
        int stage = data & 1;

        if (((stage == 0 && isInput) || (stage == 1 && !isInput)) && color < 9)
        {
            vec4 colorf = colors[color] / 255.0;
            float alphaf = alphas[alpha];
            out_pix = colorf * alphaf + out_pix * (1.0 - alphaf);
            out_pix.a = 1.0;
        }
    }
}

void draw_safe_area(inout vec4 out_pix, float x, float y)
{
    bool isSafeArea = ( x >= params.safe_area_rect.x ) &&
                      ( x <= params.safe_area_rect.z ) &&
                      ( y >= params.safe_area_rect.y ) &&
                      ( y <= params.safe_area_rect.w );

    if (!isSafeArea)
    {
        out_pix.x *= 0.5;
        out_pix.y *= 0.5;
        out_pix.z *= 0.5;

        bool isBorder = ( x >= params.safe_area_rect.x - 5.0 ) &&
                        ( x <= params.safe_area_rect.z + 5.0 ) &&
                        ( y >= params.safe_area_rect.y - 5.0 ) &&
                        ( y <= params.safe_area_rect.w + 5.0 );
        if (isBorder)
        {
            out_pix.x *= 0.5;
            out_pix.y *= 0.5;
            out_pix.z *= 0.5;
        }
    }
}

float get_param( float row, float idx )
{
    int size = bool( params.flags & 16 )
                ? params.width
                : params.height;

    return texture(
        texParams,
        vec2(
            (idx + 0.5) / 21.0,
            row / float( size - 1 )
        )).r;
}

float map_coord(float x, float in_min, float in_max, float out_min, float out_max)
{
    return ( x - in_min) * (out_max - out_min) / ( in_max - in_min ) + out_min;
}

vec2 rotate_and_distort(vec2 pos, float idx)
{
    // Row-major 4×4 stored in texels 0–15; build GLSL column-major mat4.
    mat4 M = mat4(
        get_param(idx,  0), get_param(idx,  4), get_param(idx,  8), get_param(idx, 12),
        get_param(idx,  1), get_param(idx,  5), get_param(idx,  9), get_param(idx, 13),
        get_param(idx,  2), get_param(idx,  6), get_param(idx, 10), get_param(idx, 14),
        get_param(idx,  3), get_param(idx,  7), get_param(idx, 11), get_param(idx, 15)
    );
    // Input: output pixel (pos.xy), homogeneous W=1, unit depth Z=1.
    vec4 _pos = M * vec4(pos, 1.0, 1.0);

    // Per-row IBIS/OIS corrections stored at texels 16–20.
    float sx = get_param(idx, 16);
    float sy = get_param(idx, 17);
    float ra = get_param(idx, 18);
    float ox = get_param(idx, 19);
    float oy = get_param(idx, 20);

    if ( params.r_limit > 0.0 && atan(length(vec2(_pos.x, _pos.y)), _pos.z) > atan(params.r_limit) )
    {
        return vec2( -99999.0, -99999.0 );
    }

    if ( params.light_refraction_coefficient != 1.0 &&
         params.light_refraction_coefficient > 0.0 )
    {
        float r_xy      = length(vec2(_pos.x, _pos.y));
        float sin_theta   = sin(atan(r_xy, _pos.z));
        float sin_theta_d = sin_theta * params.light_refraction_coefficient;
        if (sin_theta < 1.0 && sin_theta_d < 1.0)
        {
            float r   = sin_theta   / sqrt(1.0 - sin_theta   * sin_theta);
            float r_d = sin_theta_d / sqrt(1.0 - sin_theta_d * sin_theta_d);
            if (r_d != 0.0) { _pos.z *= r / r_d; }
        }
    }

    vec2 uv = params.f * distort_point(_pos.x, _pos.y, _pos.z) + params.c;

    if ( sx != 0.0 || sy != 0.0 || ra != 0.0 || ox != 0.0 || oy != 0.0 )
    {
        float cos_a = cos(-ra);
        float sin_a = sin(-ra);
        uv -= params.c;
        uv = vec2(
            cos_a * uv.x - sin_a * uv.y - sx + ox,
            sin_a * uv.x + cos_a * uv.y - sy + oy
        );
        uv += params.c;
    }
    uv = process_coord(uv, idx);

    if (bool(params.flags & 2))
    { // Has digital lens
        uv = digital_distort_point(uv);
    }

    if ( params.input_horizontal_stretch > 0.001 )
        uv.x /= params.input_horizontal_stretch;

    if ( params.input_vertical_stretch   > 0.001 )
        uv.y /= params.input_vertical_stretch;

    return uv;
}

vec2 rotate_point(vec2 pos, float angle, vec2 origin, vec2 origin2)
{
     return vec2(
         cos( angle ) * (pos.x - origin.x) - sin(angle) * (pos.y - origin.y) + origin2.x,
         sin( angle ) * (pos.x - origin.x) + cos(angle) * (pos.y - origin.y) + origin2.y);
}

// Re-applies a partial amount of lens distortion, blending by correctionAmount.
// pos:                  position in [-1, 1] centered at zero
// correctionAmount:     lens_correction_amount (0 = full distortion restored, 1 = fully corrected)
// focalLength:          focal length in [-1, 1] units (params.f / (outSize * 0.5))
// fov:                  field-of-view scale factor
// hasDigitalLens:       whether a digital lens warp is active
// lightRefractionCoeff: light refraction coefficient (1.0 = none)
vec2 addDistortion(vec2 pos, float correctionAmount, vec2 focalLength, float fov,
                   bool hasDigitalLens, float lightRefractionCoeff)
{
    float factor = max( 1.0 - correctionAmount, 0.001 ); // FIXME: this is close but wrong
    vec2  out_f  = ( focalLength / fov ) / factor;

    vec2 result = pos;

    if ( hasDigitalLens )
    {
        // Un-zoom -> warp -> re-zoom, all in [-1, 1] space.
        vec2 norm = result * fov;
        norm = digital_undistort_point(norm);
        result = norm / fov;
    }

    result = result / out_f;
    result = undistort_point(result);

    if (lightRefractionCoeff != 1.0 && lightRefractionCoeff > 0.0)
    {
        float r = length(result);
        if (r != 0.0)
        {
            float sin_theta_d = (r / sqrt(1.0 + r * r)) / lightRefractionCoeff;
            float r_d = sin_theta_d / sqrt(1.0 - sin_theta_d * sin_theta_d);
            result *= r_d / r;
        }
    }
    result = out_f * result;

    return result * ( 1.0 - correctionAmount ) + pos * correctionAmount;
}

void main()
{
    // outSize is the export/stab output dimensions. Used as the coordinate basis for
    // addDistortion and overlay pixel coordinates (draw_pixel / draw_safe_area).
    const vec2 outSize = vec2(params.output_width, params.output_height);

    // Work in centered proportional space: (0,0) = frame center, ±0.5 = edges.
    vec2 texPos = v_texcoord.xy - 0.5 + params.translation2d;
    vec2 outPos = v_texcoord.xy * outSize;

    //fragColor = vec4( outPos, 0.0f, 1.0f );

    //return;

    if ( bool( params.flags & 4 ) )
    {
        // Fill with background
        fragColor = params.background;
        return;
    }

    ///////////////////////////////////////////////////////////////////
    // Add lens distortion back
    //
    if ( params.lens_correction_amount < 1.0 )
    {
        vec2 center = outSize * 0.5;
        // texPos in [-0.5, 0.5]; convert to [-1, 1] for addDistortion, then back.
        vec2 norm = texPos * 2.0;
        norm = addDistortion(
            norm,
            params.lens_correction_amount,
            params.f / center,
            params.fov,
            bool( params.flags & 2 ),
            params.light_refraction_coefficient
        );
        texPos = norm * 0.5;
    }

    ///////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////
    // Calculate source `y` for rolling shutter.
    // texPos is in centered proportional space [-0.5, 0.5]; map to matrix index.
    float sy;
    if (bool(params.flags & 16))
    { // Horizontal RS
        sy = (texPos.x + 0.5) * float(params.matrix_count - 1);
    }
    else
    {
        sy = (texPos.y + 0.5) * float(params.matrix_count - 1);
    }

    if (params.matrix_count > 1)
    {
        float idx = params.matrix_count / 2.0; // Use middle matrix
        vec2 uv = rotate_and_distort(texPos, idx);
        if (uv.x > -99998.0)
        {
            if (bool(params.flags & 16))
            { // Horizontal RS — uv in input pixel space
                sy = (uv.x / float(params.width))  * float(params.matrix_count - 1);
            }
            else
            {
                sy = (uv.y / float(params.height)) * float(params.matrix_count - 1);
            }
        }
    }

    ///////////////////////////////////////////////////////////////////

    float idx = clamp(sy, 0.0, params.matrix_count - 1.0);

    vec2 uv = rotate_and_distort(texPos, idx);
    vec2 frame_size = vec2(params.width, params.height);
    if (params.input_rotation != 0.0)
    {
        float rotation = params.input_rotation * (3.1415926535897 / 180.0);
        vec2 size = frame_size;

        frame_size = abs( round( rotate_point( size, rotation, vec2(0.0, 0.0), vec2(0.0, 0.0) ) ) );
        uv = rotate_point( uv, rotation, size / vec2(2.0), frame_size / vec2(2.0) );
    }

    if (uv.x > -99998.0)
    {
        if (params.background_mode == 1)
        { // edge repeat
            uv = max(vec2(0, 0), min(vec2(params.width - 1, params.height - 1), uv));
        }
        else if ( params.background_mode == 2)
        { // edge mirror
            float width3  = (params.width - 2);
            float height3 = (params.height - 2);

            if (uv.x > width3)  uv.x = width3  - (uv.x - width3);
            if (uv.x < 2)       uv.x = 2 + params.width - (width3  + uv.x);
            if (uv.y > height3) uv.y = height3 - (uv.y - height3);
            if (uv.y < 2)       uv.y = 2 + params.height - (height3 + uv.y);
        }
        else if (params.background_mode == 3)
        { // margin with feather
            float widthf  = (params.width  - 1);
            float heightf = (params.height - 1);

            float feather = max(0.0001, params.background_margin_feather * heightf);
            vec2 pt2 = uv;
            float alpha = 1.0;

            if ((uv.x > widthf - feather) ||
                (uv.x < feather) ||
                (uv.y > heightf - feather) ||
                (uv.y < feather) )
            {
                alpha = max(0.0, min(1.0, min(min(widthf - uv.x, heightf - uv.y), min(uv.x, uv.y)) / feather));
                pt2 /= vec2(widthf, heightf);
                pt2 = ((pt2 - 0.5) * (1.0 - params.background_margin)) + 0.5;
                pt2 *= vec2(widthf, heightf);
            }

            vec4 c1 = texture(texIn, vec2(uv.x / params.width, uv.y / params.height));
            vec4 c2 = texture(texIn, vec2(pt2.x / params.width, pt2.y / params.height));
            fragColor = c1 * alpha + c2 * (1.0 - alpha);
            fragColor.a = 1.0;
            if (!((pt2.x >= 0 && pt2.x < params.width) && (pt2.y >= 0 && pt2.y < params.height)))
            {
                fragColor = params.background;
            }

            draw_pixel(fragColor, uv.x, uv.y, true);
            draw_pixel(fragColor, outPos.x, outPos.y, false);
            draw_safe_area(fragColor, outPos.x, outPos.y);
            return;
        }

        if ( (uv.x >= 0 &&
              uv.x < frame_size.x) &&
              ( uv.y >= 0 && uv.y < frame_size.y) )
        {
            fragColor = texture(texIn, vec2(uv.x / frame_size.x, uv.y / frame_size.y));
            draw_pixel(fragColor, uv.x, uv.y, true);
            draw_pixel(fragColor, outPos.x, outPos.y, false);
            draw_safe_area(fragColor, outPos.x, outPos.y);
            return;
        }
    }

    fragColor = params.background;
    draw_pixel(fragColor, outPos.x, outPos.y, false);
    draw_safe_area(fragColor, outPos.x, outPos.y);
}
