// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2024 Gyroflow contributors

#include <QQuickItem>
#include <QQuickWindow>
#include <QSGImageNode>
#include <QSGDynamicTexture>

#if QT_VERSION >= QT_VERSION_CHECK(6, 6, 0)
#   include <rhi/qrhi.h>
#else
#   include <private/qrhi_p.h>
#endif
#include <private/qquickwindow_p.h>

// ---------------------------------------------------------------------------
// GyroflowSGTexture — wraps an external QRhiTexture as a QSGTexture.
//
// Qt 6.4's scene graph nodes call rhiTexture() when binding textures. By
// overriding it here we can display any QRhiTexture without the 6.6+
// QQuickWindow::createTextureFromRhiTexture() API.
// ---------------------------------------------------------------------------
class GyroflowSGTexture : public QSGDynamicTexture {
public:
    GyroflowSGTexture(QRhiTexture *tex, QSize size) : m_tex(tex), m_size(size) {
        setFiltering(QSGTexture::Linear);
    }

    bool updateTexture() override { return false; }
    QSize textureSize() const override { return m_size; }
    bool hasAlphaChannel() const override { return false; }
    bool hasMipmaps() const override { return false; }
    qint64 comparisonKey() const override { return (qint64)(quintptr)m_tex; }
    QRhiTexture *rhiTexture() const override { return m_tex; }

private:
    QRhiTexture *m_tex; // not owned — owned by GyroflowViewport
    QSize m_size;
};

// ---------------------------------------------------------------------------
// GyroflowViewport — a QQuickItem that owns the output texture + render target
// and displays it via a QSGImageNode.
//
// No Q_OBJECT: no signals, no QML type registration, no MOC required.
// Created programmatically from C++ (via Rust cpp! block). The controller
// parents it to a plain QML Item container and drives output size changes.
//
// Threading:
//   setOutputSize() — called from QML thread, sets m_dirty + schedules update
//   updatePaintNode() — render thread (sync phase), creates/recreates GPU resources
//   renderTarget() — called from render thread (processTexture), after resources exist
// ---------------------------------------------------------------------------
class GyroflowViewport : public QQuickItem {
public:
    explicit GyroflowViewport(QQuickItem *parent = nullptr) : QQuickItem(parent) {
        setFlag(ItemHasContents, true);
    }

    // Call from QML thread when the desired output resolution changes.
    void setOutputSize(QSize size) {
        if (m_outputSize == size) return;
        m_outputSize = size;
        m_dirty = true;
        update();
    }

    QSize outputSize() const { return m_outputSize; }

    // Accessed from the render thread (processTexture callback) after the first
    // updatePaintNode has run. Returns null until resources are initialised.
    QRhiTextureRenderTarget  *renderTarget()          const { return m_rt.get(); }
    QRhiRenderPassDescriptor *renderPassDescriptor()  const { return m_rtRp.get(); }

    // The texture backing renderTarget(). Exposed so a native-texture-interop backend
    // (pipeline 1, "Zero-copy OpenCL") can write into it directly, bypassing the RHI
    // render-pass mechanism entirely. Same lifetime/thread rules as renderTarget().
    // Caller must still call the inherited update() after writing, to schedule a repaint
    // (safe to call from the render thread).
    QRhiTexture *outputTexture() const { return m_tex.get(); }

protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override {
        if (m_dirty && !m_outputSize.isEmpty()) {
            auto *rhi = QQuickWindowPrivate::get(window())->rhi;
            if (rhi) {
                // GyroflowSGTexture holds a raw pointer into m_tex; destroy it first.
                delete m_sgTex; m_sgTex = nullptr;
                m_rt.reset();
                m_rtRp.reset();
                m_tex.reset();

                m_tex.reset(rhi->newTexture(QRhiTexture::RGBA8, m_outputSize, 1,
                                            QRhiTexture::RenderTarget | QRhiTexture::UsedAsTransferSource));
                if (m_tex->create()) {
                    m_rt.reset(rhi->newTextureRenderTarget({ QRhiColorAttachment(m_tex.get()) }));
                    m_rtRp.reset(m_rt->newCompatibleRenderPassDescriptor());
                    m_rt->setRenderPassDescriptor(m_rtRp.get());
                    if (m_rt->create()) {
                        m_sgTex = new GyroflowSGTexture(m_tex.get(), m_outputSize);
                        m_dirty = false;
                    } else {
                        qWarning("[GyroflowViewport] Failed to create render target");
                        m_rt.reset(); m_rtRp.reset(); m_tex.reset();
                    }
                } else {
                    qWarning("[GyroflowViewport] Failed to create output texture %dx%d",
                             m_outputSize.width(), m_outputSize.height());
                    m_tex.reset();
                }
            }
        }

        // Never return an untextured node — Qt's batch renderer calls
        // QSGOpaqueTextureMaterial::compare() which reads the texture pointer and
        // crashes with SIGSEGV if it is NULL.
        if (!m_sgTex) {
            delete static_cast<QSGImageNode *>(old);
            return nullptr;
        }

        QSGImageNode *node = static_cast<QSGImageNode *>(old);
        if (!node)
            node = window()->createImageNode();
        node->setOwnsTexture(false);
        node->setTexture(m_sgTex);
        node->setRect(boundingRect());
        node->setFiltering(QSGTexture::Linear);
        node->setTextureCoordinatesTransform(QSGImageNode::MirrorVertically);
        return node;
    }

    void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override {
        QQuickItem::geometryChange(newGeometry, oldGeometry);
        if (newGeometry.size() != oldGeometry.size())
            update();
    }

    void releaseResources() override {
        // Called on the render thread when the window is about to be destroyed.
        delete m_sgTex; m_sgTex = nullptr;
        m_rt.reset();
        m_rtRp.reset();
        m_tex.reset();
    }

private:
    QSize m_outputSize;
    bool  m_dirty = true;

    QScopedPointer<QRhiTexture>              m_tex;
    QScopedPointer<QRhiTextureRenderTarget>  m_rt;
    QScopedPointer<QRhiRenderPassDescriptor> m_rtRp;
    GyroflowSGTexture *m_sgTex = nullptr;
};
