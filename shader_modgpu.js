// shader-chunk.js
// Full-screen WebGPU shader scene that assembles external WGSL chunks.

const UNIFORM_FLOAT_COUNT = 24; // 6 vec4 slots

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

  function updateResolution(widthPx, heightPx) {
    uniformValues[4] = widthPx;
    uniformValues[5] = heightPx;
    uniformValues[6] = widthPx > 0 ? 1 / widthPx : 0;
    uniformValues[7] = heightPx > 0 ? 1 / heightPx : 0;
    uniformValues[2] = heightPx > 0 ? widthPx / heightPx : 1;
    uniformDirty = true;
  }

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
    async renderFrame(timeSec) {
      uniformValues[0] = timeSec;
      if (uniformDirty) {
        commitUniforms();
      }

      const textureView = context.getCurrentTexture().createView();
      const encoder = device.createCommandEncoder();
      const pass = encoder.beginRenderPass({
        colorAttachments: [{
          view: textureView,
          clearValue: { r: 0, g: 0, b: 0, a: 1 },
          loadOp: 'clear',
          storeOp: 'store'
        }]
      });

      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindGroup);

        uniformValues[1] = 0;
        commitUniforms(16);
        pass.setViewport(0, 0, currentWidth, currentHeight, 0, 1);
        pass.draw(3, 1, 0, 0);

      pass.end();
      device.queue.submit([encoder.finish()]);
    },

    resize(nextWidth, nextHeight) {
      currentWidth = clampDimension(nextWidth);
      currentHeight = clampDimension(nextHeight);
      configureContext(context, canvas, device, format, currentWidth, currentHeight);
      updateResolution(currentWidth, currentHeight);
    },

    setCamera(params = {}) {
      setCameraUniforms(params);
    },

    async waitForGpu() {
      await device.queue.onSubmittedWorkDone();
    },

    dispose() {
      uniformBuffer.destroy();
      detachDeviceErrorLogger?.();
    }
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

  async function loadShaderSources() {
    const parts = await Promise.all(
      globalThis.shader_settings.SHADER_CHUNK_FILES.map((name) => loadShaderChunk(name))
    );
    if(globalThis.shader_settings.SETTINGS) parts.unshift(globalThis.shader_settings.SETTINGS)
    return parts.join('\n');
  }

  async function loadShaderChunk(filename) {
    const url = new URL(`./chunk/${filename}`, import.meta.url);
    url.searchParams.set('_', Date.now().toString());
    const response = await fetch(url, { cache: 'no-store' });
    if (!response.ok) {
      throw new Error(`Failed to load shader chunk ${filename} (status ${response.status})`);
    }
    return response.text();
  }

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

  function isFiniteNumber(value) {
    return typeof value === 'number' && Number.isFinite(value);
  }

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
}

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

function clampDimension(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) {
    return 1;
  }
  return Math.max(1, Math.floor(n));
}

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
