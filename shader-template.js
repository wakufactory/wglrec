// shader-template.js
// Provide a minimal full-screen shader scene matching the default scene interface.
import * as THREE from 'https://cdn.jsdelivr.net/npm/three@0.180.0/build/three.module.js';

export async function createSceneController({ canvas, width, height }) {
  // Initialize shared WebGL2 renderer resources
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

  const scene = new THREE.Scene();

  // Ortographic camera with clip space quad coordinates
  const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
  camera.position.z = 0;

  const uniforms = {
    uTime: { value: 0 },
    uResolution: { value: new THREE.Vector2(width, height) }
  };

  const planeGeometry = new THREE.PlaneGeometry(2, 2);
  const shaderMaterial = new THREE.ShaderMaterial({
    uniforms,
    vertexShader: `
      varying vec2 vUv;
      void main() {
        vUv = uv;
        gl_Position = vec4(position, 1.0);
      }
    `,
    fragmentShader: `
      precision highp float;

      varying vec2 vUv;
      uniform float uTime;
      uniform vec2 uResolution;

      void main() {
        vec2 uv = vUv;
        float gradient = smoothstep(0.0, 1.0, uv.y);
        float wave = 0.5 + 0.5 * sin((uv.x + uv.y) * 10.0 + uTime * 1.5);
        vec3 base = mix(vec3(0.08, 0.14, 0.35), vec3(0.9, 0.55, 0.2), gradient);
        vec2 st = gl_FragCoord.xy / uResolution.xy;
        float vignette = smoothstep(1.2, 0.3, length(st - 0.5) * 2.0);
        vec3 color = mix(base, vec3(0.2, 0.8, 0.7), wave) * vignette;
        gl_FragColor = vec4(color, 1.0);
      }
    `,
    depthTest: false
  });

  const quad = new THREE.Mesh(planeGeometry, shaderMaterial);
  scene.add(quad);

  function renderFrame(tSec) {
    uniforms.uTime.value = tSec;
    renderer.render(scene, camera);
  }

  function resize(nextWidth, nextHeight) {
    renderer.setSize(nextWidth, nextHeight, false);
    uniforms.uResolution.value.set(nextWidth, nextHeight);
  }

  renderFrame(0);

  return {
    renderer,
    renderFrame,
    resize
  };
}
