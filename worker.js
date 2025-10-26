// worker.js (module worker)
// OffscreenCanvas 上でシーンモジュールを駆動し、フレーム毎に WebCodecs へ投入。
// 任意秒の1フレームプレビューは ImageBitmap をメインへ転送。

/* ===================== 依存CDN =====================
 * webm-muxer: https://github.com/Vanilagy/webm-muxer
 * いずれも ESM を import します（Module Worker）。
 * ブラウザは Chrome 系の最新を想定（WebCodecs / OffscreenCanvas）。
 * ================================================== */
import { Muxer, ArrayBufferTarget } from 'https://cdn.jsdelivr.net/npm/webm-muxer@3.2.1/build/webm-muxer.mjs';

console.log('[worker] script evaluated top-level');

// ====== レンダリング関連の状態 ======
let canvas;             // OffscreenCanvas（レンダー用）
let initialCanvas = null; // メインから受け取った初期キャンバス（fallback用）
let width = 1280, height = 720;
let renderer = null;    // 任意のレンダラー（例: THREE.WebGLRenderer）
let sceneController = null;
let renderFrame = null;
let ready = false;
let sceneModuleUrl = './scene-default.js';
let renderContext = null; // WebGLRenderingContext | WebGL2RenderingContext | null

// ====== エンコード関連 ======
let encoder = null;
let muxer = null;               // webm-muxer
let muxTarget = null;           // ArrayBufferTarget（Output buffer）
let fps = 30;
let keyframeIntervalSec = 2;
let bitrate = 6_000_000;
let debugSampleCount = 0;
let colorSpace = 'srgb';

// ====== 汎用ログ ======
const log = (m) => {
//  console.log('[worker]', m);
  postMessage({ type:'log', message: String(m) });
};

function createCacheBustedModuleUrl(baseUrl) {
  // Append a short-lived token so module re-imports bypass the browser cache.
  const source = (baseUrl || '').trim();
  if (!source) {
    throw new Error('Scene module URL must be a non-empty string');
  }
  const token = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
  try {
    const absolute = new URL(source, self.location?.href || self.location);
    absolute.searchParams.set('cacheBust', token);
    return absolute.href;
  } catch (err) {
    const delimiter = source.includes('?') ? '&' : '?';
    return `${source}${delimiter}cacheBust=${token}`;
  }
}

// ====== メッセージ受付 ======
self.onmessage = async (ev) => {
  const msg = ev.data;
  try {
    if (msg.type === 'init') {
      initialCanvas = msg.canvas;
      canvas = initialCanvas;
      width = canvas.width; height = canvas.height;
      await initScene(msg.sceneModule);
      ready = true;
      log('Worker initialized.');
    } else if (msg.type === 'resize') {
      width = msg.width|0; height = msg.height|0;
 //     log(`Resize received => ${width}x${height}`);
      if (canvas) {
        canvas.width = width;
        canvas.height = height;
      }
      if (sceneController?.resize) {
        sceneController.resize(width, height);
      } else if (renderer) {
        renderer.setSize(width, height, false);
      }
    } else if (msg.type === 'preview') {
      // 指定時刻（秒）の1フレームを描いて ImageBitmap を送る
      ensureReady();
      const t = Math.max(0, +msg.timeSec || 0);
      fps = Math.max(1, +msg.fps || 30);
      log(`Preview request t=${t.toFixed(3)} fps=${fps} size=${width}x${height}`);
      colorSpace = msg.colorSpace || 'srgb';
      await renderAtTime(t);
      await emitPreview(t, { debug: false, origin: 'ui' });
    } else if (msg.type === 'render') {
      ensureReady();
      const totalFrames = +msg.totalFrames|0;
      fps = Math.max(1, +msg.fps || 30);
      bitrate = Math.max(100_000, +msg.bitrate || 6_000_000);
      keyframeIntervalSec = Math.max(0.5, +msg.keyframeIntervalSec || 2);
      const webmBuffer = await renderAndEncode(totalFrames);
      // Muxer 終了 → Blob URL を返す
      const blob = new Blob([webmBuffer], { type: 'video/webm' });
      const url = URL.createObjectURL(blob);
      postMessage({ type:'done', url, sizeBytes: blob.size });
    } else if (msg.type === 'loadScene') {
      ensureReady();
      const modulePath = typeof msg.module === 'string' ? msg.module : null;
      const previewTime = typeof msg.timeSec === 'number' ? msg.timeSec : 0;
      log(`Scene reload requested => ${modulePath || sceneModuleUrl}`);
      await initScene(modulePath);
      if (sceneController?.resize) {
        sceneController.resize(width, height);
      } else if (renderer) {
        renderer.setSize(width, height, false);
      }
      await renderAtTime(previewTime);
      await emitPreview(previewTime, { origin: 'scene-reload' });
    }
  } catch (e) {
    postMessage({ type:'error', message: e?.stack || String(e) });
  }
};

// ====== シーン初期化 ======
async function initScene(modulePath){
  const targetUrl = typeof modulePath === 'string' && modulePath.length > 0
    ? modulePath
    : sceneModuleUrl;
  const resolvedUrl = (targetUrl || './scene-default.js').trim() || './scene-default.js';

  destroyCurrentScene();

  const canvasSetup = createRenderingCanvas(width, height);
  canvas = canvasSetup.surface;
  width = canvasSetup.width;
  height = canvasSetup.height;
  if (!canvasSetup.reusedInitial) {
    initialCanvas = canvas;
  }

  const bustUrl = createCacheBustedModuleUrl(resolvedUrl);
  const mod = await import(bustUrl);
  const factory = typeof mod.createSceneController === 'function'
    ? mod.createSceneController
    : typeof mod.default === 'function'
      ? mod.default
      : null;
  if (typeof factory !== 'function') {
    throw new Error(`Scene module ${resolvedUrl} must export createSceneController()`);
  }

  const controller = await factory({ canvas, width, height });
  if (!controller || typeof controller.renderFrame !== 'function') {
    throw new Error(`Scene module ${resolvedUrl} returned invalid controller`);
  }

  sceneController = controller;
  sceneModuleUrl = resolvedUrl;
  renderer = controller.renderer ?? null;
  renderFrame = controller.renderFrame.bind(controller);
  renderContext = resolveRenderContext(controller);
  if (!renderer && typeof controller.resize !== 'function') {
    log(`Scene ${resolvedUrl} does not provide renderer.resize; resize fallback unavailable.`);
  }
}

// 任意時刻 t（秒）で1フレームだけ描画
async function renderAtTime(tSec){
  if (typeof renderFrame !== 'function') {
    throw new Error('Scene render function not configured');
  }
  renderFrame(tSec);
  await waitForGpu();
}

// ====== オフライン 1フレームずつ → WebCodecs へ投入 ======
async function renderAndEncode(totalFrames){
  if (typeof renderFrame !== 'function') {
    throw new Error('Scene render function not configured');
  }
  // 1) WebM muxer 準備（VP9想定）
  muxTarget = new ArrayBufferTarget();
  muxer = new Muxer({
    fastStart: false,  // 後から blob で渡すので false でもOK
    target: muxTarget,
    video: {
      codec: 'V_VP9',           // VP9
      width, height,
      frameRate: fps
    }
  });

  // 2) VideoEncoder 準備（VP9）
  const config = {
    codec: 'vp09.00.10.08',     // VP9 profile/level（環境に応じて fallback してもOK）
    width, height,
    bitrate,                     // bps
    framerate: fps,
  };
  const sup = await VideoEncoder.isConfigSupported(config);
  if (!sup.supported) {
    throw new Error('WebCodecs: encoder config not supported (VP9).');
  }

  encoder = new VideoEncoder({
    output: (chunk, meta) => {
      if (!muxer) {
        chunk.close?.();
        return;
      }
      try {
        // webm-muxer expects the EncodedVideoChunk instance
        muxer.addVideoChunk(chunk, meta);
      } finally {
        chunk.close?.();
      }
    },
    error: (e) => postMessage({ type:'error', message: String(e) })
  });
  encoder.configure(config);

  // 3) ループ：各フレームを決定的に描画 → VideoFrame化 → encode
  const timePerFrameUs = Math.round(1_000_000 / fps);
  for (let i=0; i<totalFrames; i++){
    const t = i / fps;          // 決定的な理想時刻
    renderFrame(t);             // シーンを t 秒でレンダ
    await waitForGpu();
    if (i === 0) debugSample('render-loop');
    debugSample(`frame ${i}`);
    await emitPreview(t, { origin: 'render' });

    // VideoFrame へ（OffscreenCanvas からゼロコピー的に作れる）
    const ts = i * timePerFrameUs; // us
    const vf = new VideoFrame(canvas, { timestamp: ts });
    const isKey = (i === 0) || (i % Math.round(keyframeIntervalSec * fps) === 0);
    encoder.encode(vf, { keyFrame: isKey });
    vf.close();

    // 進捗通知
    postMessage({ type:'progress', done: i+1, total: totalFrames });

    // スレッドに譲る（UI/GCに優しい）
    await nap(0);
  }

  // 4) 終了処理：flush → close → muxer finalize
  await encoder.flush();
  encoder.close();
  encoder = null;
  muxer.finalize();
  const buffer = muxTarget?.buffer ?? new ArrayBuffer(0);
  muxer = null;
  muxTarget = null;
  return buffer;
}

function nap(ms){ return new Promise(r => setTimeout(r, ms)); }
function ensureReady(){ if (!ready) throw new Error('Worker not initialized'); }
async function waitForGpu(){
  const gl = await getRenderableContext();
  if (!gl) return;
  if (typeof gl.fenceSync !== 'function') {
    gl.finish?.();
    return;
  }
  const sync = gl.fenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0);
  gl.flush();
  let status;
  do {
    status = gl.clientWaitSync(sync, 0, 0);
    if (status === gl.TIMEOUT_EXPIRED) await nap(0);
  } while (status !== gl.CONDITION_SATISFIED && status !== gl.ALREADY_SIGNALED);
  gl.deleteSync(sync);
  gl.commit?.();
}

function debugSample(tag){
    return ;
  if (debugSampleCount++ > 8) return;
  const gl = renderContext;
  if (!gl?.readPixels) return;
  const x = Math.max(0, Math.min(width - 1, Math.floor(width / 2)));
  const y = Math.max(0, Math.min(height - 1, Math.floor(height / 2)));
  const buf = new Uint8Array(4);
  try {
    gl.readPixels(x, y, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, buf);
    log(`[debug:${tag}] pixel(${x},${y}) = [${buf.join(', ')}]`);
  } catch (err) {
    log(`[debug:${tag}] readPixels failed: ${err?.message || err}`);
  }
}

async function captureBitmap(){
  if (!canvas) {
    throw new Error('Canvas not configured');
  }
  if (typeof sceneController?.captureBitmap === 'function') {
    const bmp = await sceneController.captureBitmap({ width, height, canvas });
    if (bmp) return bmp;
  }
  return await createImageBitmap(canvas);
}

async function emitPreview(timeSec, { debug = false, origin = 'render' } = {}){
  const bmp = await captureBitmap();
  if (debug) {
    log(`Preview bitmap size = ${bmp.width}x${bmp.height}`);
    try {
      const testCanvas = new OffscreenCanvas(1, 1);
      const testCtx = testCanvas.getContext('2d');
      if (!testCtx) {
        log('[debug:bitmap] no 2d context available');
      }
      log(`[debug:bitmap] bitmap colorSpace=${bmp.colorSpace}`);
      const sx = Math.max(0, Math.min(bmp.width - 1, Math.floor(bmp.width / 2)));
      const sy = Math.max(0, Math.min(bmp.height - 1, Math.floor(bmp.height / 2)));
      testCtx.drawImage(bmp, sx, sy, 1, 1, 0, 0, 1, 1);
      const pixel = testCtx.getImageData(0, 0, 1, 1).data;
      log(`[debug:bitmap] center pixel = [${pixel.join(', ')}]`);
    } catch (err) {
      log(`[debug:bitmap] sample failed: ${err?.message || err}`);
    }
  }
  postMessage({ type:'preview', bitmap: bmp, timeSec, width, height, origin }, [bmp]);
}

function resolveRenderContext(controller){
  try {
    if (!controller) return null;
    if (controller.renderContext) return controller.renderContext;
    if (controller.gl) return controller.gl;
    if (controller.context && typeof controller.context.getParameter === 'function') {
      return controller.context;
    }
    if (controller.renderer?.getContext) {
      return controller.renderer.getContext();
    }
    const candidate = typeof controller.getRenderContext === 'function'
      ? controller.getRenderContext()
      : null;
    if (candidate && typeof candidate.then === 'function') {
      candidate.then((ctx) => {
        if (ctx && typeof ctx.getParameter === 'function') {
          renderContext = ctx;
        }
      }).catch((err) => {
        log(`resolveRenderContext (async) failed: ${err?.message || err}`);
      });
      return null;
    }
    if (candidate && typeof candidate.getParameter === 'function') {
      return candidate;
    }
    return null;
  } catch (err) {
    log(`resolveRenderContext: ${err?.message || err}`);
    return null;
  }
}

async function getRenderableContext(){
  if (renderContext) return renderContext;
  const ctx = resolveRenderContext(sceneController);
  if (ctx) {
    renderContext = ctx;
    return renderContext;
  }
  return renderContext;
}

function destroyCurrentScene(){
  const prevController = sceneController;
  const prevRenderer = renderer;
  const prevContext = renderContext;

  sceneController = null;
  renderFrame = null;
  renderer = null;
  renderContext = null;

  try {
    prevController?.dispose?.();
  } catch (err) {
    log(`Scene dispose failed: ${err?.message || err}`);
  }
  try {
    prevRenderer?.dispose?.();
  } catch (err) {
    log(`Renderer dispose failed: ${err?.message || err}`);
  }
  try {
    prevRenderer?.forceContextLoss?.();
  } catch (err) {
    log(`Renderer forceContextLoss failed: ${err?.message || err}`);
  }
  releaseWebGLContext(prevContext);
}

function createRenderingCanvas(targetWidth, targetHeight){
  const desiredWidth = clampDimension(targetWidth);
  const desiredHeight = clampDimension(targetHeight);

  if (typeof OffscreenCanvas === 'function') {
    try {
      const surface = new OffscreenCanvas(desiredWidth, desiredHeight);
      surface.width = desiredWidth;
      surface.height = desiredHeight;
      return {
        surface,
        width: surface.width,
        height: surface.height,
        reusedInitial: false
      };
    } catch (err) {
      log(`OffscreenCanvas allocation failed (${err?.message || err}), falling back to initial canvas.`);
    }
  }

  if (initialCanvas) {
    initialCanvas.width = desiredWidth;
    initialCanvas.height = desiredHeight;
    return {
      surface: initialCanvas,
      width: initialCanvas.width,
      height: initialCanvas.height,
      reusedInitial: true
    };
  }

  throw new Error('Rendering canvas allocation failed: OffscreenCanvas unavailable');
}

function releaseWebGLContext(gl){
  if (!gl || typeof gl.getExtension !== 'function') return;
  try {
    const lose =
      gl.getExtension('WEBGL_lose_context') ||
      gl.getExtension('WEBKIT_WEBGL_lose_context');
    if (lose && typeof lose.loseContext === 'function') {
      lose.loseContext();
    }
  } catch (err) {
    log(`releaseWebGLContext failed: ${err?.message || err}`);
  }
}

function clampDimension(value){
  const num = Number.isFinite(value) ? value : 1;
  const clamped = Math.max(1, num);
  return Math.floor(clamped);
}
