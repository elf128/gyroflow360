// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2024

use parking_lot::Mutex;

/// A lens's decoded frame, captured from whichever callback MDK invoked for it.
///
/// Both the GPU texture (onProcessTexture) and CPU buffer (onProcessPixels) that
/// MDK hands back are persistent, reused storage owned by that lens's own
/// MDKPlayer - the same texture/buffer object every tick, with contents simply
/// overwritten in place for whatever frame was just decoded (verified against
/// qml-video-rs's VideoTextureNode.cpp: m_texture and m_readbackResult are both
/// created once and reused). So nothing here is copied to guard against the
/// source going stale - it stays valid until that lens's next tick either way.
///
/// What *is* captured is call-scoped data that only exists as arguments to that
/// one callback invocation, with no way to re-derive it afterwards:
/// - `Texture`: `backend_id`/`ptr1..ptr5` aren't stored anywhere on the MDK side -
///   they're computed fresh each tick from the window's RHI resource interface
///   and hand to the callback as plain arguments. Cheap `Copy` data, no allocation.
/// - `Buffer`: the `&mut [u8]` MDK hands over is a borrow valid only for that one
///   call, even though the memory it points to is persistent - Rust won't let it
///   be soundly retained past that call, so it's copied once here (same cost the
///   old ffmpeg-based secondary source already paid for the same reason).
#[derive(Clone, Debug)]
pub enum LensFrame {
    Texture { backend_id: u32, ptr1: u64, ptr2: u64, ptr3: u64, ptr4: u64, ptr5: u64, width: u32, height: u32 },
    Buffer { data: Vec<u8>, width: u32, height: u32, stride: u32 },
}

/// Identifies which processing pipeline is asking - each has its own notion of
/// "have I already handled this frame index", since a texture-pipeline consumer
/// and a buffer-pipeline consumer run independently of one another.
#[derive(Clone, Copy)]
pub enum Consumer {
    Texture = 0,
    Buffer = 1,
}

#[derive(Default)]
struct LensSlot {
    frame_idx: Option<i64>,
    frame: Option<LensFrame>,
}

/// Per-lens latch of "the most recently reported decoded frame". Written by each
/// lens's own onProcessTexture/onProcessPixels callback (see Controller::init_video_source),
/// read by whatever consumes frames for rendering. Two lenses only, indexed 0/1 -
/// mirrors the rest of the dual-lens pipeline's two-lens-only scope.
///
/// Both lenses' callbacks run the same unified consumer step every tick (see
/// init_video_source), so `try_consume` exists to make that idempotent: whichever
/// of the two callbacks fires second in a tick would otherwise redo the same
/// render/process work the first one just did.
#[derive(Default)]
pub struct DualLensFrameSync {
    slots: [Mutex<LensSlot>; 2],
    last_consumed: [Mutex<Option<i64>>; 2],
}

impl DualLensFrameSync {
    pub fn submit(&self, lens: usize, frame_idx: i64, frame: LensFrame) {
        let mut slot = self.slots[lens].lock();
        slot.frame_idx = Some(frame_idx);
        slot.frame = Some(frame);
    }

    /// The most recently reported (frame_idx, frame) for a single lens, if any.
    pub fn latest(&self, lens: usize) -> Option<(i64, LensFrame)> {
        let slot = self.slots[lens].lock();
        match (slot.frame_idx, &slot.frame) {
            (Some(idx), Some(frame)) => Some((idx, frame.clone())),
            _ => None,
        }
    }

    /// Just the most recently reported frame index for a single lens, if any -
    /// cheaper than `latest` when the frame payload itself isn't needed.
    pub fn latest_frame_idx(&self, lens: usize) -> Option<i64> {
        self.slots[lens].lock().frame_idx
    }

    /// The frame index both lenses currently agree on, if any.
    pub fn ready_frame(&self) -> Option<i64> {
        let a = self.latest_frame_idx(0)?;
        let b = self.latest_frame_idx(1)?;
        if a == b { Some(a) } else { None }
    }

    /// True the first time it's called for a given (consumer, frame_idx) pair;
    /// false on any repeat, so a consumer triggered from both lenses' callbacks
    /// in the same tick only actually does its work once.
    pub fn try_consume(&self, consumer: Consumer, frame_idx: i64) -> bool {
        let mut last = self.last_consumed[consumer as usize].lock();
        if *last == Some(frame_idx) { return false; }
        *last = Some(frame_idx);
        true
    }
}
