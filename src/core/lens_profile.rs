// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2021-2022 Adrian <adrian.eddy at gmail>

use std::collections::{ HashSet, BTreeMap };
use itertools::Itertools;

use serde::{ Serialize, Deserialize };

use crate::stabilization::distortion_models::DistortionModel;
use crate::stabilization_params::ReadoutDirection;

#[cfg(feature = "opencv")]
use super::LensCalibrator;

#[derive(Deserialize, Serialize, Default, Clone, Debug)]
pub struct Dimensions { pub w: usize, pub h: usize }

#[derive(Deserialize, Serialize, Default, Clone, Debug)]
#[serde(default)]
#[allow(non_snake_case)]
pub struct CameraParams { pub RMS_error: f64, pub camera_matrix: Vec<[f64; 3]>, pub distortion_coeffs: Vec<f64>, pub radial_distortion_limit: Option<f64> }

#[derive(Deserialize, Serialize, Default, Clone, Debug, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum DualLensLayout {
    #[default]
    None,
    SeparateFiles,
    SideBySide,
    TopBottom,
}

/// Calibration and settings for a single optical path. A `LensProfile` with one `LensParams`
/// entry is an ordinary single-lens profile; two (or more) entries make it a dual/multi-lens
/// profile - see `LensProfile::lens`. Everything here is per-lens: it's the shape a
/// calibration session actually produces (`set_from_calibrator`), and what the render
/// pipeline pulls coefficients from for one specific lens.
#[derive(Deserialize, Serialize, Clone, Debug)]
#[serde(default)]
pub struct LensParams {
    pub lens_model: String,

    pub calib_dimension: Dimensions,
    pub orig_dimension: Dimensions,

    /// Rolling shutter readout - genuinely per-sensor, though for a shared-body dual-fisheye
    /// rig it's usually identical across lenses. Can differ for heterogeneous camera pairs.
    pub frame_readout_time: Option<f64>,
    pub frame_readout_direction: Option<ReadoutDirection>,

    pub input_horizontal_stretch: f64,
    pub input_vertical_stretch: f64,
    pub num_images: usize,

    pub crop: Option<f64>,

    pub asymmetrical: bool,

    pub fisheye_params: CameraParams,

    /// Used to auto-match a loaded video's detected camera identifier to this lens entry.
    pub identifier: String,

    pub compatible_settings: Vec<serde_json::Value>,

    pub sync_settings: Option<serde_json::Value>,

    pub distortion_model: Option<String>,
    pub digital_lens: Option<String>,
    pub digital_lens_params: Option<Vec<f64>>,

    pub interpolations: Option<serde_json::Value>,

    pub focal_length: Option<f64>,
    pub crop_factor: Option<f64>,
    pub global_shutter: bool,

    /// Rotation from the reference lens's frame (`lens[0]`, always identity) to this lens's
    /// own camera space. Quaternion, stored as `[w, x, y, z]`. For a back-to-back dual-fisheye
    /// rig this directly encodes the full mounting rotation (nominally ~180° about Y, plus
    /// whatever real deviation the specific unit has, including roll around the optical axis)
    /// - there is no separate hardcoded base rotation anywhere else in the pipeline.
    pub rotation_offset: [f64; 4],

    // Skip these fields, make sure to update in `LensProfile::get_json_value`
    pub optimal_fov: Option<f64>,
    parsed_interpolations: BTreeMap<i64, LensParams>,
}

impl Default for LensParams {
    fn default() -> Self {
        Self {
            lens_model: String::new(),
            calib_dimension: Dimensions::default(),
            orig_dimension: Dimensions::default(),
            frame_readout_time: None,
            frame_readout_direction: None,
            input_horizontal_stretch: 0.0,
            input_vertical_stretch: 0.0,
            num_images: 0,
            crop: None,
            asymmetrical: false,
            fisheye_params: CameraParams::default(),
            identifier: String::new(),
            compatible_settings: Vec::new(),
            sync_settings: None,
            distortion_model: None,
            digital_lens: None,
            digital_lens_params: None,
            interpolations: None,
            focal_length: None,
            crop_factor: None,
            global_shutter: false,
            rotation_offset: [1.0, 0.0, 0.0, 0.0],
            optimal_fov: None,
            parsed_interpolations: BTreeMap::new(),
        }
    }
}

#[derive(Deserialize, Serialize, Default, Clone, Debug)]
#[serde(default)]
pub struct LensProfile {
    pub name: String,
    pub note: String,
    pub calibrated_by: String,
    pub camera_brand: String,
    pub camera_model: String,
    pub camera_setting: String,

    pub output_dimension: Option<Dimensions>,

    /// IMU/gyro is a single physical sensor per profile even when there are two lenses -
    /// only the primary body's IMU is ever used (see Phase1 dual-lens design), so this
    /// stays profile-level rather than living on each `LensParams`.
    pub gyro_lpf: Option<f64>,
    pub imu_orientation: Option<String>,

    /// Drives the MDK player's frame timing and the timeline/frame-index mapping - one
    /// clock for the whole session, so this must stay profile-level even for dual-lens
    /// (varying it per lens would desync playback).
    pub fps: f64,

    pub official: bool,

    pub calibrator_version: String,
    pub date: String,

    /// How multiple lenses' source video is packed/arranged. `None`/single-entry `lens`
    /// means a normal single-lens profile.
    pub layout: DualLensLayout,

    /// One entry = single-lens profile (the common case). Two (or more) = dual/multi-lens.
    /// Old profile JSON (no `lens` array) is loaded as a single implicit entry - see
    /// `from_value`.
    pub lens: Vec<LensParams>,

    // Skip these fields, make sure to update in `get_json_value`
    pub path_to_file: String,
    pub is_copy: bool,
    pub rating: Option<f64>,
    pub checksum: Option<String>,
}

impl LensParams {
    pub fn init(&mut self) {
        if !self.fisheye_params.distortion_coeffs.is_empty() && !self.distortion_model.as_deref().is_some_and(|x| x == "gopro") {
            let distortion_model = DistortionModel::from_name(self.distortion_model.as_deref().unwrap_or("opencv_fisheye"));
            self.fisheye_params.radial_distortion_limit = distortion_model.radial_distortion_limit(&self.get_distortion_coeffs());
        }
    }

    #[cfg(feature = "opencv")]
    pub fn set_from_calibrator(&mut self, cal: &LensCalibrator) {
        if self.input_horizontal_stretch <= 0.01 { self.input_horizontal_stretch = 1.0; }
        if self.input_vertical_stretch   <= 0.01 { self.input_vertical_stretch   = 1.0; }

        self.calib_dimension = Dimensions { w: cal.width, h: cal.height };
        self.orig_dimension  = Dimensions { w: cal.width, h: cal.height };
        self.num_images = cal.used_points.len();
        self.digital_lens = cal.digital_lens.clone();
        self.optimal_fov = None;

        self.asymmetrical = cal.asymmetrical;

        self.fisheye_params = CameraParams {
            RMS_error: cal.rms,
            camera_matrix: cal.k.row_iter().map(|x| [x[0], x[1], x[2]]).collect(),
            distortion_coeffs: cal.d.as_slice().to_vec(),
            radial_distortion_limit: None
        };
    }

    fn get_camera_matrix_internal(&self, invert_h: bool) -> Option<nalgebra::Matrix3<f64>> {
        if self.fisheye_params.camera_matrix.len() == 3 {
            let mut mat = nalgebra::Matrix3::from_rows(&[
                self.fisheye_params.camera_matrix[0].into(),
                self.fisheye_params.camera_matrix[1].into(),
                self.fisheye_params.camera_matrix[2].into()
            ]);
            if !self.asymmetrical {
                mat[(0, 2)] = self.calib_dimension.w as f64 / 2.0;
                mat[(1, 2)] = self.calib_dimension.h as f64 / 2.0;
            } else if invert_h {
                mat[(1, 2)] = self.calib_dimension.h as f64 - mat[(1, 2)];
            }
            if let Some(crop) = self.crop {
                mat[(0, 0)] /= crop;
                mat[(1, 1)] /= crop;
            }
            Some(mat)
        } else {
            None
        }
    }
    pub fn get_camera_matrix(&self, size: (usize, usize), invert_h: bool) -> nalgebra::Matrix3<f64> {
        if self.fisheye_params.camera_matrix.len() == 3 {
            let mat = self.get_camera_matrix_internal(invert_h).unwrap();

            // TODO: this didn't really work, try to figure it out and re-enable
            // if self.optimal_fov.is_none() && self.num_images > 3 {
            //     self.optimal_fov = Some(self.calculate_optimal_fov(video_size));
            //     log::debug!("Optimal lens FOV: {:?} ({:?})", self.optimal_fov, video_size);
            // }

            mat
        } else {
            // Default camera matrix
            let mut mat = nalgebra::Matrix3::<f64>::identity();
            mat[(0, 0)] = size.0 as f64 * 0.8;
            mat[(1, 1)] = size.0 as f64 * 0.8;
            mat[(0, 2)] = size.0 as f64 / 2.0;
            mat[(1, 2)] = size.1 as f64 / 2.0;
            mat
        }
    }
    pub fn get_distortion_coeffs(&self) -> [f64; 12] {
        let mut ret = [0.0; 12];
        for (i, x) in self.fisheye_params.distortion_coeffs.iter().enumerate() {
            if i < 12 {
                ret[i] = *x;
            }
        }
        ret
    }

    pub fn get_aspect_ratio(&self) -> String {
        if self.calib_dimension.w == 0 || self.calib_dimension.h == 0 {
            return String::new();
        }

        let ratios = [
            (1.0, "1:1"),
            (3.0/2.0, "3:2"), (2.0/3.0, "2:3"),
            (4.0/3.0, "4:3"), (3.0/4.0, "3:4"),
            (8.0/7.0, "8:7"), (7.0/8.0, "7:8"),
            (16.0/9.0, "16:9"), (9.0/16.0, "9:16")
        ];
        let ratio = self.calib_dimension.w as f64 / self.calib_dimension.h as f64;
        let mut diffs = ratios.into_iter().map(|x| ((x.0 - ratio).abs(), x.1)).collect::<Vec<_>>();
        diffs.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Less));
        let (lowest_diff, ratio_str) = *diffs.first().unwrap();
        if lowest_diff < 0.05 {
            return ratio_str.to_string();
        }

        let gcd = num::integer::gcd(self.calib_dimension.w, self.calib_dimension.h);

        let ratio1 = self.calib_dimension.w / gcd;
        let ratio2 = self.calib_dimension.h / gcd;

        if ratio1 >= 20 || ratio2 >= 20 {
            format!("{:.2}:1", ratio)
        } else {
            format!("{}:{}", ratio1, ratio2)
        }
    }
    pub fn get_size_str(&self) -> &'static str {
             if self.calib_dimension.w >= 8000 { "8k" }
        else if self.calib_dimension.w >= 6000 { "6k" }
        else if self.calib_dimension.w >= 5000 { "5k" }
        else if self.calib_dimension.w >  4000 { "C4k" }
        else if self.calib_dimension.w >= 3840 { "4k" }
        else if self.calib_dimension.w >= 2700 { "2.7k" }
        else if self.calib_dimension.w >= 2500 { "2.5k" }
        else if self.calib_dimension.w >= 2000 { "2k" }
        else if self.calib_dimension.w == 1920 && self.calib_dimension.h == 1440 { "1440p" }
        else if self.calib_dimension.w >= 1920 { "1080p" }
        else if self.calib_dimension.w >= 1280 { "720p" }
        else if self.calib_dimension.w >= 640  { "480p" }
        else { "" }
    }

    pub fn swapped(&self) -> LensParams {
        let mut ret = self.clone();
        std::mem::swap(&mut ret.orig_dimension.w, &mut ret.orig_dimension.h);
        std::mem::swap(&mut ret.calib_dimension.w, &mut ret.calib_dimension.h);
        std::mem::swap(&mut ret.input_horizontal_stretch, &mut ret.input_vertical_stretch);

        if ret.fisheye_params.camera_matrix.len() == 3 {
            let mut mtrx0 = ret.fisheye_params.camera_matrix[0];
            let mut mtrx1 = ret.fisheye_params.camera_matrix[1];
            std::mem::swap(&mut mtrx0[0], &mut mtrx1[1]);
            std::mem::swap(&mut mtrx0[2], &mut mtrx1[2]);
            ret.fisheye_params.camera_matrix[0] = mtrx0;
            ret.fisheye_params.camera_matrix[1] = mtrx1;
        }

        // Swap compatible settings
        for x in ret.compatible_settings.iter_mut() {
            if let Some(x) = x.as_object_mut() {
                match (x.get("width").and_then(|x| x.as_u64()), x.get("height").and_then(|x| x.as_u64())) {
                    (Some(w), Some(h)) => {
                        x["width"] = h.into();
                        x["height"] = w.into();
                    }
                    _ => { }
                }
            }
        }

        // Swap interpolations
        for (_, x) in ret.parsed_interpolations.iter_mut() {
            *x = x.swapped();
        }

        ret
    }

    pub fn get_all_matching_profiles(&self) -> Vec<LensParams> {
        let mut ret = Vec::with_capacity(self.compatible_settings.len() + 1);
        ret.push(self.clone());
        for x in &self.compatible_settings {
            let mut cpy = self.clone();
            cpy.compatible_settings.clear();
            if let Some(x) = x.as_object() {
                if x.contains_key("width") && x.contains_key("height") {
                    let (new_w, new_h) = (x["width"].as_u64().unwrap_or_default(), x["height"].as_u64().unwrap_or_default());
                    if new_w > 0 && new_h > 0 {
                        let mut ratiow = new_w as f64 / cpy.calib_dimension.w as f64;
                        let ratioh = new_h as f64 / cpy.calib_dimension.h as f64;
                        match x.get("digital_lens").and_then(|x| x.as_str()) {
                            Some("gopro_superview") => { ratiow /= 1.33333333333; },
                            Some("gopro6_superview") => { ratiow /= 1.33333333333; },
                            Some("gopro_hyperview") => { ratiow /= 1.55555555555; },
                            _ => { }
                        }
                        fn scale(val: &mut usize, ratio: f64, pad: bool) {
                            *val = (*val as f64 * ratio).round() as usize;
                            if pad && *val % 2 != 0 { *val -= 1; }
                        }
                        scale(&mut cpy.calib_dimension.w, ratiow, true);
                        scale(&mut cpy.calib_dimension.h, ratioh, true);
                        scale(&mut cpy.orig_dimension.w, ratiow, true);
                        scale(&mut cpy.orig_dimension.h, ratioh, true);
                        if cpy.fisheye_params.camera_matrix.len() > 1 {
                            // If aspect ratio is different, then we treat it as a sensor crop.
                            // In this case, we don't want to scale the camera matrix
                            // Otherwise, it's not a crop, but sub- or super-sampling so we simply "zoom" the entire video
                            if (ratiow - ratioh).abs() < 0.001 { // if x and y aspect ratios are the same
                                cpy.fisheye_params.camera_matrix[0][0] *= ratiow;
                                cpy.fisheye_params.camera_matrix[0][2] *= ratiow;
                                cpy.fisheye_params.camera_matrix[1][1] *= ratioh;
                                cpy.fisheye_params.camera_matrix[1][2] *= ratioh;
                            }
                        }
                    }
                }
                if x.contains_key("frame_readout_time") {
                    cpy.frame_readout_time = x["frame_readout_time"].as_f64();
                }
                if x.contains_key("crop") { cpy.crop = x["crop"].as_f64(); }
                if x.contains_key("interpolations") { cpy.interpolations = x.get("interpolations").cloned(); }
                if x.contains_key("digital_lens")   { cpy.digital_lens   = x.get("digital_lens").and_then(|x| x.as_str().map(|x| x.to_owned())); }
                if x.contains_key("focal_length")   { cpy.focal_length   = x.get("focal_length").and_then(|x| x.as_f64()); }
                if x.contains_key("crop_factor")    { cpy.crop_factor    = x.get("crop_factor").and_then(|x| x.as_f64()); }
                if let Some(v) = x.get("input_horizontal_stretch").and_then(|x| x.as_f64()) { cpy.input_horizontal_stretch = v; }
                if let Some(v) = x.get("input_vertical_stretch")  .and_then(|x| x.as_f64()) { cpy.input_vertical_stretch   = v; }
                if let Some(v) = x.get("lens_model")  .and_then(|x| x.as_str()) { cpy.lens_model = v.to_owned(); }
                if let Some(row) = x.get("distortion_coeffs").and_then(|x| x.as_array()) {
                    for (i, v) in row.iter().enumerate() {
                        if let Some(v) = v.as_f64() {
                            cpy.fisheye_params.distortion_coeffs[i] = v;
                        }
                    }
                }

                if x.contains_key("sync_settings") {
                    if let Some(obj) = x.get("sync_settings") {
                        if let Some(ref mut ss) = cpy.sync_settings {
                            if obj.get("custom_sync_pattern").is_some() && ss.get("custom_sync_pattern").is_some() {
                                ss.as_object_mut().unwrap().remove("custom_sync_pattern");
                            }
                            crate::util::merge_json(ss, obj);
                        } else {
                            cpy.sync_settings = Some(obj.clone());
                        }
                    }
                }
                if x.contains_key("identifier") {
                    cpy.identifier = x["identifier"].as_str().unwrap_or_default().to_string();
                }
                ret.push(cpy);
            }
        }
        ret
    }

    pub fn get_interpolated_lens_at(&self, val: f64) -> LensParams {
        let mut cpy = self.clone();

        if !self.parsed_interpolations.is_empty() {
            let key = (val * 1000000.0).round() as i64;

            if let Some(v) = self.parsed_interpolations.get(&key) { return v.clone(); }

            if let Some(&first) = self.parsed_interpolations.keys().next() {
                if let Some(&last) = self.parsed_interpolations.keys().next_back() {
                    let lookup = (key).min(last-1).max(first+1);
                    if let Some(p1) = self.parsed_interpolations.range(..=lookup).next_back() {
                        if *p1.0 == lookup {
                            return p1.1.clone();
                        }
                        if let Some(p2) = self.parsed_interpolations.range(lookup..).next() {
                            let time_delta = (p2.0 - p1.0) as f64;
                            let fract = (key - p1.0) as f64 / time_delta;

                            let l1 = p1.1;
                            let l2 = p2.1;
                            // println!("interpolated at {:.4}, fract: {:.4}", val, fract);

                            cpy.fisheye_params.camera_matrix[0][0] = l1.fisheye_params.camera_matrix[0][0] * (1.0 - fract) + (l2.fisheye_params.camera_matrix[0][0] * fract);
                            cpy.fisheye_params.camera_matrix[1][1] = l1.fisheye_params.camera_matrix[1][1] * (1.0 - fract) + (l2.fisheye_params.camera_matrix[1][1] * fract);
                            cpy.fisheye_params.camera_matrix[0][2] = l1.fisheye_params.camera_matrix[0][2] * (1.0 - fract) + (l2.fisheye_params.camera_matrix[0][2] * fract);
                            cpy.fisheye_params.camera_matrix[1][2] = l1.fisheye_params.camera_matrix[1][2] * (1.0 - fract) + (l2.fisheye_params.camera_matrix[1][2] * fract);

                            if cpy.fisheye_params.distortion_coeffs.len() == l1.fisheye_params.distortion_coeffs.len() && l1.fisheye_params.distortion_coeffs.len() == l2.fisheye_params.distortion_coeffs.len() {
                                for i in 0..l1.fisheye_params.distortion_coeffs.len() {
                                    cpy.fisheye_params.distortion_coeffs[i] = l1.fisheye_params.distortion_coeffs[i] * (1.0 - fract) + (l2.fisheye_params.distortion_coeffs[i] * fract);
                                }
                            }
                            cpy.crop = Some(l1.crop.unwrap_or(1.0) * (1.0 - fract) + (l2.crop.unwrap_or(1.0) * fract));

                            match (l1.focal_length, l2.focal_length) {
                                (Some(fl1), Some(fl2)) => { cpy.focal_length = Some(fl1 * (1.0 - fract) + (fl2 * fract))},
                                _ => { }
                            }

                            cpy.calib_dimension.w = (l1.calib_dimension.w as f64 * (1.0 - fract) + (l2.calib_dimension.w as f64 * fract)).round() as usize;
                            cpy.calib_dimension.h = (l1.calib_dimension.h as f64 * (1.0 - fract) + (l2.calib_dimension.h as f64 * fract)).round() as usize;

                            cpy.input_horizontal_stretch = l1.input_horizontal_stretch * (1.0 - fract) + (l2.input_horizontal_stretch * fract);
                            cpy.input_vertical_stretch   = l1.input_vertical_stretch   * (1.0 - fract) + (l2.input_vertical_stretch   * fract);

                            // TODO: digital lens interpolation?
                        }
                    }
                }
            }
        }

        cpy
    }

    pub fn resolve_interpolations(&mut self, db: &crate::lens_profile_database::LensProfileDatabase) {
        if !self.parsed_interpolations.is_empty() {
            return; // Already resolved
        }

        if let Some(digital) = self.digital_lens.as_ref() {
            let model = DistortionModel::from_name(&digital);
            model.adjust_lens_profile(self);
        }

        if let Some(serde_json::Value::Object(map)) = &self.interpolations {
            let mut interpolations = BTreeMap::new();
            for (k, v) in map {
                if let serde_json::Value::Object(v) = v {
                    if let Ok(key) = k.parse::<f64>() {
                        let key = (key * 1000000.0).round() as i64;
                        let mut new_params = self.clone();
                        if let Some(id) = v.get("identifier").and_then(|x| x.as_str()) {
                            if let Some(profile) = db.get_by_id(id) {
                                if let Some(primary) = profile.lens.first() {
                                    new_params = primary.clone();
                                }
                            }
                        }
                        new_params.interpolations = None;
                        if let Some(row) = v.get("camera_matrix").and_then(|x| x.as_array()) {
                            for (i, r) in row.iter().enumerate() {
                                if let Some(col) = r.as_array() {
                                    for (j, c) in col.iter().enumerate() {
                                        if let Some(v) = c.as_f64() {
                                            new_params.fisheye_params.camera_matrix[i][j] = v;
                                        }
                                    }
                                }
                            }
                        }
                        if let Some(row) = v.get("distortion_coeffs").and_then(|x| x.as_array()) {
                            for (i, v) in row.iter().enumerate() {
                                if let Some(v) = v.as_f64() {
                                    new_params.fisheye_params.distortion_coeffs[i] = v;
                                }
                            }
                        }
                        if let Some(fl) = v.get("focal_length").and_then(|x| x.as_f64()) {
                            new_params.focal_length = Some(fl);
                        }
                        interpolations.insert(key, new_params);
                    }
                }
            }
            self.parsed_interpolations = interpolations;
        }
    }
}

impl LensProfile {
    pub fn init(&mut self) {
        for lens in self.lens.iter_mut() {
            lens.init();
        }
    }

    /// The primary lens (`lens[0]`), creating a default one first if the profile is empty
    /// (e.g. nothing loaded yet). Used by setters that mutate "the" lens's calibration
    /// without caring whether a dual-lens `lens[1]` also exists.
    pub fn primary_mut(&mut self) -> &mut LensParams {
        self.lens_mut(0)
    }

    /// The lens at `index`, padding with default entries first if the profile doesn't have
    /// that many yet. `lens_mut(1)` is how the second lens of a dual-lens profile gets
    /// created in the first place - there's no separate "add a lens" constructor, it's
    /// implicit in writing to an index that doesn't exist yet.
    pub fn lens_mut(&mut self, index: usize) -> &mut LensParams {
        while self.lens.len() <= index {
            self.lens.push(LensParams::default());
        }
        &mut self.lens[index]
    }

    /// Loads a `LensProfile` from parsed JSON, transparently handling both shapes:
    /// - New: profile-level fields at top, lens-level fields inside a `lens: [...]` array.
    /// - Legacy (all existing single-lens profiles): every field flattened at top level,
    ///   no `lens` key at all. Deserializing a `LensParams` from that same top-level object
    ///   works unmodified - it just picks out the keys it recognizes and defaults the rest,
    ///   exactly like `LensProfile`'s own deserialization does for the profile-level keys.
    pub fn from_value(json: serde_json::Value) -> Result<Self, serde_json::Error> {
        let mut profile: LensProfile = serde_json::from_value(json.clone())?;
        if profile.lens.is_empty() {
            profile.lens.push(serde_json::from_value(json)?);
        }
        profile.init();
        Ok(profile)
    }
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        Self::from_value(serde_json::from_str(json)?)
    }

    pub fn load_from_data(&mut self, data: &str) -> std::result::Result<(), crate::GyroflowCoreError> {
        *self = Self::from_json(data)?;

        // Trust lens profiles loaded from file
        self.official = true;

        let primary_ok = self.lens.first().is_some_and(|l|
            !l.fisheye_params.camera_matrix.is_empty() && l.calib_dimension.w > 0 && l.calib_dimension.h > 0
        );
        if !primary_ok {
            return Err(crate::GyroflowCoreError::InvalidData);
        }

        Ok(())
    }

    pub fn load_from_file(&mut self, url: &str) -> std::result::Result<(), crate::GyroflowCoreError> {
        self.load_from_data(&crate::filesystem::read_to_string(url)?)
    }

    pub fn load_from_json_value(&mut self, v: &serde_json::Value) -> Option<()> {
        *self = Self::from_value(v.clone()).ok()?;
        Some(())
    }

    pub fn get_json_value(&self) -> Result<serde_json::Value, serde_json::error::Error> {
        let mut v = serde_json::to_value(&self)?;
        if let Some(obj) = v.as_object_mut() {
            obj.remove("filename");
            obj.remove("path_to_file");
            obj.remove("is_copy");
            obj.remove("rating");
            obj.remove("checksum");

            // Strip runtime-only fields from every lens entry.
            if let Some(serde_json::Value::Array(lens_arr)) = obj.get_mut("lens") {
                for l in lens_arr.iter_mut() {
                    if let Some(lo) = l.as_object_mut() {
                        lo.remove("optimal_fov");
                        lo.remove("parsed_interpolations");
                    }
                }
            }

            // Single-lens profiles round-trip in the legacy flat shape: hoist lens[0]'s
            // (already-cleaned) fields up to the top level and drop the `lens` array
            // entirely, rather than writing `lens: [...]` for the common case.
            if self.lens.len() == 1 {
                if let Some(serde_json::Value::Array(mut lens_arr)) = obj.remove("lens") {
                    if let Some(serde_json::Value::Object(lens_obj)) = lens_arr.pop() {
                        for (k, val) in lens_obj {
                            obj.insert(k, val);
                        }
                    }
                }
            }
        }
        Ok(v)
    }
    pub fn get_json(&self) -> Result<String, serde_json::error::Error> {
        Ok(serde_json::to_string_pretty(&self.get_json_value()?)?)
    }

    pub fn get_name(&self) -> String {
        let primary = self.lens.first().cloned().unwrap_or_default();
        let setting = if self.camera_setting.is_empty() { &self.note } else { &self.camera_setting };
        format!("{}_{}_{}_{}_{}_{}_{}x{}-{:.2}fps", self.camera_brand, self.camera_model, primary.lens_model, setting, primary.get_size_str(), primary.get_aspect_ratio().replace(':', "by"), primary.calib_dimension.w, primary.calib_dimension.h, self.fps)
    }

    /// Expands the primary lens's `compatible_settings` into full alternate profiles (same
    /// profile-level fields, primary lens swapped for the matching variant) - used to
    /// auto-select the resolution/fps/identifier variant that matches a loaded video.
    /// `fps` is profile-level (see `LensProfile::fps`) but a compatible-settings entry can
    /// still override it for that variant, so that one field is handled here rather than in
    /// `LensParams::get_all_matching_profiles` (which only knows about lens-level fields).
    pub fn get_all_matching_profiles(&self) -> Vec<LensProfile> {
        let Some(primary) = self.lens.first() else { return vec![self.clone()]; };
        let mut ret = Vec::with_capacity(primary.compatible_settings.len() + 1);
        ret.push(self.clone());
        for (variant, setting) in primary.get_all_matching_profiles().into_iter().skip(1).zip(primary.compatible_settings.iter()) {
            let mut cpy = self.clone();
            cpy.lens = vec![variant];
            if let Some(fps) = setting.as_object().and_then(|x| x.get("fps")).and_then(|x| x.as_f64()) {
                cpy.fps = fps;
            }
            ret.push(cpy);
        }
        ret
    }

    pub fn save_to_file(&mut self, url: &str) -> std::result::Result<String, crate::GyroflowCoreError> {
        let json = self.get_json()?;

        crate::filesystem::write(url, json.as_bytes())?;

        Ok(json)
    }

    pub fn swapped(&self) -> LensProfile {
        let mut ret = self.clone();
        if let Some(ref mut out) = ret.output_dimension {
            std::mem::swap(&mut out.w, &mut out.h);
        }
        ret.lens = ret.lens.iter().map(|l| l.swapped()).collect();
        ret
    }

    pub fn get_display_name(&self) -> String {
        let primary = self.lens.first().cloned().unwrap_or_default();
        if primary.calib_dimension.w == 0 || primary.calib_dimension.h == 0 {
            return String::from("---");
        }
        let mut all_sizes = HashSet::new();
        let mut all_fps = HashSet::new();
        all_sizes.insert(primary.calib_dimension.w * 10000 + primary.calib_dimension.h);
        if self.fps > 0.0 { all_fps.insert((self.fps * 10000.0) as usize); }
        for x in &primary.compatible_settings {
            if let Some(x) = x.as_object() {
                match (x.get("width").and_then(|v| v.as_u64()), x.get("height").and_then(|v| v.as_u64())) {
                    (Some(w), Some(h)) => { all_sizes.insert(w as usize * 10000 + h as usize); }
                    _ => { }
                }
                match x.get("fps").and_then(|v| v.as_f64()) {
                    Some(fps) => { all_fps.insert((fps * 10000.0).round() as usize); }
                    _ => { }
                }
            }
        }

        let include_size = all_sizes.len() <= 1;
        let include_fps = all_fps.len() <= 1 || (all_fps.len() == 2 && all_fps.into_iter().next().unwrap() >= 200_0000);

        let mut final_name = vec![&self.camera_brand, &self.camera_model].into_iter().filter(|x| !x.is_empty()).join(" ");
        if include_size {
            final_name.push(' ');
            final_name.push_str(primary.get_size_str());
        }
        final_name.push(' ');
        final_name.push_str(&primary.get_aspect_ratio());

        final_name.push(' ');
        final_name.push_str(&Self::cleanup_name(vec![&primary.lens_model, &self.camera_setting, &self.note].into_iter().filter(|x| !x.is_empty()).join(" ")));

        if include_size {
            final_name.push_str(&format!(" {}x{}", primary.calib_dimension.w, primary.calib_dimension.h));
        }
        if include_fps && self.fps > 0.0 {
            final_name.push_str(&format!(" {:.2}fps", self.fps));
        }
        final_name
    }
    pub fn cleanup_name(name: String) -> String {
        name.replace(".json", "")
            .replace("4_3", "")
            .replace("4:3", "")
            .replace("4by3", "")
            .replace("16:9", "")
            .replace("169", "")
            .replace("16_9", "")
            .replace("16*9", "")
            .replace("16/9", "")
            .replace("16by9", "")
            .replace("2_7K", "")
            .replace("2,7K", "")
            .replace("2.7K", "")
            .replace("4K", "")
            .replace("5K", "")
            .replace('_', " ")
    }

    pub fn calculate_optimal_fov(&self, _output_size: (usize, usize)) -> f64 {
        1.0
    }

    pub fn resolve_interpolations(&mut self, db: &crate::lens_profile_database::LensProfileDatabase) {
        for lens in self.lens.iter_mut() {
            lens.resolve_interpolations(db);
        }
    }
}
