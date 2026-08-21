// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2024

use ffmpeg_next::{ codec, format, frame, media, software::scaling };

pub struct SecondaryVideoSource {
    input:        format::context::Input,
    decoder:      codec::decoder::Video,
    stream_index: usize,
}

impl SecondaryVideoSource {
    pub fn open(path: &str) -> Result<Self, ffmpeg_next::Error> {
        let input = format::input(&path)?;
        let stream = input.streams().best(media::Type::Video)
            .ok_or(ffmpeg_next::Error::StreamNotFound)?;
        let stream_index = stream.index();
        let decoder = codec::context::Context::from_parameters(stream.parameters())?
            .decoder()
            .video()?;
        Ok(Self { input, decoder, stream_index })
    }

    /// Decode and return the next video frame. Returns None at EOF.
    pub fn next_frame(&mut self) -> Option<frame::Video> {
        loop {
            let mut frame = frame::Video::empty();
            if self.decoder.receive_frame(&mut frame).is_ok() {
                return Some(frame);
            }
            // Feed more packets until we get a frame or hit EOF
            let (stream, packet) = self.input.packets().find(|(s, _)| s.index() == self.stream_index)?;
            let _ = stream; // suppress unused warning
            if self.decoder.send_packet(&packet).is_err() {
                return None;
            }
        }
    }

    /// Seek to the closest keyframe at or before `timestamp_us` (AV_TIME_BASE = µs), then flush.
    pub fn seek_to_us(&mut self, timestamp_us: i64) -> bool {
        // ffmpeg_next expects timestamps in AV_TIME_BASE (= 1 000 000 ticks / second = µs).
        let ok = self.input.seek(timestamp_us, ..timestamp_us).is_ok();
        self.decoder.flush();
        ok
    }

    /// Decode the next frame and return it scaled to `(target_w, target_h)` as packed RGBA8.
    pub fn next_frame_as_rgba8(&mut self, target_w: u32, target_h: u32) -> Option<Vec<u8>> {
        let frame = self.next_frame()?;
        let mut scaler = scaling::Context::get(
            frame.format(), frame.width(), frame.height(),
            format::Pixel::RGBA, target_w, target_h,
            scaling::Flags::BILINEAR,
        ).ok()?;
        let mut rgba = frame::Video::empty();
        scaler.run(&frame, &mut rgba).ok()?;
        Some(rgba.data(0).to_vec())
    }

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
