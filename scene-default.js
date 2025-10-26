// scene-default.js
// Export a reusable Three.js scene setup that the worker can swap out.
import * as THREE from 'https://cdn.jsdelivr.net/npm/three@0.180.0/build/three.module.js';

export async function createSceneController({ canvas, width, height }) {
  // Acquire WebGL2 context and configure renderer
  const gl = canvas.getContext('webgl2', {
    antialias: true,
    preserveDrawingBuffer: true,
    alpha: false
  });
  if (!gl) {
    throw new Error('WebGL2 context not available');
  }

  const renderer = new THREE.WebGLRenderer({
    canvas,
    context: gl,
    antialias: true,
    preserveDrawingBuffer: true,
    alpha: false
  });
  renderer.setSize(width, height, false);
  renderer.setPixelRatio(1);

  // Scene graph with a simple animated torus knot and helpers
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x000000);

  const camera = new THREE.PerspectiveCamera(45, width / height, 0.1, 100);
  camera.position.set(0, 1.0, 3.5);

  const geo = new THREE.TorusKnotGeometry(0.7, 0.28, 256, 48);
  const mat = new THREE.MeshStandardMaterial({
    color: 0x66ccff,
    metalness: 0.2,
    roughness: 0.3
  });
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

  renderer.setClearColor(scene.background, 1);

  function renderFrame(tSec) {
    const target = scene.getObjectByName('torus');
    if (target) {
      target.rotation.x = tSec * 0.9;
      target.rotation.y = tSec * 1.2;
      const hue = (tSec * 0.05) % 1.0;
      const color = new THREE.Color().setHSL(hue, 0.6, 0.55);
      target.material.color.copy(color);
    }
    camera.lookAt(0, 0, 0);
    renderer.render(scene, camera);
  }

  function resize(nextWidth, nextHeight) {
    renderer.setSize(nextWidth, nextHeight, false);
    camera.aspect = nextWidth / nextHeight;
    camera.updateProjectionMatrix();
  }

  // Draw once so downstream consumers can rely on an initialized frame.
  renderFrame(0);

  return {
    renderer,
    renderFrame,
    resize
  };
}
