// shader-template.js
// WebGPU full-screen shader scene matching the worker scene controller interface.

export async function createSceneController({ canvas, width, height, log }) {
  const nav = globalThis.navigator;
  if (!nav || !nav.gpu) {
    throw new Error('WebGPU not supported in this environment');
  }

  const context = canvas.getContext('webgpu');
  if (!context) {
    throw new Error('Failed to acquire WebGPU canvas context');
  }

  const adapter = await nav.gpu.requestAdapter();
  if (!adapter) {
    throw new Error('Unable to acquire WebGPU adapter');
  }

  const device = await adapter.requestDevice();
  const format = nav.gpu.getPreferredCanvasFormat();

  let currentWidth = clampDimension(width);
  let currentHeight = clampDimension(height);

  configureContext(context, canvas, device, format, currentWidth, currentHeight);

  // Uniform buffer layout: vec4(time, width, height, padding)
  const uniformValues = new Float32Array(4);
  uniformValues[1] = currentWidth;
  uniformValues[2] = currentHeight;

  const uniformBuffer = device.createBuffer({
    size: uniformValues.byteLength,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
  });

  const shaderModule = device.createShaderModule({
    code: `
      struct Uniforms {
        data : vec4<f32>
      };
      @group(0) @binding(0) var<uniform> uniforms : Uniforms;

      @vertex
      fn vs_main(@builtin(vertex_index) vertexIndex : u32) -> @builtin(position) vec4<f32> {
        var positions = array<vec2<f32>, 3>(
          vec2<f32>(-1.0, -3.0),
          vec2<f32>(-1.0,  1.0),
          vec2<f32>( 3.0,  1.0)
        );
        return vec4<f32>(positions[vertexIndex], 0.0, 1.0);
      }

      @fragment
      fn fs_main(@builtin(position) fragCoord : vec4<f32>) -> @location(0) vec4<f32> {
        let time = uniforms.data.x;
        let resolution = uniforms.data.yz;
        let safeResolution = max(resolution, vec2<f32>(1.0, 1.0));
        let uv = fragCoord.xy / safeResolution;
        let gradient = smoothstep(0.0, 1.0, uv.y);
        let wave = 0.5 + 0.5 * sin((uv.x + uv.y) * 10.0 + time * 1.5);
        let base = mix(vec3<f32>(0.08, 0.14, 0.35), vec3<f32>(0.9, 0.55, 0.2), gradient);
        let st = fragCoord.xy / safeResolution;
        let vignette = smoothstep(1.2, 0.3, length(st - vec2<f32>(0.5, 0.5)) * 2.0);
        let accent = vec3<f32>(0.2, 0.8, 0.7);
        let color = mix(base, accent, wave) * vignette;
        return vec4<f32>(color, 1.0);
      }
    `
  });

  const pipeline = device.createRenderPipeline({
    layout: 'auto',
    vertex: {
      module: shaderModule,
      entryPoint: 'vs_main'
    },
    fragment: {
      module: shaderModule,
      entryPoint: 'fs_main',
      targets: [
        { format }
      ]
    },
    primitive: {
      topology: 'triangle-list'
    }
  });

  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      {
        binding: 0,
        resource: { buffer: uniformBuffer }
      }
    ]
  });

  device.lost.then((info) => {
    if (typeof log === 'function') {
      const reason = info && info.reason ? info.reason : 'unknown';
      const message = info && info.message ? info.message : '';
      const extra = message ? ` ${message}` : '';
      log(`[webgpu] device lost: ${reason}${extra}`);
    }
  }).catch(() => {});

  async function renderFrame(timeSec) {
    uniformValues[0] = timeSec;
    uniformValues[1] = currentWidth;
    uniformValues[2] = currentHeight;
    device.queue.writeBuffer(uniformBuffer, 0, uniformValues.buffer, uniformValues.byteOffset, uniformValues.byteLength);

    const textureView = context.getCurrentTexture().createView();
    const encoder = device.createCommandEncoder();
    const pass = encoder.beginRenderPass({
      colorAttachments: [
        {
          view: textureView,
          clearValue: { r: 0, g: 0, b: 0, a: 1 },
          loadOp: 'clear',
          storeOp: 'store'
        }
      ]
    });

    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindGroup);
    pass.draw(3, 1, 0, 0);
    pass.end();

    device.queue.submit([encoder.finish()]);
  }

  function resize(nextWidth, nextHeight) {
    currentWidth = clampDimension(nextWidth);
    currentHeight = clampDimension(nextHeight);
    uniformValues[1] = currentWidth;
    uniformValues[2] = currentHeight;
    configureContext(context, canvas, device, format, currentWidth, currentHeight);
  }

  async function waitForGpu() {
    await device.queue.onSubmittedWorkDone();
  }

  function dispose() {
    uniformBuffer.destroy();
  }

  await renderFrame(0);
  await waitForGpu();

  return {
    renderFrame,
    resize,
    waitForGpu,
    dispose
  };
}

function clampDimension(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) {
    return 1;
  }
  return Math.max(1, Math.floor(n));
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
