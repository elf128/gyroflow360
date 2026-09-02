// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2024

/// Namespace for deriving a dual-lens camera's secondary file path from its primary file's
/// path. The secondary file itself is loaded and decoded through a real MDKVideoItem now
/// (see Controller::load_secondary_video/init_video_source) - this module only ever answers
/// "what path should that be", never touches a decoder.
pub struct SecondaryVideoSource;

impl SecondaryVideoSource {
    /// Derive the secondary file path from the primary using camera-aware rules.
    /// Tries each rule in order and returns the first path that exists on disk.
    pub fn pair_path(primary: &str) -> Option<String> {
        // Strip file:// prefix if present
        let path = primary.strip_prefix("file://").unwrap_or(primary);

        for candidate in Self::pair_candidates(path) {
            if std::path::Path::new(&candidate).exists() {
                return Some(candidate);
            }
        }
        None
    }

    fn pair_candidates(path: &str) -> Vec<String> {
        let mut candidates = Vec::new();

        // Rule 1 — Insta360: replace stream id segment _00_ → _10_ (or _10_ → _00_)
        // Pattern: VID_..._00_NNN.insv  ↔  VID_..._10_NNN.insv
        if path.to_lowercase().ends_with(".insv") {
            if let Some(c) = Self::replace_segment(path, "_00_", "_10_") { candidates.push(c); }
            if let Some(c) = Self::replace_segment(path, "_10_", "_00_") { candidates.push(c); }
        }

        // Rule 2 — GoPro MAX / dual-lens rigs: increment first digit run in filename stem
        // GS010001.MP4 → GS020001.MP4
        if let Some(c) = Self::increment_first_digit_run(path) {
            candidates.push(c);
        }

        candidates
    }

    /// Replace the last occurrence of `from` in the filename (not the directory part).
    fn replace_segment(path: &str, from: &str, to: &str) -> Option<String> {
        let p = std::path::Path::new(path);
        let filename = p.file_name()?.to_str()?;
        // Find last occurrence to avoid touching directory components
        let pos = filename.rfind(from)?;
        let new_filename = format!("{}{}{}", &filename[..pos], to, &filename[pos + from.len()..]);
        Some(p.with_file_name(new_filename).to_str()?.to_owned())
    }

    /// Increment the first contiguous run of decimal digits in the filename stem.
    fn increment_first_digit_run(path: &str) -> Option<String> {
        let p = std::path::Path::new(path);
        let filename = p.file_name()?.to_str()?;
        let start = filename.find(|c: char| c.is_ascii_digit())?;
        let end   = start + filename[start..].find(|c: char| !c.is_ascii_digit()).unwrap_or(filename[start..].len());
        let num: u64 = filename[start..end].parse().ok()?;
        let width = end - start;
        let new_num = format!("{:0>width$}", num + 1, width = width);
        let new_filename = format!("{}{}{}", &filename[..start], new_num, &filename[end..]);
        Some(p.with_file_name(new_filename).to_str()?.to_owned())
    }
}
