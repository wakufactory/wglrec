// tsl-temlate.js
// Full-screen shader scene implemented with Three.js WebGPU renderer + TSL nodes.
import {
  WebGPURenderer,
  Scene,
  OrthographicCamera,
  PlaneGeometry,
  Mesh,
  Vector2,
  MeshBasicNodeMaterial,
  TSL 
} from 'https://cdn.jsdelivr.net/npm/three@0.180.0/build/three.webgpu.js';

const {
  uniform,
  vec2,
  vec3,
  mix,
  smoothstep,
  sin,
  length,
  uv,
  screenCoordinate
} = TSL;

export async function createSceneController({ canvas, width, height }) {
  const renderer = new WebGPURenderer({
    canvas,
    antialias: true,
    alpha: false
  });
  renderer.setPixelRatio(1);
  renderer.setSize(width, height, false);
  await renderer.init();

  const scene = new Scene();
  const camera = new OrthographicCamera(-1, 1, 1, -1, 0, 1);
  camera.position.z = 0;

  const timeUniform = uniform(0).setName('uTime');
  const resolutionUniform = uniform(new Vector2(width, height)).setName('uResolution');

  const uvNode = uv();
  const gradient = smoothstep(0.0, 1.0, uvNode.y);

  const wave = sin(
    uvNode.x.add(uvNode.y).mul(10.0).add(timeUniform.mul(1.5))
  ).mul(0.5).add(0.5);

  const base = mix(
    vec3(0.08, 0.14, 0.35),
    vec3(0.9, 0.55, 0.2),
    gradient
  );

  const st = screenCoordinate.div(resolutionUniform);
  const vignette = smoothstep(
    1.2,
    0.3,
    length(st.sub(vec2(0.5, 0.5))).mul(2.0)
  );

  const finalColor = mix(
    base,
    vec3(0.2, 0.8, 0.7),
    wave
  ).mul(vignette);

  const nodeMaterial = new MeshBasicNodeMaterial();
  nodeMaterial.colorNode = finalColor;
  nodeMaterial.depthTest = false;
  nodeMaterial.depthWrite = false;

  const quad = new Mesh(new PlaneGeometry(2, 2), nodeMaterial);
  scene.add(quad);

  async function renderFrame(tSec) {
    timeUniform.value = tSec;
    await renderer.renderAsync(scene, camera);
  }

  function resize(nextWidth, nextHeight) {
    renderer.setSize(nextWidth, nextHeight, false);
    resolutionUniform.value.set(nextWidth, nextHeight);
  }

  await renderFrame(0);

  return {
    renderer,
    renderFrame,
    resize
  };
}
