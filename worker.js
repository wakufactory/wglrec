// worker.js (module worker)
// three.js を OffscreenCanvas 上で駆動し、フレーム毎に WebCodecs へ投入。
// 任意秒の1フレームプレビューは ImageBitmap をメインへ転送。

/* ===================== 依存CDN =====================
 * three.js:           r159 以降を想定
 * webm-muxer:         https://github.com/Vanilagy/webm-muxer
 * いずれも ESM を import します（Module Worker）。
 * ブラウザは Chrome 系の最新を想定（WebCodecs / OffscreenCanvas）。
 * ================================================== */
import * as THREE from 'https://cdn.jsdelivr.net/npm/three@0.159.0/build/three.module.js';
import { Muxer, ArrayBufferTarget } from 'https://cdn.jsdelivr.net/npm/webm-muxer@3.2.1/build/webm-muxer.mjs';

console.log('[worker] script evaluated top-level');

// ====== レンダリング関連の状態 ======
let canvas;             // OffscreenCanvas（メインからtransfer）
let width = 1280, height = 720;
let renderer;           // THREE.WebGLRenderer
let scene, camera, clock;
let ready = false;

// ====== エンコード関連 ======
let encoder = null;
let muxer = null;               // webm-muxer
let muxTarget = null;           // ArrayBufferTarget（Output buffer）
let fps = 30;
let keyframeIntervalSec = 2;
let bitrate = 6_000_000;
let debugSampleCount = 0;
let colorSpace = 'srgb';
let previewCanvas2D = null;
let previewCtx2D = null;
let previewPixelBuffer = null;

// ====== 汎用ログ ======
const log = (m) => {
  console.log('[worker]', m);
  postMessage({ type:'log', message: String(m) });
};

// ====== メッセージ受付 ======
self.onmessage = async (ev) => {
  const msg = ev.data;
  try {
    if (msg.type === 'init') {
      canvas = msg.canvas;
      width = canvas.width; height = canvas.height;
      await initThree();
      ready = true;
      log('Worker initialized.');
    } else if (msg.type === 'resize') {
      width = msg.width|0; height = msg.height|0;
      log(`Resize received => ${width}x${height}`);
      if (canvas) {
        canvas.width = width;
        canvas.height = height;
      }
      if (renderer) {
        renderer.setSize(width, height, false);
        camera.aspect = width / height;
        camera.updateProjectionMatrix();
      }
    } else if (msg.type === 'preview') {
      // 指定時刻（秒）の1フレームを描いて ImageBitmap を送る
      ensureReady();
      const t = Math.max(0, +msg.timeSec || 0);
      fps = Math.max(1, +msg.fps || 30);
      log(`Preview request t=${t.toFixed(3)} fps=${fps} size=${width}x${height}`);
      colorSpace = msg.colorSpace || 'srgb';
      await renderAtTime(t);
      debugSample('preview');
      const bmp = await captureBitmap();
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
      postMessage({ type:'preview', bitmap: bmp, timeSec: t, width, height }, [bmp]);
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
    }
  } catch (e) {
    postMessage({ type:'error', message: e?.stack || String(e) });
  }
};

// ====== three.js 初期化 ======
async function initThree(){
  // OffscreenCanvas を用いて WebGL 上下文を取得（antialiasは任意）
  const gl = canvas.getContext('webgl2', { antialias: true, preserveDrawingBuffer: true, alpha: false });
  if (!gl) throw new Error('WebGL2 context not available');

  renderer = new THREE.WebGLRenderer({
    canvas,
    context: gl,
    antialias: true,
    preserveDrawingBuffer: true,  // プレビューの ImageBitmap 取得を安定させる
    alpha: false
  });
  renderer.setSize(width, height, false);
  renderer.setPixelRatio(1);       // 動画向け：1固定で安定化
  renderer.setClearColor(scene?.background || 0x000000, 1);

  // シーン例：重めのフラグメント処理の代わりに、簡易オブジェクト群＆ポストなし
  scene = new THREE.Scene();
  scene.background = new THREE.Color(0x000000);

  camera = new THREE.PerspectiveCamera(45, width/height, 0.1, 100);
  camera.position.set(0, 1.0, 3.5);

  // 簡単なオブジェクト：回転トーラス＆床グリッド
  const geo = new THREE.TorusKnotGeometry(0.7, 0.28, 256, 48);
  const mat = new THREE.MeshStandardMaterial({ color: 0x66ccff, metalness: 0.2, roughness: 0.3 });
  const torus = new THREE.Mesh(geo, mat);
  torus.name = 'torus';
  scene.add(torus);

  const grid = new THREE.GridHelper(8, 16, 0x444444, 0x222222);
  grid.position.y = -1.0;
  scene.add(grid);

  const hemi = new THREE.HemisphereLight(0xffffff, 0x222233, 1.0);
  scene.add(hemi);

  const dir = new THREE.DirectionalLight(0xffffff, 0.8);
  dir.position.set(3, 4, 2);
  scene.add(dir);

  clock = new THREE.Clock(false); // 自動進行は使わない（決定的にtimeを渡す）

  // 決定的進行のために、任意時刻 t を明示的に渡す draw を用意
  drawScene(0);
}

// t（秒）に基づいて「同じ結果」を描く（乱数は固定化推奨）
function drawScene(tSec){
  // 例：時間でアニメする（トーラス回転＋色相バイアス）
  const torus = scene.getObjectByName('torus');
  if (torus){
    torus.rotation.x = tSec * 0.9;
    torus.rotation.y = tSec * 1.2;
    const hue = (tSec * 0.05) % 1.0;
    const color = new THREE.Color().setHSL(hue, 0.6, 0.55);
    torus.material.color.copy(color);
  }
  camera.lookAt(0,0,0);
  renderer.render(scene, camera);
}

// 任意時刻 t（秒）で1フレームだけ描画
async function renderAtTime(tSec){
  drawScene(tSec);
  await waitForGpu();
}

// ====== オフライン 1フレームずつ → WebCodecs へ投入 ======
async function renderAndEncode(totalFrames){
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
    drawScene(t);               // three.js を t 秒でレンダ
    await waitForGpu();
    if (i === 0) debugSample('render-loop');
    debugSample(`frame ${i}`);

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
  if (!renderer) return;
  const gl = renderer.getContext();
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
  if (debugSampleCount++ > 8) return;
  if (!renderer) return;
  const gl = renderer.getContext();
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
  if (!renderer) throw new Error('Renderer not ready');
  const gl = renderer.getContext();
  if (!gl) throw new Error('WebGL context missing');
  if (!previewCanvas2D || previewCanvas2D.width !== width || previewCanvas2D.height !== height){
    previewCanvas2D = new OffscreenCanvas(width, height);
    previewCtx2D = previewCanvas2D.getContext('2d');
    previewPixelBuffer = null;
  }
  if (!previewCtx2D) throw new Error('2D context unavailable for preview');

  const size = width * height * 4;
  if (!previewPixelBuffer || previewPixelBuffer.length !== size){
    previewPixelBuffer = new Uint8Array(size);
  }

  gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, previewPixelBuffer);

  const imageData = previewCtx2D.createImageData(width, height);
  const dst = imageData.data;
  const rowSize = width * 4;
  for (let y = 0; y < height; y++){
    const srcOffset = (height - 1 - y) * rowSize;
    const dstOffset = y * rowSize;
    dst.set(previewPixelBuffer.subarray(srcOffset, srcOffset + rowSize), dstOffset);
  }
  previewCtx2D.putImageData(imageData, 0, 0);
  return await createImageBitmap(previewCanvas2D);
}
