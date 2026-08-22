// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2021-2022 Adrian <adrian.eddy at gmail>

#include <QQuickWindow>
#include <QFile>
#include <QDir>
#include <QDateTime>
#include <QFileInfo>
#include <QProcess>
#include <QCoreApplication>
#include <QStandardPaths>
#include <atomic>
#include <mutex>
#include <thread>
#include <chrono>
#include <private/qquickitem_p.h>
#if QT_VERSION >= QT_VERSION_CHECK(6, 6, 0)
#   include <rhi/qrhi.h>
#else
#   include <private/qrhi_p.h>
#endif
#include <private/qsgrenderer_p.h>
#include <private/qsgdefaultrendercontext_p.h>
#include <private/qshader_p.h>

#define qDebug2(func) QMessageLogger(__FILE__, __LINE__, func).debug(QLoggingCategory("Qt RHI"))
#define qWarn2(func)  QMessageLogger(__FILE__, __LINE__, func).warning(QLoggingCategory("Qt RHI"))

class MDKPlayer {
public:
    QSGDefaultRenderContext *rhiContext();
    QRhiTexture *rhiTexture();
    // QRhiTextureRenderTarget *rhiRenderTarget();
    // QRhiRenderPassDescriptor *rhiRenderPassDescriptor();
    QQuickWindow *qmlWindow();
    QQuickItem *qmlItem();
    QSize textureSize();
    QMatrix4x4 textureMatrix();

    void *userData() const;
    void setUserData(void *);
    void setUserDataDestructor(std::function<void(void *)> &&cb);
};
class MDKPlayerWrapper {
public:
    MDKPlayer *mdkplayer;
};

// Watcher thread deposits pre-compiled shaders here; init() picks them up.
// Static so it survives the delete+new cycle in the Rust render callback.
struct PendingShaders { QShader vert; QShader frag; };
static std::mutex s_pendingMu;
static PendingShaders s_pending;

static float quadVertexData[16] = { // Y up, CCW
    -0.5f,  0.5f, 0.0f, 0.0f,
    -0.5f, -0.5f, 0.0f, 1.0f,
    0.5f, -0.5f, 1.0f, 1.0f,
    0.5f,  0.5f, 1.0f, 0.0f
};
static quint16 quadIndexData[6] = { 0, 1, 2, 0, 2, 3 };

// ubufAlignment
// static inline uint aligned(uint v, uint byteAlign) { return (v + byteAlign - 1) & ~(byteAlign - 1); }

class QtRHIUndistort {
public:
    QtRHIUndistort() { }
    ~QtRHIUndistort() { stopWatcher(); }

    QSize outSize() { return m_outputSize; }
    QSize texSize() { return m_textureSize; }
    QString shaderPath() { return m_shaderPath; }
    QRhiTexture *itemTexturePtr() { return m_itemTexturePtr; }
    unsigned int sizeForRS() { return m_sizeForRS; }
    QRhiTextureRenderTarget *externalRT() { return m_externalRT; }

    bool sourcesChanged() const {
        return m_filesChanged.exchange(false);
    }

    void stopWatcher() {
        m_watcherStop.store(true);
        if (m_watcherThread.joinable())
            m_watcherThread.join();
        if (m_beforeRenderingConn)
            QObject::disconnect(m_beforeRenderingConn);
        m_beforeRenderingConn = {};
    }

    void startWatcher() {
        stopWatcher();
        if (m_watchedSourcePaths.isEmpty()) return;

        QQuickWindow *window = m_item ? m_item->qmlWindow() : nullptr;

        // Connect to beforeRendering (render thread, fires every scene graph frame,
        // even when video is paused) so reinit() is triggered without needing MDK
        // to produce a new video frame.
        if (window) {
            m_beforeRenderingConn = QObject::connect(
                window, &QQuickWindow::beforeRendering, window,
                [this]() {
                    if (m_filesChanged.exchange(false))
                        reinit();
                },
                Qt::DirectConnection
            );
        }

        QStringList paths = m_watchedSourcePaths;
        QList<QDateTime> mtimes = m_watchedSourceMtimes;

        m_watcherStop.store(false);
        m_watcherThread = std::thread([this, paths, mtimes, window]() mutable {
            while (!m_watcherStop.load()) {
                // Sleep in 25 ms ticks so join latency is at most 25 ms
                for (int t = 0; t < 10 && !m_watcherStop.load(); ++t)
                    std::this_thread::sleep_for(std::chrono::milliseconds(25));
                if (m_watcherStop.load()) break;

                bool anyChanged = false;
                for (int i = 0; i < paths.size(); ++i) {
                    QDateTime cur = QFileInfo(paths[i]).lastModified();
                    if (cur != mtimes[i]) {
                        mtimes[i] = cur;
                        qWarning("[Qt RHI] File updated: %s", paths[i].toUtf8().constData());
                        anyChanged = true;
                    }
                }

                if (anyChanged) {
                    const QString base = repoBasePath();
                    if (!findQsbBinary().isEmpty()) {
                        QShader newVert = compileSingleShader(
                            base + "src/qt_gpu/texture.vert",
                            QDir::tempPath() + "/gyroflow_texture.vert.qsb"
                        );
                        QShader newFrag = compileShaderFromSource();
                        {
                            std::lock_guard<std::mutex> lock(s_pendingMu);
                            s_pending.vert = newVert;
                            s_pending.frag = newFrag;
                        }
                    }
                    m_filesChanged.store(true);
                    // Kick the scene graph so beforeRendering fires and reinit() runs
                    if (window)
                        QMetaObject::invokeMethod(window, [window]{ window->update(); }, Qt::QueuedConnection);
                }
            }
        });
    }

    // Recreate only the graphics pipeline with freshly compiled shaders.
    // Called from the beforeRendering handler (render thread) so RHI operations are valid.
    // All other RHI resources (textures, buffers, SRB) are reused unchanged.
    void reinit() {
        if (!m_item || !m_srb || !m_externalRT) return;
        auto context = m_item->rhiContext();
        if (!context) return;
        auto rhi = context->rhi();
        if (!rhi) return;

        QShader vertShader, fragShader;
        {
            std::lock_guard<std::mutex> lock(s_pendingMu);
            if (s_pending.vert.isValid() && s_pending.frag.isValid()) {
                vertShader = std::move(s_pending.vert);
                fragShader = std::move(s_pending.frag);
                s_pending.vert = QShader();
                s_pending.frag = QShader();
            }
        }
        if (!vertShader.isValid() || !fragShader.isValid()) {
            if (!diskShadersAvailable()) {
                qWarn2("reinit") << "Shader sources not available for hot-reload";
                return;
            }
            const QString base = repoBasePath();
            if (!vertShader.isValid())
                vertShader = compileSingleShader(base + "src/qt_gpu/texture.vert",
                                                 QDir::tempPath() + "/gyroflow_texture.vert.qsb");
            if (!fragShader.isValid())
                fragShader = compileShaderFromSource();
        }
        if (!vertShader.isValid() || !fragShader.isValid()) {
            if (!vertShader.isValid()) qWarn2("reinit") << "Vertex shader invalid — black screen";
            if (!fragShader.isValid()) qWarn2("reinit") << "Fragment shader invalid — black screen";
            m_pipeline.reset(); // null pipeline → render() returns false → black screen
            return;
        }

        QScopedPointer<QRhiGraphicsPipeline> newPipeline(rhi->newGraphicsPipeline());
        newPipeline->setShaderStages({
            { QRhiShaderStage::Vertex,   vertShader },
            { QRhiShaderStage::Fragment, fragShader }
        });
        QRhiVertexInputLayout inputLayout;
        inputLayout.setBindings({ { 4 * sizeof(float) } });
        inputLayout.setAttributes({
            { 0, 0, QRhiVertexInputAttribute::Float2, 0 },
            { 0, 1, QRhiVertexInputAttribute::Float2, 2 * sizeof(float) }
        });
        newPipeline->setVertexInputLayout(inputLayout);
        newPipeline->setShaderResourceBindings(m_srb.get());
        newPipeline->setRenderPassDescriptor(m_externalRTRP);
        if (!newPipeline->create()) {
            qWarn2("reinit") << "Pipeline creation failed during hot-reload — black screen";
            m_pipeline.reset(); // null pipeline → render() returns false → black screen
            return;
        }

        m_pipeline.reset(newPipeline.take());
        qDebug2("reinit") << "Hot-reload: pipeline swapped successfully";

        // Re-draw immediately using the already-uploaded GPU buffers.
        // We are on the render thread inside beforeRendering, so the command buffer is
        // valid. MDK won't call render() itself when video is paused, so we do it here.
        rerender();
    }

    // Re-run the draw + copy commands using whatever is already in the GPU-side buffers.
    // Safe to call from the render thread (e.g. from beforeRendering / reinit()).
    // Does NOT call rhi->finish() — the scene graph submits everything at endFrame.
    void rerender() {
        if (!m_item || !m_pipeline || !m_hadFirstRender) return;
        auto context = m_item->rhiContext();
        if (!context) return;
        auto rhi = context->rhi();
        QRhiCommandBuffer *cb = context->currentFrameCommandBuffer();
        if (!rhi || !cb) return;

        QRhiResourceUpdateBatch *u = rhi->nextResourceUpdateBatch();
        if (m_initialUpdates) {
            u->merge(m_initialUpdates);
            m_initialUpdates->release();
            m_initialUpdates = nullptr;
        }
        QMatrix4x4 mvp = m_item->textureMatrix();
        mvp.scale(2.0f);
        u->updateDynamicBuffer(m_drawingUniform.get(), 0, 64, mvp.constData());

        cb->beginPass(m_externalRT, QColor(Qt::black), { 1.0f, 0 }, u);
        cb->setGraphicsPipeline(m_pipeline.get());
        cb->setViewport({ 0, 0, float(m_outputSize.width()), float(m_outputSize.height()) });
        cb->setShaderResources();
        QRhiCommandBuffer::VertexInput vbufBinding(m_vertexBuffer.get(), 0);
        cb->setVertexInput(0, 1, &vbufBinding, m_indexBuffer.get(), 0, QRhiCommandBuffer::IndexUInt16);
        cb->drawIndexed(6);
        cb->endPass();
    }

    // binary: {repo}/target/{release|debug}/gyroflow  →  repo root is ../../
    static QString repoBasePath() {
        return QDir::cleanPath(QCoreApplication::applicationDirPath() + "/../../") + "/";
    }

    static QString findQsbBinary() {
        // PATH already contains the Qt bin dir when launched via `just run`
        QString fromPath = QStandardPaths::findExecutable("qsb");
        if (!fromPath.isEmpty()) return fromPath;
        // Fallback: hardcoded location for common Qt installations in ext/
        const QString base = repoBasePath();
        const QStringList candidates = {
            base + "ext/6.4.3/gcc_64/bin/qsb",
            base + "ext/6.7.3/gcc_64/bin/qsb",
            "/usr/lib/qt6/bin/qsb",
            "/usr/bin/qsb",
        };
        for (const QString &c : candidates)
            if (QFile::exists(c)) return c;
        return QString();
    }

    static bool diskShadersAvailable() {
        const QString base = repoBasePath();
        bool hasFrag = QFile::exists(base + "src/qt_gpu/undistort.frag");
        bool hasQsb  = !findQsbBinary().isEmpty();
        if (!hasFrag || !hasQsb)
            qWarn2("compile") << "disk shaders unavailable: hasFrag=" << hasFrag << "hasQsb=" << hasQsb << "base=" << base;
        return hasFrag && hasQsb;
    }

    // Pure compile: run qsb on srcPath, write to tmpQsb, return the loaded QShader.
    // Does not touch the watch list — call from init() or watcher thread.
    QShader compileSingleShader(const QString &srcPath, const QString &tmpQsb) {
        const QString qsbBin = findQsbBinary();

        QProcess proc;
        proc.start(qsbBin, {
            "--glsl", "120,300 es,310 es,320 es,310,320,330,400,410,420",
            "--hlsl", "50",
            "--msl",  "12",
            "-o", tmpQsb,
            srcPath
        });
        if (!proc.waitForFinished(15000)) {
            qWarn2("compile") << "qsb timed out for" << srcPath;
            return QShader();
        }
        if (proc.exitCode() != 0) {
            qWarn2("compile") << "qsb error for" << srcPath << ":\n" << proc.readAllStandardError().constData();
            return QShader();
        }

        qDebug2("compile") << "Compiled" << srcPath << "->" << tmpQsb;
        return getShader(tmpQsb);
    }

    // Reads undistort.frag + model GLSL from disk, substitutes LENS_MODEL_FUNCTIONS;,
    // runs qsb, returns the compiled QShader.
    // Pure: does not touch the watch list. Safe to call from watcher thread.
    QShader compileShaderFromSource() {
        const QString base       = repoBasePath();
        const QString tmplPath   = base + "src/qt_gpu/undistort.frag";
        const QString modelPath  = base + "src/core/stabilization/distortion_models/" + m_distortionModel + ".glsl";
        const QString qsbBin     = findQsbBinary();

        QFile tf(tmplPath);
        if (!tf.open(QIODevice::ReadOnly)) {
            qWarn2("compile") << "Cannot open shader template:" << tmplPath;
            return QShader();
        }
        QString shader = QString::fromUtf8(tf.readAll());
        tf.close();

        // Build the LENS_MODEL_FUNCTIONS replacement, mirroring compile_shaders.sh logic.
        QString funcs;

        if (m_digitalLens.isEmpty()) {
            funcs += "vec2 digital_undistort_point(vec2 uv) { return uv; } "
                     "vec2 digital_distort_point(vec2 uv) { return uv; } ";
        } else {
            const QString dlPath = base + "src/core/stabilization/distortion_models/" + m_digitalLens + ".glsl";
            QFile dlf(dlPath);
            if (dlf.open(QIODevice::ReadOnly)) {
                funcs += QString::fromUtf8(dlf.readAll()) + " ";
            } else {
                qWarn2("compile") << "Cannot open digital lens GLSL:" << dlPath;
            }
        }

        // process_coord stub — only sony and generic_polynomial define their own.
        if (m_distortionModel != "sony" && m_distortionModel != "generic_polynomial") {
            funcs += "vec2 process_coord(vec2 uv, float idx) { return uv; } ";
        }

        QFile mf(modelPath);
        if (!mf.open(QIODevice::ReadOnly)) {
            qWarn2("compile") << "Cannot open model GLSL:" << modelPath;
            return QShader();
        }
        funcs += QString::fromUtf8(mf.readAll());
        mf.close();

        // get_mesh_data helper — only for models that use the mesh texture.
        if (m_distortionModel == "sony" || m_distortionModel == "generic_polynomial") {
            funcs += " float get_mesh_data(int idx) { return texture(texMeshData, vec2(0, idx / 1023.0)).r; } ";
        }

        shader.replace("LENS_MODEL_FUNCTIONS;", funcs);

        const QString tmpFrag = QDir::tempPath() + "/gyroflow_undistort.frag";
        const QString tmpQsb  = QDir::tempPath() + "/gyroflow_undistort.frag.qsb";

        {
            QFile out(tmpFrag);
            if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
                qWarn2("compile") << "Cannot write temp frag:" << tmpFrag;
                return QShader();
            }
            out.write(shader.toUtf8());
        }

        QProcess proc;
        proc.start(qsbBin, {
            "--glsl", "120,300 es,310 es,320 es,310,320,330,400,410,420",
            "--hlsl", "50",
            "--msl",  "12",
            "-o", tmpQsb,
            tmpFrag
        });
        if (!proc.waitForFinished(15000)) {
            qWarn2("compile") << "qsb timed out";
            return QShader();
        }
        if (proc.exitCode() != 0) {
            qWarn2("compile") << "qsb error:\n" << proc.readAllStandardError().constData();
            return QShader();
        }

        qDebug2("compile") << "Compiled" << m_distortionModel
                           << (m_digitalLens.isEmpty() ? QString() : "+" + m_digitalLens)
                           << "->" << tmpQsb;
        return getShader(tmpQsb);
    }

    bool init(MDKPlayer *item, GyroflowViewport *viewport, QSize textureSize, QSize outputSize, const QString &shaderPath,
              const QString &distortionModel, const QString &digitalLens,
              int kernelParmsSize, unsigned int sizeForRS, QSize canvasSize) {
        if (!item || !viewport) return false;
        auto context = item->rhiContext();
        auto rhi = context->rhi();

        m_item = item;
        m_sizeForRS = sizeForRS;
        m_outputSize = outputSize;
        m_textureSize = textureSize;
        m_shaderPath = shaderPath;
        m_itemTexturePtr = item->rhiTexture();
        m_distortionModel = distortionModel;
        m_digitalLens = digitalLens;
        m_kernelParmsSize = kernelParmsSize;
        m_canvasSize = canvasSize;
        m_externalRT   = viewport->renderTarget();
        m_externalRTRP = viewport->renderPassDescriptor();
        m_watchedSourcePaths.clear();
        m_watchedSourceMtimes.clear();
        stopWatcher();

        // Populate watch list now, before any compilation attempt, so the watcher
        // detects file changes even if the first compile fails.
        const QString base = repoBasePath();
        auto addToWatch = [&](const QString &p) {
            m_watchedSourcePaths << p;
            m_watchedSourceMtimes << QFileInfo(p).lastModified();
        };
        addToWatch(base + "src/qt_gpu/texture.vert");
        addToWatch(base + "src/qt_gpu/undistort.frag");
        addToWatch(base + "src/core/stabilization/distortion_models/" + distortionModel + ".glsl");
        if (!digitalLens.isEmpty())
            addToWatch(base + "src/core/stabilization/distortion_models/" + digitalLens + ".glsl");

        if (!m_externalRT || !m_externalRTRP) { qDebug2("init") << "viewport render target not ready"; return false; }

        m_kernelParams.reset(rhi->newBuffer(QRhiBuffer::Dynamic, QRhiBuffer::UniformBuffer, kernelParmsSize));
        if (!m_kernelParams->create()) { qDebug2("init") << "failed to create m_kernelParams"; return false; }

        m_texMatrices.reset(rhi->newTexture(QRhiTexture::R32F, QSize(21, sizeForRS), 1, QRhiTexture::Flags()));
        if (!m_texMatrices->create()) { qDebug2("init") << "failed to create m_texMatrices"; return false; }

        m_texMeshData.reset(rhi->newTexture(QRhiTexture::R32F, QSize(1, 1024), 1, QRhiTexture::Flags()));
        if (!m_texMeshData->create()) { qDebug2("init") << "failed to create m_texMeshData"; return false; }

        matricesBuffer.resize(sizeForRS * 21 * sizeof(float));
        meshDataBuffer.resize(1024 * sizeof(float));

        m_texCanvas.reset(rhi->newTexture(QRhiTexture::R8, canvasSize, 1, QRhiTexture::Flags()));
        if (!m_texCanvas->create()) { qDebug2("init") << "failed to create m_texCanvas"; return false; }

        m_vertexBuffer.reset(rhi->newBuffer(QRhiBuffer::Immutable, QRhiBuffer::VertexBuffer, sizeof(quadVertexData)));
        if (!m_vertexBuffer->create()) { qDebug2("init") << "failed to create m_vertexBuffer"; return false; }

        m_indexBuffer.reset(rhi->newBuffer(QRhiBuffer::Immutable, QRhiBuffer::IndexBuffer, sizeof(quadIndexData)));
        if (!m_indexBuffer->create()) { qDebug2("init") << "failed to create m_indexBuffer"; return false; }

        m_drawingUniform.reset(rhi->newBuffer(QRhiBuffer::Dynamic, QRhiBuffer::UniformBuffer, 64 + 4));
        if (!m_drawingUniform->create()) { qDebug2("init") << "failed to create m_drawingUniform"; return false; }
        qint32 flip = rhi->isYUpInFramebuffer();

        m_drawingSampler.reset(rhi->newSampler(QRhiSampler::Linear, QRhiSampler::Linear, QRhiSampler::None, QRhiSampler::ClampToEdge, QRhiSampler::ClampToEdge));
        if (!m_drawingSampler->create()) { qDebug2("init") << "failed to create m_drawingSampler"; return false; }

        m_canvasSampler.reset(rhi->newSampler(QRhiSampler::Nearest, QRhiSampler::Nearest, QRhiSampler::None, QRhiSampler::ClampToEdge, QRhiSampler::ClampToEdge));
        if (!m_canvasSampler->create()) { qDebug2("init") << "failed to create m_canvasSampler"; return false; }

        m_matricesSampler.reset(rhi->newSampler(QRhiSampler::Nearest, QRhiSampler::Nearest, QRhiSampler::None, QRhiSampler::ClampToEdge, QRhiSampler::ClampToEdge));
        if (!m_matricesSampler->create()) { qDebug2("init") << "failed to create m_matricesSampler"; return false; }

        m_meshDataSampler.reset(rhi->newSampler(QRhiSampler::Nearest, QRhiSampler::Nearest, QRhiSampler::None, QRhiSampler::ClampToEdge, QRhiSampler::ClampToEdge));
        if (!m_meshDataSampler->create()) { qDebug2("init") << "failed to create m_meshDataSampler"; return false; }

        m_srb.reset(rhi->newShaderResourceBindings());
        m_srb->setBindings({
            QRhiShaderResourceBinding::uniformBuffer (0, QRhiShaderResourceBinding::FragmentStage | QRhiShaderResourceBinding::VertexStage, m_drawingUniform.get()),
            QRhiShaderResourceBinding::sampledTexture(1, QRhiShaderResourceBinding::FragmentStage, item->rhiTexture(), m_drawingSampler.get()),
            QRhiShaderResourceBinding::uniformBuffer (2, QRhiShaderResourceBinding::FragmentStage, m_kernelParams.get()),
            QRhiShaderResourceBinding::sampledTexture(3, QRhiShaderResourceBinding::FragmentStage, m_texMatrices.get(), m_matricesSampler.get()),
            QRhiShaderResourceBinding::sampledTexture(4, QRhiShaderResourceBinding::FragmentStage, m_texCanvas.get(), m_canvasSampler.get()),
            QRhiShaderResourceBinding::sampledTexture(5, QRhiShaderResourceBinding::FragmentStage, m_texMeshData.get(), m_meshDataSampler.get()),
        });
        if (!m_srb->create()) { qDebug2("init") << "failed to create m_srb"; return false; }

        // Pick up shaders that the watcher already compiled in the background.
        // If not available (first load or watcher compile failed), compile fresh now.
        QShader vertShader, fragShader;
        {
            std::lock_guard<std::mutex> lock(s_pendingMu);
            if (s_pending.vert.isValid() && s_pending.frag.isValid()) {
                vertShader = std::move(s_pending.vert);
                fragShader = std::move(s_pending.frag);
                s_pending.vert = QShader();
                s_pending.frag = QShader();
                qDebug2("init") << "Using pre-compiled shaders from watcher thread";
            }
        }
        if (!vertShader.isValid() || !fragShader.isValid()) {
            if (!diskShadersAvailable()) {
                qWarn2("init") << "Cannot compile shaders: qsb or source files not found";
                startWatcher();
                return false;
            }
            if (!vertShader.isValid())
                vertShader = compileSingleShader(base + "src/qt_gpu/texture.vert", QDir::tempPath() + "/gyroflow_texture.vert.qsb");
            if (!fragShader.isValid())
                fragShader = compileShaderFromSource();
        }
        // Always start the watcher so beforeRendering fires reinit() when the shader is fixed,
        // even if the initial compile failed.
        startWatcher();

        if (vertShader.isValid() && fragShader.isValid()) {
            m_pipeline.reset(rhi->newGraphicsPipeline());
            m_pipeline->setShaderStages({
                { QRhiShaderStage::Vertex,   vertShader },
                { QRhiShaderStage::Fragment, fragShader }
            });
            QRhiVertexInputLayout inputLayout;
            inputLayout.setBindings({ { 4 * sizeof(float) } });
            inputLayout.setAttributes({
                { 0, 0, QRhiVertexInputAttribute::Float2, 0 },
                { 0, 1, QRhiVertexInputAttribute::Float2, 2 * sizeof(float) }
            });
            m_pipeline->setVertexInputLayout(inputLayout);
            m_pipeline->setShaderResourceBindings(m_srb.get());
            m_pipeline->setRenderPassDescriptor(m_externalRTRP);
            if (!m_pipeline->create()) {
                qWarn2("init") << "Pipeline creation failed — black screen until shader is fixed";
                m_pipeline.reset();
            }
        } else {
            if (!vertShader.isValid()) qWarn2("init") << "Vertex shader compilation failed — black screen until fixed";
            if (!fragShader.isValid()) qWarn2("init") << "Fragment shader compilation failed — black screen until fixed";
            // m_pipeline stays null; render() will return false
        }

        m_initialUpdates = rhi->nextResourceUpdateBatch();
        m_initialUpdates->uploadStaticBuffer(m_vertexBuffer.get(), quadVertexData);
        m_initialUpdates->uploadStaticBuffer(m_indexBuffer.get(), quadIndexData);
        m_initialUpdates->updateDynamicBuffer(m_drawingUniform.get(), 64, 4, &flip);

        // Return true even with a null pipeline: instance stays alive so the watcher
        // can call reinit() when the shader is fixed, without Rust destroying us.
        return true;
    }

    bool render(MDKPlayer *item, uint8_t *params, uint paramsLen, uint8_t *matrices, uint matricesLen, uint8_t *canvas, uint canvasLen, float *meshData, uint meshDataLen) {
        if (!item->qmlItem() || !item->rhiTexture() || !item->qmlWindow()) return false;
        if (!m_pipeline || !m_externalRT) return false;
        m_hadFirstRender = true;
        auto context = item->rhiContext();
        auto rhi = context->rhi();

        if (matricesBuffer.size() < matricesLen) { matricesBuffer.resize(matricesLen); }
        if (matricesLen > 0) memcpy(matricesBuffer.data(), matrices, matricesLen);

        if (meshDataBuffer.size() < meshDataLen*4) { meshDataBuffer.resize(meshDataLen*4); }
        if (meshDataLen > 0) memcpy(meshDataBuffer.data(), meshData, meshDataLen*4);
        else if (meshDataBuffer[0] != 0) memset(meshDataBuffer.data(), 0, meshDataBuffer.size());

        QRhiCommandBuffer *cb = context->currentFrameCommandBuffer();

        QRhiResourceUpdateBatch *u = rhi->nextResourceUpdateBatch();
        if (m_initialUpdates) {
            u->merge(m_initialUpdates);
            m_initialUpdates->release();
            m_initialUpdates = nullptr;
        }

        u->updateDynamicBuffer(m_kernelParams.get(), 0, paramsLen, params);

        {
            QRhiTextureSubresourceUploadDescription desc1(meshDataBuffer.data(), meshDataBuffer.size());
            u->uploadTexture(m_texMeshData.get(), QRhiTextureUploadDescription({ QRhiTextureUploadEntry(0, 0, desc1) }));
        }

        QRhiTextureSubresourceUploadDescription desc1(matricesBuffer.data(), matricesBuffer.size());
        u->uploadTexture(m_texMatrices.get(), QRhiTextureUploadDescription({ QRhiTextureUploadEntry(0, 0, desc1) }));

        if (canvasLen > 0) {
            QRhiTextureSubresourceUploadDescription desc2(canvas, canvasLen);
            u->uploadTexture(m_texCanvas.get(), QRhiTextureUploadDescription({ QRhiTextureUploadEntry(0, 0, desc2) }));
        }

        QMatrix4x4 mvp = item->textureMatrix();
        mvp.scale(2.0f);
        u->updateDynamicBuffer(m_drawingUniform.get(), 0, 64, mvp.constData());

        // Render shader output directly into the viewport's render target.
        // No intermediate texture, no copyTexture — MDK is done after this.
        cb->beginPass(m_externalRT, QColor(Qt::black), { 1.0f, 0 }, u);
        cb->setGraphicsPipeline(m_pipeline.get());
        cb->setViewport({ 0, 0, float(m_outputSize.width()), float(m_outputSize.height()) });
        cb->setShaderResources();
        QRhiCommandBuffer::VertexInput vbufBinding(m_vertexBuffer.get(), 0);
        cb->setVertexInput(0, 1, &vbufBinding, m_indexBuffer.get(), 0, QRhiCommandBuffer::IndexUInt16);
        cb->drawIndexed(6);
        cb->endPass();

        rhi->finish();

        return true;
    }

    std::vector<uint8_t> matricesBuffer;
    std::vector<uint8_t> meshDataBuffer;

    QShader getShader(const QString &name) {
        QFile f(name);
        if (f.open(QIODevice::ReadOnly))
            return QShader::fromSerialized(f.readAll());
        return QShader();
    }

    QRhiTexture *m_itemTexturePtr{nullptr};

    // External render target — owned by GyroflowViewport, not by this class.
    QRhiTextureRenderTarget  *m_externalRT   {nullptr};
    QRhiRenderPassDescriptor *m_externalRTRP {nullptr};

    QScopedPointer<QRhiTexture> m_texMatrices;
    QScopedPointer<QRhiTexture> m_texCanvas;
    QScopedPointer<QRhiBuffer> m_kernelParams;
    QScopedPointer<QRhiTexture> m_texMeshData;

    QSize m_outputSize;
    QSize m_textureSize;
    QString m_shaderPath;
    unsigned int m_sizeForRS{0};

    MDKPlayer *m_item{nullptr};
    int m_kernelParmsSize{0};
    QSize m_canvasSize;
    bool m_hadFirstRender{false};
    QString m_distortionModel;
    QString m_digitalLens;
    QStringList m_watchedSourcePaths;
    QList<QDateTime> m_watchedSourceMtimes;
    mutable std::atomic<bool> m_filesChanged{false};
    std::atomic<bool> m_watcherStop{true};
    std::thread m_watcherThread;
    QMetaObject::Connection m_beforeRenderingConn;

    QScopedPointer<QRhiBuffer> m_vertexBuffer;
    QScopedPointer<QRhiBuffer> m_indexBuffer;
    QScopedPointer<QRhiBuffer> m_drawingUniform;
    QScopedPointer<QRhiSampler> m_canvasSampler;
    QScopedPointer<QRhiSampler> m_drawingSampler;
    QScopedPointer<QRhiSampler> m_matricesSampler;
    QScopedPointer<QRhiSampler> m_meshDataSampler;
    QScopedPointer<QRhiShaderResourceBindings> m_srb;
    QScopedPointer<QRhiGraphicsPipeline> m_pipeline;

    QScopedPointer<QRhiReadbackResult> m_readbackResult;

    QRhiResourceUpdateBatch *m_initialUpdates{nullptr};
};
