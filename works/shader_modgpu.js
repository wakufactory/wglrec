// shader-chunk.js
// Full-screen WebGPU shader scene that assembles external WGSL chunks.

const UNIFORM_FLOAT_COUNT = 24; // 6 vec4 slots

// WebGPU シェーダーシーンを組み立ててコントローラを返す
export async function createSceneController({ canvas, width, height, log }) {
  if (!navigator.gpu) {
    throw new Error('WebGPU not supported in this environment');
  }

  const context = canvas.getContext('webgpu');
  if (!context) {
    throw new Error('Failed to acquire WebGPU canvas context');
  }

  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) {
    throw new Error('Unable to acquire WebGPU adapter');
  }

  const device = await adapter.requestDevice();
  const format = navigator.gpu.getPreferredCanvasFormat();

  let currentWidth = clampDimension(width);
  let currentHeight = clampDimension(height);

  configureContext(context, canvas, device, format, currentWidth, currentHeight);
  const detachDeviceErrorLogger = attachDeviceErrorLogger(device, log);

  const shaderSource = await loadShaderSources();
  const shaderModule = device.createShaderModule({ code: shaderSource });

  const pipelineDescriptor = {
    layout: 'auto',
    vertex: {
      module: shaderModule,
      entryPoint: 'vs_main'
    },
    fragment: {
      module: shaderModule,
      entryPoint: 'fs_main',
      targets: [{ format }]
    },
    primitive: { topology: 'triangle-list' }
  };

  let pipeline;
  const hasErrorScopes = typeof device.pushErrorScope === 'function' && typeof device.popErrorScope === 'function';
  if (hasErrorScopes) {
    device.pushErrorScope('validation');
    device.pushErrorScope('internal');
  }
  let validationError = null;
  let internalError = null;
  try {
    if (typeof device.createRenderPipelineAsync === 'function') {
      pipeline = await device.createRenderPipelineAsync(pipelineDescriptor);
    } else {
      pipeline = device.createRenderPipeline(pipelineDescriptor);
    }
  } catch (pipelineError) {
    if (hasErrorScopes) {
      try {
        internalError = await device.popErrorScope();
      } catch (_) {}
      try {
        validationError = await device.popErrorScope();
      } catch (_) {}
    }
    // Attempt to surface WGSL compiler diagnostics before rethrowing.
    await reportShaderCompilationMessages(shaderModule, log, { suppressThrow: true });
    if (typeof log === 'function') {
      const reason = pipelineError?.message || pipelineError;
      log(`[webgpu] Failed to create render pipeline: ${reason}`);
    }
    for (const error of [internalError, validationError]) {
      if (error && typeof log === 'function') {
        log(`[webgpu validation] ${error.message || error}`);
      }
    }
    throw pipelineError;
  }
  if (hasErrorScopes) {
    try {
      internalError = await device.popErrorScope();
    } catch (_) {}
    try {
      validationError = await device.popErrorScope();
    } catch (_) {}
    const scopedMessages = [internalError, validationError].filter(Boolean);
    if (scopedMessages.length && typeof log === 'function') {
      for (const error of scopedMessages) {
        const message = error?.message || error;
        log(`[webgpu validation] ${message}`);
      }
    }
  }

  await reportShaderCompilationMessages(shaderModule, log);

  const uniformValues = new Float32Array(UNIFORM_FLOAT_COUNT);
  let uniformDirty = true;
  initializeUniforms(uniformValues, currentWidth, currentHeight);

  const uniformBuffer = device.createBuffer({
    size: uniformValues.byteLength,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
  });

  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [{ binding: 0, resource: { buffer: uniformBuffer } }]
  });

  // シェーダー設定から受け取ったビューポート分割数を保持し、タイル描画で利用する
  let viewportGrid = resolveViewportGridSetting(globalThis.shader_settings);
  let activeTileSequence = null;

  // CPU側で変更したユニフォーム値をGPUバッファへ転送する
  function commitUniforms(rangeBytes = uniformValues.byteLength) {
    device.queue.writeBuffer(
      uniformBuffer,
      0,
      uniformValues.buffer,
      uniformValues.byteOffset,
      rangeBytes
    );
    uniformDirty = false;
  }

  // 画面解像度に依存するユニフォーム値を更新する
  function updateResolution(widthPx, heightPx) {
    uniformValues[4] = widthPx;
    uniformValues[5] = heightPx;
    uniformValues[6] = widthPx > 0 ? 1 / widthPx : 0;
    uniformValues[7] = heightPx > 0 ? 1 / heightPx : 0;
    uniformValues[2] = heightPx > 0 ? widthPx / heightPx : 1;
    uniformDirty = true;
  }

  // カメラ関連のユニフォーム値をまとめて設定する
  function setCameraUniforms({ position, target, up, fovY } = {}) {
    if (position) assignVec3(8, position);
    if (target) assignVec3(12, target);
    if (up) assignVec3(16, up);
    if (isFiniteNumber(fovY)) {
      uniformValues[20] = fovY;
    }
    uniformDirty = true;
  }

  const controller = {
    // worker から渡されるビューポートブロック単位でレンダリングを行う
    async renderFrame(timeSec, viewportBlock) {
      const viewport = normalizeViewportBlock(viewportBlock, currentWidth, currentHeight);

      uniformValues[0] = timeSec;
      uniformValues[1] = viewport.index;
      if (uniformDirty) {
        commitUniforms();
      }
      commitUniforms(16);

      const target = acquireTileTarget(viewport);
      const attachment = {
        view: target.view,
        loadOp: target.loadOp,
        storeOp: 'store'
      };
      if (attachment.loadOp === 'clear') {
        attachment.clearValue = { r: 0, g: 0, b: 0, a: 1 };
      }

      const encoder = device.createCommandEncoder();
      const pass = encoder.beginRenderPass({ colorAttachments: [attachment] });

      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindGroup);
      pass.setViewport(
        viewport.offsetX,
        viewport.offsetY,
        viewport.width,
        viewport.height,
        0,
        1
      );
      if (typeof pass.setScissorRect === 'function') {
        pass.setScissorRect(
          viewport.scissorX,
          viewport.scissorY,
          viewport.scissorWidth,
          viewport.scissorHeight
        );
      }
      pass.draw(3, 1, 0, 0);

      pass.end();
      let submitted = false;
      try {
        device.queue.submit([encoder.finish()]);
        submitted = true;
      } finally {
        if (!submitted && viewport.totalBlocks > 1) {
          releaseTileSequence();
        }
        target.release?.();
      }
    },

    // 画面サイズ変更に追随し、タイル状態もリセットする
    resize(nextWidth, nextHeight) {
      currentWidth = clampDimension(nextWidth);
      currentHeight = clampDimension(nextHeight);
      configureContext(context, canvas, device, format, currentWidth, currentHeight);
      updateResolution(currentWidth, currentHeight);
      releaseTileSequence();
    },

    // カメラパラメータをまとめて更新する
    setCamera(params = {}) {
      setCameraUniforms(params);
    },

    // GPUキューの完了を待つことで描画完了を保証する
    async waitForGpu() {
      await device.queue.onSubmittedWorkDone();
    },

    // バッファやリスナーを破棄してリソースリークを防ぐ
    dispose() {
      uniformBuffer.destroy();
      detachDeviceErrorLogger?.();
      releaseTileSequence();
    }
  };

  Object.defineProperty(controller, 'viewportGrid', {
    get() {
      return viewportGrid;
    },
    set(value) {
      viewportGrid = normalizeViewportGrid(value);
    }
  });
  controller.getViewportGrid = () => viewportGrid;
  controller.setViewportGrid = (value) => {
    viewportGrid = normalizeViewportGrid(value);
    return viewportGrid;
  };

  device.lost.then((info) => {
    if (typeof log === 'function') {
      const reason = info && info.reason ? info.reason : 'unknown';
      const message = info && info.message ? info.message : '';
      const extra = message ? ` ${message}` : '';
      log(`[webgpu] device lost: ${reason}${extra}`);
    }
  }).catch(() => {});

  updateResolution(currentWidth, currentHeight);
  commitUniforms();
  await controller.renderFrame(0);
  await controller.waitForGpu();

  return controller;

  // 必要なWGSLチャンクを読み込み一つの文字列に連結する
  async function loadShaderSources() {
    const parts = await Promise.all(
      globalThis.shader_settings.SHADER_CHUNK_FILES.map((name) => loadShaderChunk(name))
    );
    if(globalThis.shader_settings.SETTINGS) parts.unshift(globalThis.shader_settings.SETTINGS)
    return parts.join('\n');
  }

  // 指定チャンクファイルをフェッチしてWGSL文字列を取得する
  async function loadShaderChunk(filename) {
    const url = new URL(`./chunk/${filename}`, import.meta.url);
    url.searchParams.set('_', Date.now().toString());
    const response = await fetch(url, { cache: 'no-store' });
    if (!response.ok) {
      throw new Error(`Failed to load shader chunk ${filename} (status ${response.status})`);
    }
    return response.text();
  }

  // ユニフォームバッファ全体を既定値で初期化する
  function initializeUniforms(buffer, widthPx, heightPx) {
    buffer.fill(0);
    buffer[8] = 0.0;
    buffer[9] = 0.5;
    buffer[10] = 4.0;
    buffer[12] = 0.0;
    buffer[13] = -0.1;
    buffer[14] = -1.0;
    buffer[16] = 0.0;
    buffer[17] = 1.0;
    buffer[18] = 0.0;
    buffer[20] = 45.0;
    updateResolution(widthPx, heightPx);
  }

  // 数値が有限かどうかを判定する
  function isFiniteNumber(value) {
    return typeof value === 'number' && Number.isFinite(value);
  }

  // 任意の配列/オブジェクトからvec3成分をユニフォームへコピーする
  function assignVec3(baseIndex, source) {
    if (Array.isArray(source) || ArrayBuffer.isView(source)) {
      if (isFiniteNumber(source[0])) uniformValues[baseIndex + 0] = source[0];
      if (isFiniteNumber(source[1])) uniformValues[baseIndex + 1] = source[1];
      if (isFiniteNumber(source[2])) uniformValues[baseIndex + 2] = source[2];
      return;
    }
    const { x, y, z } = source ?? {};
    if (isFiniteNumber(x)) uniformValues[baseIndex + 0] = x;
    if (isFiniteNumber(y)) uniformValues[baseIndex + 1] = y;
    if (isFiniteNumber(z)) uniformValues[baseIndex + 2] = z;
  }

  // 現在のブロックに対応する render pass のターゲットと loadOp を決定する
  function acquireTileTarget(block) {
    const multiBlock = block && block.totalBlocks > 1;
    if (!multiBlock) {
      releaseTileSequence();
      const texture = context.getCurrentTexture();
      return {
        view: texture.createView(),
        loadOp: 'clear',
        release: () => {}
      };
    }

    if (
      block.isFirst ||
      !activeTileSequence ||
      activeTileSequence.expected !== block.totalBlocks
    ) {
      releaseTileSequence();
      const texture = context.getCurrentTexture();
      activeTileSequence = {
        view: texture.createView(),
        expected: block.totalBlocks,
        needsClear: true
      };
    }

    const shouldClear = block.isFirst || activeTileSequence.needsClear;
    activeTileSequence.needsClear = false;

    return {
      view: activeTileSequence.view,
      loadOp: shouldClear ? 'clear' : 'load',
      release: () => {
        if (block.isLast) {
          releaseTileSequence();
        }
      }
    };
  }

  // タイル描画用に握っているテクスチャ参照を破棄する
  function releaseTileSequence() {
    activeTileSequence = null;
  }
}

// WGSLコンパイル結果からエラー情報を収集してログに出す
async function reportShaderCompilationMessages(shaderModule, log, options = {}) {
  const { suppressThrow = false } = options ?? {};
  const hasLogger = typeof log === 'function';
  if (!shaderModule?.compilationInfo) {
    return;
  }
  let info;
  try {
    info = await shaderModule.compilationInfo();
  } catch (err) {
    if (hasLogger) {
      log(`[wgsl] Failed to inspect compilation info: ${err?.message || err}`);
    } else {
      console.error('[wgsl] Failed to inspect compilation info', err);
    }
    if (suppressThrow) {
      return;
    }
    throw err;
  }
  const messages = info?.messages || [];
  const errors = messages.filter((msg) => msg.type === 'error');
  if (!errors.length) {
    return;
  }
  const formatLocation = (msg) => {
    const parts = [];
    if (Number.isFinite(msg.lineNum)) parts.push(`line ${msg.lineNum}`);
    if (Number.isFinite(msg.linePos)) parts.push(`col ${msg.linePos}`);
    if (parts.length === 0) return '';
    return ` (${parts.join(':')})`;
  };
  if (hasLogger) {
    for (const msg of errors) {
      const prefix = `[wgsl ${msg.type || 'info'}]`;
      const detail = msg.message || 'WGSL compilation error';
      log(`${prefix}${formatLocation(msg)} ${detail}`.trim());
    }
  } else {
    console.error('[wgsl] compilation failed', errors);
  }
  if (suppressThrow) {
    return errors;
  }
  throw new Error('WGSL shader compilation failed; see log output for details.');
}

// CanvasContextを指定のフォーマット・サイズで設定する
function configureContext(context, canvas, device, format, width, height) {
  canvas.width = width;
  canvas.height = height;
  context.configure({
    device,
    format,
    alphaMode: 'opaque',
    usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
    size: { width, height }
  });
}

// 数値を1以上の整数ピクセルへ正規化する
function clampDimension(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) {
    return 1;
  }
  return Math.max(1, Math.floor(n));
}

// workerから渡されたブロック情報を安全なビューポートに変換する
function normalizeViewportBlock(info, frameWidth, frameHeight) {
  const widthLimit = Math.max(1, clampDimension(frameWidth));
  const heightLimit = Math.max(1, clampDimension(frameHeight));
  if (!info || typeof info !== 'object') {
    return {
      index: 0,
      column: 0,
      row: 0,
      columns: 1,
      rows: 1,
      totalBlocks: 1,
      isFirst: true,
      isLast: true,
      offsetX: 0,
      offsetY: 0,
      width: widthLimit,
      height: heightLimit,
      scissorX: 0,
      scissorY: 0,
      scissorWidth: widthLimit,
      scissorHeight: heightLimit,
      canvasWidth: widthLimit,
      canvasHeight: heightLimit
    };
  }

  const columns = clampDimension(info.columns ?? info.cols ?? info.xSegments ?? 1);
  const rows = clampDimension(info.rows ?? info.lines ?? info.ySegments ?? 1);
  const totalBlocks = Math.max(1, columns * rows);
  const rawIndex = Math.floor(info.index ?? 0);
  const index = Math.min(totalBlocks - 1, Math.max(0, rawIndex));
  const offsetX = clampViewportOffset(info.offsetX ?? info.x ?? 0, widthLimit);
  const offsetY = clampViewportOffset(info.offsetY ?? info.y ?? 0, heightLimit);
  const widthPx = clampViewportExtent(info.width ?? widthLimit, widthLimit - offsetX);
  const heightPx = clampViewportExtent(info.height ?? heightLimit, heightLimit - offsetY);
  const column = Math.min(columns - 1, Math.max(0, Math.floor(info.column ?? (index % columns))));
  const row = Math.min(rows - 1, Math.max(0, Math.floor(info.row ?? Math.floor(index / columns))));
  const isFirst = Boolean(info.isFirst ?? (index === 0));
  const isLast = Boolean(info.isLast ?? (index === totalBlocks - 1));

  return {
    index,
    column,
    row,
    columns,
    rows,
    totalBlocks,
    isFirst,
    isLast,
    offsetX,
    offsetY,
    width: widthPx,
    height: heightPx,
    scissorX: offsetX,
    scissorY: offsetY,
    scissorWidth: widthPx,
    scissorHeight: heightPx,
    canvasWidth: widthLimit,
    canvasHeight: heightLimit
  };
}

// ビューポート開始位置をキャンバス範囲内へ丸める
function clampViewportOffset(value, limit) {
  const num = Number(value);
  if (!Number.isFinite(num)) {
    return 0;
  }
  const max = Math.max(0, limit - 1);
  return Math.min(max, Math.max(0, Math.floor(num)));
}

// ビューポートサイズを残り領域に収まるよう制限する
function clampViewportExtent(value, available) {
  const fallback = Math.max(1, available || 1);
  const num = Number(value);
  if (!Number.isFinite(num) || num <= 0) {
    return fallback;
  }
  return Math.max(1, Math.min(Math.floor(num), fallback));
}

// グローバル設定から初期グリッド数を決定する
function resolveViewportGridSetting(settings) {
  if (settings?.VIEWPORT_GRID) {
    return normalizeViewportGrid(settings.VIEWPORT_GRID);
  }
  return normalizeViewportGrid();
}

// 列・行情報を正規化し不変オブジェクトとして返す
function normalizeViewportGrid(source) {
  const columns = clampDimension(pickViewportValue(source, ['columns', 'cols', 'x', 'width'], 1));
  const rows = clampDimension(pickViewportValue(source, ['rows', 'lines', 'y', 'height'], 1));
  return Object.freeze({
    columns,
    rows,
    totalBlocks: Math.max(1, columns * rows)
  });
}

// 指定キー配列の中から最初に見つかった値を取得する
function pickViewportValue(source, keys, fallback) {
  if (!source) {
    return fallback;
  }
  for (const key of keys) {
    if (source[key] != null) {
      return source[key];
    }
  }
  return fallback;
}

// Deviceのuncapturederrorを拾ってログへ流す
function attachDeviceErrorLogger(device, log) {
  if (!device || typeof device.addEventListener !== 'function') {
    return null;
  }
  const handler = (event) => {
    const error = event?.error;
    const message = error?.message || error;
    if (typeof log === 'function') {
      log(`[webgpu uncaptured] ${message}`);
    } else {
      console.error('[webgpu uncaptured error]', error);
    }
  };
  device.addEventListener('uncapturederror', handler);
  return () => {
    try {
      device.removeEventListener('uncapturederror', handler);
    } catch (_) {
      // Ignore cleanup errors; device may already be lost.
    }
  };
}
