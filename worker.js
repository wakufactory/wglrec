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
let cancelRequested = false;
let isRendering = false;
let sceneInitLock = Promise.resolve();
let sceneInitInFlight = null;

// ====== エンコード関連 ======
let encoder = null;
let muxer = null;               // webm-muxer
let muxTarget = null;           // ArrayBufferTarget（Output buffer）
let fps = 30;
let keyframeIntervalSec = 2;
let bitrate = 6_000_000;

// ====== 汎用ログ ======
const log = (m) => {
//  console.log('[worker]', m);
  postMessage({ type:'log', message: String(m) });
};

// モジュール再読み込み用にキャッシュバスター付きURLを生成する
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
  try {
    const msg = ev.data ?? {};
    switch (msg.type) {
      case 'init':
        await handleInit(msg);
        break;
      case 'resize':
        handleResize(msg);
        break;
      case 'preview':
        await handlePreview(msg);
        break;
      case 'render':
        await handleRender(msg);
        break;
      case 'loadScene':
        await handleLoadScene(msg);
        break;
      case 'cancelRender':
        handleCancelRender();
        break;
      default:
        if (msg.type) {
          log(`Unknown message type: ${msg.type}`);
        }
    }
  } catch (e) {
    postMessage({ type:'error', message: e?.stack || String(e) });
  }
};

// メインスレッドから渡された初期化情報を受け取り、シーンと状態を整える
async function handleInit({ canvas: initCanvas, sceneModule }) {
  initialCanvas = initCanvas;
  canvas = initialCanvas;
  if (!canvas) {
    throw new Error('Initialization requires a transferable canvas');
  }
  width = canvas.width;
  height = canvas.height;
  log('Worker initialization started.');
  await initScene(sceneModule);
  ready = true;
  log('Worker initialized.');
  postMessage({
    type: 'ready',
    sceneModule: sceneModuleUrl,
    width,
    height
  });
}

// UIからのリサイズ指示を受けてキャンバス寸法を更新する
function handleResize({ width: nextWidth, height: nextHeight }) {
  applyResize(nextWidth, nextHeight);
}

// 指定秒数のプレビューフレームを描画してメインへ送る
async function handlePreview({ timeSec, fps: requestedFps }) {
  ensureReady();
  const t = Math.max(0, Number(timeSec) || 0);
  fps = Math.max(1, Number(requestedFps) || 30);
  log(`Preview request t=${t.toFixed(3)} fps=${fps} size=${width}x${height}`);
  await renderAtTime(t);
  await emitPreview(t, 'ui');
}

// エンコード付きの本番レンダリング要求を処理する
async function handleRender({ totalFrames, fps: requestedFps, bitrate: requestedBitrate, keyframeIntervalSec: requestedInterval, startSec, endSec }) {
  ensureReady();
  if (isRendering) {
    log('Render request ignored: already rendering.');
    return;
  }
  const frames = Math.max(0, Math.floor(Number(totalFrames) || 0));
  fps = Math.max(1, Number(requestedFps) || 30);
  bitrate = Math.max(100_000, Number(requestedBitrate) || 6_000_000);
  keyframeIntervalSec = Math.max(0.5, Number(requestedInterval) || 2);
  const rangeStart = Math.max(0, Number(startSec) || 0);
  let rangeEnd = Number(endSec);
  if (!Number.isFinite(rangeEnd)) {
    rangeEnd = rangeStart + (frames > 0 ? frames / fps : 0);
  }
  if (rangeEnd < rangeStart) {
    rangeEnd = rangeStart;
  }
  cancelRequested = false;
  isRendering = true;
  try {
    const webmBuffer = await renderAndEncode({ totalFrames: frames, startSec: rangeStart, endSec: rangeEnd });
    if (cancelRequested) {
      postMessage({ type:'cancelled' });
      return;
    }
    const blob = new Blob([webmBuffer], { type: 'video/webm' });
    const url = URL.createObjectURL(blob);
    postMessage({ type:'done', url, sizeBytes: blob.size });
  } catch (err) {
    if (err?.name === 'AbortError') {
      log('Render cancelled before completion.');
      postMessage({ type:'cancelled' });
      return;
    }
    throw err;
  } finally {
    cancelRequested = false;
    isRendering = false;
  }
}

// 別のシーンモジュールを再読み込みしてプレビューを更新する
async function handleLoadScene({ module, timeSec }) {
  ensureReady();
  const modulePath = typeof module === 'string' ? module : null;
  const previewTime = Math.max(0, Number(timeSec) || 0);
  log(`Scene reload requested => ${modulePath || sceneModuleUrl}`);
  await initScene(modulePath);
  applyResize(width, height);
  await renderAtTime(previewTime);
  await emitPreview(previewTime, 'scene-reload');
}

// 実行中レンダリングにキャンセルフラグを立てる
function handleCancelRender() {
  if (!isRendering) {
    log('Cancel request ignored: no active render.');
    return;
  }
  log('Cancel render requested.');
  cancelRequested = true;
}

// キャンバスとシーンに対して実際のリサイズ処理を行う
function applyResize(nextWidth, nextHeight) {
  const parsedWidth = Number(nextWidth);
  const parsedHeight = Number(nextHeight);
  width = clampDimension(Number.isFinite(parsedWidth) ? parsedWidth : width);
  height = clampDimension(Number.isFinite(parsedHeight) ? parsedHeight : height);

  if (canvas) {
    canvas.width = width;
    canvas.height = height;
  }

  const resize = sceneController?.resize;
  if (typeof resize === 'function') {
    resize(width, height);
    return;
  }

  renderer?.setSize?.(width, height, false);
}

// ====== シーン初期化 ======
// 指定されたシーンモジュールを動的に読み込み初期化する
async function initScene(modulePath){
  await sceneInitLock;
  let releaseLock = () => {};
  sceneInitLock = new Promise((resolve) => {
    releaseLock = resolve;
  });

  const initPromise = (async () => {
    const resolvedUrl =
      (typeof modulePath === 'string' && modulePath.trim()) ||
      (sceneModuleUrl && sceneModuleUrl.trim()) ||
      './scene-default.js';

    destroyCurrentScene();

    const { surface, width: surfaceWidth, height: surfaceHeight, reusedInitial } =
      createRenderingCanvas(width, height);
    canvas = surface;
    width = surfaceWidth;
    height = surfaceHeight;
    if (!reusedInitial) {
      initialCanvas = canvas;
    }

    const mod = await import(createCacheBustedModuleUrl(resolvedUrl));
    const factory = typeof mod.createSceneController === 'function'
      ? mod.createSceneController
      : typeof mod.default === 'function'
        ? mod.default
        : null;
    if (typeof factory !== 'function') {
      throw new Error(`Scene module ${resolvedUrl} must export createSceneController()`);
    }

    const controllerLog = (msg) => log(`[scene] ${msg}`);
    const controller = await factory({ canvas, width, height, log: controllerLog });
    if (typeof controller?.renderFrame !== 'function') {
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
  })();

  sceneInitInFlight = initPromise;
  try {
    await initPromise;
  } finally {
    if (sceneInitInFlight === initPromise) {
      sceneInitInFlight = null;
    }
    releaseLock();
  }
}

// 任意時刻 t（秒）のフレームをタイル描画でレンダリングする
async function renderAtTime(tSec){
  await renderFrameWithViewportGrid(tSec);
}

// ====== オフライン 1フレームずつ → WebCodecs へ投入 ======
// 連続フレームを描画しつつWebCodecsでエンコードする
async function renderAndEncode({ totalFrames, startSec, endSec }){
  await waitForSceneInitialization();
  if (typeof renderFrame !== 'function') {
    throw new Error('Scene render function not configured');
  }
  const abortIfNeeded = () => {
    if (cancelRequested) {
      throw createAbortError();
    }
  };

  try {
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
        if (!muxer || cancelRequested) {
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
    abortIfNeeded();

    // 3) ループ：各フレームを決定的に描画 → VideoFrame化 → encode
    const timePerFrameUs = Math.round(1_000_000 / fps);
    const keyframeInterval = Math.max(1, Math.round(keyframeIntervalSec * fps));
    const baseTime = Math.max(0, Number(startSec) || 0);
    let endTime = Number(endSec);
    if (!Number.isFinite(endTime) || endTime < baseTime) {
      endTime = baseTime;
    }
    for (let i = 0; i < totalFrames; i++) {
      abortIfNeeded();
      const t = baseTime + i / fps;          // レンジ開始からの決定的な理想時刻
      const clampedT = Math.min(t, endTime);
      await renderFrameWithViewportGrid(clampedT, { abortCheck: abortIfNeeded });
      abortIfNeeded();
      await emitPreview(clampedT, 'render');
      abortIfNeeded();

      // VideoFrame へ（OffscreenCanvas からゼロコピー的に作れる）
      const ts = i * timePerFrameUs; // us
      const vf = new VideoFrame(canvas, { timestamp: ts });
      const isKey = (i === 0) || (i % keyframeInterval === 0);
      encoder.encode(vf, { keyFrame: isKey });
      vf.close();
      abortIfNeeded();

      // 進捗通知
      postMessage({ type:'progress', done: i + 1, total: totalFrames });

      // スレッドに譲る（UI/GCに優しい）
      await nap(0);
      abortIfNeeded();
    }

    // 4) 終了処理：flush → close → muxer finalize
    await encoder.flush();
    abortIfNeeded();
    encoder.close();
    encoder = null;
    abortIfNeeded();
    muxer?.finalize();
    const buffer = muxTarget?.buffer ?? new ArrayBuffer(0);
    muxer = null;
    muxTarget = null;
    return buffer;
  } catch (err) {
    resetEncodingPipeline();
    throw err;
  }
}

// ビューポートをタイル状に分割し、各ブロックを順番に描画する共通ループ
async function renderFrameWithViewportGrid(timeSec, options = {}){
  await waitForSceneInitialization();
  if (typeof renderFrame !== 'function') {
    throw new Error('Scene render function not configured');
  }

  const { abortCheck } = options ?? {};
  const grid = await resolveViewportGridDescriptor();
  const totalBlocks = Math.max(1, Number(grid?.totalBlocks) || (grid.columns * grid.rows));

  for (let blockIndex = 0; blockIndex < totalBlocks; blockIndex++) {
    if (typeof abortCheck === 'function') {
      abortCheck();
    }
    const block = describeViewportBlock(blockIndex, grid, width, height);
    await renderFrame(timeSec, block);
    await waitForGpu();
    log(`block ${block.index + 1}/${totalBlocks} (${block.width}x${block.height}@${block.offsetX},${block.offsetY}) rendered at t=${timeSec.toFixed?.(3) ?? timeSec}`);
    if (typeof abortCheck === 'function') {
      abortCheck();
    }
  }
}

// キャンセル検出時に投げる AbortError を生成する
function createAbortError(){
  try {
    return new DOMException('Render cancelled', 'AbortError');
  } catch (_) {
    const err = new Error('Render cancelled');
    err.name = 'AbortError';
    return err;
  }
}

// エンコード途中でエラーになった際に関連リソースを解放する
function resetEncodingPipeline(){
  if (encoder) {
    try { encoder.close(); } catch (_) { /* ignore */ }
    encoder = null;
  }
  muxer = null;
  muxTarget = null;
}

// 指定ミリ秒だけ待つシンプルな遅延ユーティリティ
function nap(ms = 0){ return new Promise(r => setTimeout(r, ms)); }
// 初期化が完了しているかを確認し、未準備なら例外を投げる
function ensureReady(){ if (!ready) throw new Error('Worker not initialized'); }
// GPU側の処理完了を同期的に待ち合わせる
async function waitForGpu(){
  if (typeof sceneController?.waitForGpu === 'function') {
    await sceneController.waitForGpu();
    return;
  }
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

// 現在のキャンバス内容を ImageBitmap として取得する
async function captureBitmap(){
  await waitForSceneInitialization();
  if (!canvas) {
    throw new Error('Canvas not configured');
  }
  if (typeof sceneController?.captureBitmap === 'function') {
    const bmp = await sceneController.captureBitmap({ width, height, canvas });
    if (bmp) return bmp;
  }
  return await createImageBitmap(canvas);
}

// プレビュー画像をメインスレッドに転送する
async function emitPreview(timeSec, origin = 'render'){
  const bmp = await captureBitmap();
  postMessage({ type:'preview', bitmap: bmp, timeSec, width, height, origin }, [bmp]);
}

// シーンコントローラから WebGL コンテキストを特定して返す
function resolveRenderContext(controller){
  try {
    if (!controller) return null;

    const candidates = [
      controller.renderContext,
      controller.gl,
      typeof controller.context?.getParameter === 'function' ? controller.context : null,
      typeof controller.renderer?.getContext === 'function' ? controller.renderer.getContext() : null
    ];

    for (const ctx of candidates) {
      if (ctx?.getParameter) {
        return ctx;
      }
    }

    if (typeof controller.getRenderContext !== 'function') {
      return null;
    }

    const asyncCandidate = controller.getRenderContext();
    if (asyncCandidate?.then) {
      asyncCandidate.then((ctx) => {
        if (ctx?.getParameter) {
          renderContext = ctx;
        }
      }).catch((err) => {
        log(`resolveRenderContext (async) failed: ${err?.message || err}`);
      });
      return null;
    }

    return asyncCandidate?.getParameter ? asyncCandidate : null;
  } catch (err) {
    log(`resolveRenderContext: ${err?.message || err}`);
    return null;
  }
}

// 利用可能な描画コンテキストを確保しキャッシュする
async function getRenderableContext(){
  if (!renderContext) {
    const ctx = resolveRenderContext(sceneController);
    if (ctx) {
      renderContext = ctx;
    }
  }
  return renderContext;
}

// 現在のシーンやレンダラーを破棄しリソースを解放する
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

// レンダリングに利用するキャンバスを確保する
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

// WEBGL_lose_context 拡張を使ってコンテキストを解放する
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

// シーン側が公開するビューポート分割数を取得し、標準化したディスクリプタを返す
async function resolveViewportGridDescriptor(){
  const fallback = { columns: 1, rows: 1, totalBlocks: 1 };
  if (!sceneController) {
    return fallback;
  }
  try {
    const raw = typeof sceneController.getViewportGrid === 'function'
      ? await sceneController.getViewportGrid()
      : sceneController.viewportGrid;
    return normalizeViewportGridDescriptor(raw);
  } catch (err) {
    log(`resolveViewportGrid failed: ${err?.message || err}`);
    return fallback;
  }
}

// グリッド情報を安全な列・行数に正規化する
function normalizeViewportGridDescriptor(raw){
  const columns = clampGridDimension(raw?.columns ?? raw?.cols ?? raw?.x ?? raw?.width ?? 1);
  const rows = clampGridDimension(raw?.rows ?? raw?.lines ?? raw?.y ?? raw?.height ?? 1);
  const totalBlocks = Math.max(1, columns * rows);
  return { columns, rows, totalBlocks };
}

// 指定インデックスのブロック領域を算出して返す
function describeViewportBlock(index, grid, canvasWidth, canvasHeight){
  const columns = clampGridDimension(grid?.columns ?? 1);
  const rows = clampGridDimension(grid?.rows ?? 1);
  const totalBlocks = Math.max(1, columns * rows);
  const cappedIndex = Math.min(totalBlocks - 1, Math.max(0, Math.floor(index)));
  const column = cappedIndex % columns;
  const row = Math.floor(cappedIndex / columns);
  const sliceX = computeViewportSlice(canvasWidth, columns, column);
  const sliceY = computeViewportSlice(canvasHeight, rows, row);
  return {
    index: cappedIndex,
    columns,
    rows,
    totalBlocks,
    column,
    row,
    isFirst: cappedIndex === 0,
    isLast: cappedIndex === totalBlocks - 1,
    offsetX: sliceX.start,
    offsetY: sliceY.start,
    width: sliceX.size,
    height: sliceY.size,
    scissorX: sliceX.start,
    scissorY: sliceY.start,
    scissorWidth: sliceX.size,
    scissorHeight: sliceY.size,
    canvasWidth,
    canvasHeight
  };
}

// 全長と分割数から対象セグメントの範囲を求める
function computeViewportSlice(fullLength, segments, segmentIndex){
  const safeLength = Math.max(1, Math.floor(fullLength));
  const safeSegments = Math.max(1, Math.floor(segments));
  const clampedIndex = Math.min(safeSegments - 1, Math.max(0, Math.floor(segmentIndex)));
  const start = Math.floor((clampedIndex * safeLength) / safeSegments);
  const rawEnd = clampedIndex === safeSegments - 1
    ? safeLength
    : Math.floor(((clampedIndex + 1) * safeLength) / safeSegments);
  const end = Math.max(start + 1, rawEnd);
  return {
    start,
    end,
    size: end - start
  };
}

// ビューポート分割数を1以上の整数に丸める
function clampGridDimension(value){
  const num = Number(value);
  if (!Number.isFinite(num) || num < 1) {
    return 1;
  }
  return Math.floor(num);
}

// ピクセル寸法を1以上の整数値に丸める
function clampDimension(value){
  const num = Number.isFinite(value) ? value : 1;
  const clamped = Math.max(1, num);
  return Math.floor(clamped);
}

// シーン初期化が完了するまで待機する
async function waitForSceneInitialization(){
  // Wait for any in-flight scene initialization to settle before proceeding.
  while (true) {
    const pending = sceneInitInFlight;
    if (!pending) {
      return;
    }
    await pending;
    if (sceneInitInFlight === pending) {
      return;
    }
  }
}
