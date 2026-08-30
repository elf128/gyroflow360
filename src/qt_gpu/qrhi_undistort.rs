// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2021-2022 Adrian <adrian.eddy at gmail>

use gyroflow_core::{ stabilization::ProcessedInfo, gpu::Buffers };
use qml_video_rs::video_player::MDKPlayerWrapper;
use std::sync::Arc;
use crate::core::StabilizationManager;
use crate::core::stabilization::RGBA8;
use cpp::*;
use qmetaobject::{ QSize, QString, QImage };

cpp! {{
    #include <QJSValue>
    #include <QQuickItem>
    #include <QQuickItemGrabResult>
    #include <QJsonObject>
    #include "src/qt_gpu/viewport_item.cpp"
    #include "src/qt_gpu/qrhi_undistort.cpp"
}}

pub fn render(mdkplayer: &MDKPlayerWrapper, viewport_ptr: usize, timestamp: f64, frame: usize, width: u32, height: u32, stab: Arc<StabilizationManager>, buffers: &mut Buffers) -> Option<ProcessedInfo> {
    if stab.prevent_recompute.load(std::sync::atomic::Ordering::SeqCst) { return None; }

    let mut timestamp_us = (timestamp * 1000.0).round() as i64;
    let mut output_size = QSize::default();
    let mut shader_path = QString::default();
    let mut distortion_model = QString::default();
    let mut digital_lens = QString::default();

    if let Some(p) = stab.params.try_read() {
        output_size = QSize { width: p.output_size.0 as u32, height: p.output_size.1 as u32 };
        {
            let lens = stab.lens.read();
            let dm = lens.distortion_model.as_deref().unwrap_or("opencv_fisheye");
            let dl = lens.digital_lens.as_deref().unwrap_or("");
            let dl_suffix = if dl.is_empty() { String::new() } else { format!("_{}", dl) };
            shader_path      = QString::from(format!(":/src/qt_gpu/compiled/undistort_{}{}.frag.qsb", dm, dl_suffix));
            distortion_model = QString::from(dm);
            digital_lens     = QString::from(dl);
        };

        if let Some(scale) = p.fps_scale {
            timestamp_us = (timestamp_us as f64 / scale).round() as i64;
        }
    }

    if let Some(mut undist) = stab.stabilization.try_write() {
        undist.ensure_stab_data_at_timestamp::<RGBA8>(timestamp_us, Some(frame), buffers, true);
        stab.draw_overlays(&mut undist.drawing, timestamp_us);
    }

    if let Some(undist) = stab.stabilization.try_read() {
        if let Some(itm) = undist.get_undistortion_data(timestamp_us) {
            let params = bytemuck::bytes_of(&itm.kernel_params);
            let params_ptr = params.as_ptr();
            let params_len = params.len() as u32;
            let matrices_ptr = itm.matrices.as_ptr();
            let matrices_len = (itm.matrices.len() * 21 * std::mem::size_of::<f32>()) as u32;
            let canvas = undist.drawing.get_buffer();
            let canvas_ptr = canvas.as_ptr();
            let canvas_len = canvas.len() as u32;
            let mesh_data_ptr = itm.mesh_data.as_ptr();
            let mesh_data_len = itm.mesh_data.len() as u32;

            let size_for_rs = if (itm.kernel_params.flags & 16) == 16 { itm.kernel_params.width } else { itm.kernel_params.height } as u32;

            let canvas_size = undist.drawing.get_size();
            let canvas_size = QSize { width: canvas_size.0 as u32, height: canvas_size.1 as u32 };

            let ok = cpp!(unsafe [mdkplayer as "MDKPlayerWrapper *", viewport_ptr as "uintptr_t", output_size as "QSize", shader_path as "QString", distortion_model as "QString", digital_lens as "QString", width as "uint32_t", height as "uint32_t", params_ptr as "uint8_t*", matrices_ptr as "uint8_t*", canvas_ptr as "uint8_t*", mesh_data_ptr as "float*", mesh_data_len as "uint32_t", matrices_len as "uint32_t", params_len as "uint32_t", canvas_len as "uint32_t", canvas_size as "QSize", size_for_rs as "uint32_t"] -> bool as "bool" {
                if (!mdkplayer || !mdkplayer->mdkplayer || shader_path.isEmpty() || output_size.isEmpty()) return false;

                auto *viewport = reinterpret_cast<GyroflowViewport *>(viewport_ptr);
                // Render target may not be ready yet on the first frame (before the first
                // updatePaintNode completes). Return false to skip this frame.
                if (!viewport || !viewport->renderTarget()) return false;

                auto rhiUndistortion = static_cast<QtRHIUndistort *>(mdkplayer->mdkplayer->userData());

                if (!QFile::exists(shader_path) && !QtRHIUndistort::diskShadersAvailable()) {
                    qDebug2("render") << shader_path << "doesn't exist";
                    delete rhiUndistortion;
                    mdkplayer->mdkplayer->setUserData(nullptr);
                    return false;
                }
                if (output_size.width() < 4 || output_size.height() < 4) {
                    delete rhiUndistortion;
                    mdkplayer->mdkplayer->setUserData(nullptr);
                    return true;
                }

                if (!rhiUndistortion
                || rhiUndistortion->outSize() != output_size
                || rhiUndistortion->texSize() != QSize(width, height)
                || rhiUndistortion->shaderPath() != shader_path
                || rhiUndistortion->sizeForRS() != size_for_rs
                || rhiUndistortion->itemTexturePtr() != mdkplayer->mdkplayer->rhiTexture()
                || rhiUndistortion->externalRT() != viewport->renderTarget()) {
                    delete rhiUndistortion;
                    rhiUndistortion = new QtRHIUndistort();
                    if (!rhiUndistortion->init(mdkplayer->mdkplayer, viewport, QSize(width, height), output_size, shader_path, distortion_model, digital_lens, params_len, size_for_rs, canvas_size)) {
                        qDebug2("render") << "Failed to initialize";
                        delete rhiUndistortion;
                        mdkplayer->mdkplayer->setUserData(nullptr);
                        return false;
                    }
                    qDebug2("render") << "Initialized" << QSize(width, height) << "->" << output_size << shader_path << rhiUndistortion;
                    mdkplayer->mdkplayer->setUserData(static_cast<void *>(rhiUndistortion));
                    mdkplayer->mdkplayer->setUserDataDestructor([](void *ptr) {
                        delete static_cast<QtRHIUndistort *>(ptr);
                    });
                }

                return rhiUndistortion->render(mdkplayer->mdkplayer, params_ptr, params_len, matrices_ptr, matrices_len, canvas_ptr, canvas_len, mesh_data_ptr, mesh_data_len);
            });
            if ok {
                return Some(ProcessedInfo {
                    fov: itm.fov,
                    minimal_fov: itm.minimal_fov,
                    focal_length: itm.focal_length,
                    backend: "Qt RHI"
                });
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Viewport lifecycle helpers — called from controller.rs (no cpp! there).
// ---------------------------------------------------------------------------

/// Create a GyroflowViewport as a C++ child of the given QML container item.
/// Returns the raw pointer as usize (0 on failure).
pub fn create_viewport(container: &qmetaobject::QJSValue) -> usize {
    cpp!(unsafe [container as "QJSValue *"] -> usize as "uintptr_t" {
        QObject *obj = container->toQObject();
        auto *parent = qobject_cast<QQuickItem *>(obj);
        if (!parent) return 0;
        auto *viewport = new GyroflowViewport(parent);
        viewport->setWidth(parent->width());
        viewport->setHeight(parent->height());
        QObject::connect(parent, &QQuickItem::widthChanged,  parent, [viewport, parent]() { viewport->setWidth(parent->width()); });
        QObject::connect(parent, &QQuickItem::heightChanged, parent, [viewport, parent]() { viewport->setHeight(parent->height()); });
        return reinterpret_cast<uintptr_t>(viewport);
    })
}

/// Notify the viewport that the desired output resolution has changed.
/// Safe to call from the main thread; GPU resource recreation is deferred to the render thread.
pub fn set_viewport_output_size(vp_ptr: usize, w: u32, h: u32) {
    if vp_ptr == 0 { return; }
    cpp!(unsafe [vp_ptr as "uintptr_t", w as "uint32_t", h as "uint32_t"] {
        auto *viewport = reinterpret_cast<GyroflowViewport *>(vp_ptr);
        if (viewport) viewport->setOutputSize(QSize(w, h));
    });
}

/// Current allocated size of the viewport's output texture, as (width, height).
/// Returns (0, 0) if the viewport or its GPU resources aren't ready yet (before the
/// first updatePaintNode has run) — callers should skip the frame in that case.
/// Safe to call from the render thread (read-only access to render-thread-owned state).
pub fn viewport_texture_size(vp_ptr: usize) -> (u32, u32) {
    if vp_ptr == 0 { return (0, 0); }
    let size = cpp!(unsafe [vp_ptr as "uintptr_t"] -> QSize as "QSize" {
        auto *viewport = reinterpret_cast<GyroflowViewport *>(vp_ptr);
        if (!viewport || !viewport->outputTexture()) return QSize(0, 0);
        return viewport->outputTexture()->pixelSize();
    });
    (size.width, size.height)
}

/// Native GPU texture handle backing the viewport's output texture — same encoding as
/// MDK's `nativeTexture().object` (GLuint for OpenGL, pointer bit-pattern for Metal/D3D11,
/// VkImage handle for Vulkan). Returns 0 if not ready yet. Must be called on the render
/// thread, after the RHI backend for the window has been established.
pub fn viewport_native_texture(vp_ptr: usize) -> u64 {
    if vp_ptr == 0 { return 0; }
    cpp!(unsafe [vp_ptr as "uintptr_t"] -> u64 as "uint64_t" {
        auto *viewport = reinterpret_cast<GyroflowViewport *>(vp_ptr);
        if (!viewport || !viewport->outputTexture()) return 0;
        return (uint64_t)viewport->outputTexture()->nativeTexture().object;
    })
}

/// Schedule a repaint after writing into the viewport's texture via a native-texture-interop
/// backend (bypassing the RHI render-pass mechanism, so Qt has no other way to know new
/// content landed). Safe to call from the render thread.
pub fn viewport_request_update(vp_ptr: usize) {
    if vp_ptr == 0 { return; }
    cpp!(unsafe [vp_ptr as "uintptr_t"] {
        auto *viewport = reinterpret_cast<GyroflowViewport *>(vp_ptr);
        if (viewport) viewport->update();
    });
}

// ---------------------------------------------------------------------------
// MDK source lifecycle helpers — called from controller.rs.
//
// MDKVideoItem is a headless decoder / texture source, never displayed directly
// (see GyroflowViewport above for what actually gets shown). It used to be declared
// in QML and handed to Rust by reference; now Controller creates and owns it directly,
// the same way it owns the viewport, so QML never touches it.
// ---------------------------------------------------------------------------

/// Create an MDKVideoItem as a C++ child of the given QML container item, entirely from
/// Rust. Ownership of the Rust object is handed to C++ via `into_leaked_cpp_ptr` — from
/// then on, get a typed handle back with `MDKVideoItem::get_from_cpp(ptr)`.
/// Returns the raw QQuickItem* as usize (0 on failure).
pub fn create_mdk_source(container: &qmetaobject::QJSValue) -> usize {
    let item_ptr = qmetaobject::into_leaked_cpp_ptr(qml_video_rs::video_item::MDKVideoItem::default());
    cpp!(unsafe [container as "QJSValue *", item_ptr as "QObject *"] -> usize as "uintptr_t" {
        QObject *obj = container->toQObject();
        auto *parent = qobject_cast<QQuickItem *>(obj);
        if (!parent) return 0;
        auto *item = qobject_cast<QQuickItem *>(item_ptr);
        if (!item) return 0;
        item->setParentItem(parent);
        item->setSize(parent->size());
        QObject::connect(parent, &QQuickItem::widthChanged,  parent, [item, parent]() { item->setWidth(parent->width()); });
        QObject::connect(parent, &QQuickItem::heightChanged, parent, [item, parent]() { item->setHeight(parent->height()); });
        return reinterpret_cast<uintptr_t>(item);
    })
}

/// Wire the MDKVideoItem's own signals directly to the given Controller's `on_video_*` handler
/// methods, via old-style string-based `QObject::connect`. This works because that overload
/// resolves both signal and slot purely via runtime QMetaObject lookup by name — it doesn't
/// require either side's metaobject to have been produced by moc (neither is; both are
/// qmetaobject-rs generated), only that the lookup succeeds, which it does because QML's own
/// native property bindings already rely on the exact same lookup mechanism today.
pub fn wire_video_signals(item_ptr: usize, controller_ptr: usize) {
    if item_ptr == 0 || controller_ptr == 0 { return; }
    cpp!(unsafe [item_ptr as "uintptr_t", controller_ptr as "uintptr_t"] {
        auto *item = reinterpret_cast<QObject *>(item_ptr);
        auto *ctrl = reinterpret_cast<QObject *>(controller_ptr);
        QObject::connect(item, SIGNAL(metadataLoaded(QJsonObject)), ctrl, SLOT(on_video_metadata_loaded(QJsonObject)));
        QObject::connect(item, SIGNAL(metadataChanged()),            ctrl, SLOT(on_video_metadata_changed()));
        QObject::connect(item, SIGNAL(currentFrameChanged()),        ctrl, SLOT(on_video_current_frame_changed()));
        QObject::connect(item, SIGNAL(timestampChanged()),           ctrl, SLOT(on_video_timestamp_changed()));
        QObject::connect(item, SIGNAL(playingChanged()),             ctrl, SLOT(on_video_playing_changed()));
        QObject::connect(item, SIGNAL(mutedChanged()),                ctrl, SLOT(on_video_muted_changed()));
    });
}

/// Destroy a previously-created MDK source. `QQuickItem::deleteLater()` triggers Qt Quick's
/// normal item-destruction path (`releaseResources()` → `MDKPlayer::destroyPlayer()`), so the
/// underlying decoder is torn down the same way it would be for a QML-owned item going away.
/// Safe to call from any thread with a running event loop.
pub fn destroy_mdk_source(item_ptr: usize) {
    if item_ptr == 0 { return; }
    cpp!(unsafe [item_ptr as "uintptr_t"] {
        auto *item = reinterpret_cast<QQuickItem *>(item_ptr);
        if (item) {
            item->setParentItem(nullptr);
            item->deleteLater();
        }
    });
}

/// Grabs the current contents of `item_ptr` as an offscreen render (works regardless of the
/// item's `visible` state — it's a separate render pass, not a copy of the composited scene),
/// base64-encodes it, and invokes `callback(b64: string)` once ready. Thin wrapper around
/// `QQuickItem::grabToImage`, kept as a real Qt async API rather than reimplemented — the
/// callback is invoked directly in C++ (QJSValue is an implicitly-shared value type, safe to
/// copy into the completion lambda) so no Rust-side closure/ownership plumbing is needed.
/// target_w/target_h <= 0 means "use the item's own native size" (matches QQuickItem's own
/// grabToImage default of an invalid/empty QSize), rather than requesting a literal 0x0 grab.
pub fn grab_item_image_b64(item_ptr: usize, target_w: f64, target_h: f64, callback: &qmetaobject::QJSValue) {
    if item_ptr == 0 { return; }
    cpp!(unsafe [item_ptr as "uintptr_t", target_w as "double", target_h as "double", callback as "QJSValue *"] {
        auto *item = reinterpret_cast<QQuickItem *>(item_ptr);
        if (!item) return;
        QSize targetSize = (target_w > 0 && target_h > 0) ? QSize(target_w, target_h) : QSize();
        auto grabResult = item->grabToImage(targetSize);
        if (!grabResult) return;
        QJSValue cb = *callback;
        QObject::connect(grabResult.data(), &QQuickItemGrabResult::ready, [grabResult, cb]() mutable {
            QImage img = grabResult->image();
            QString b64 = rust!(Rust_grab_item_image_b64 [img: QImage as "QImage"] -> QString as "QString" {
                // rust! captures img by value but the cpp! macro's own generated glue still
                // needs it afterward (to drop the C++-side handle correctly) — image_to_b64
                // takes it by value, so clone rather than move. QImage is implicitly-shared
                // (copy-on-write), so this is a cheap refcount bump, not a pixel copy.
                crate::util::image_to_b64(img.clone())
            });
            cb.call(QJSValueList() << b64);
        });
    });
}
