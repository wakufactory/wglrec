// shader-path.js
// Full-screen path tracing sample using Three.js with a fragment shader.
import * as THREE from 'https://cdn.jsdelivr.net/npm/three@0.180.0/build/three.module.js';

//shaders 
const SHADER_CHUNK_FILES = [
  'path1-environment.glsl',
  'path1-common.glsl',
  'path1-scene.glsl'
];
//settings
const stereo = 0.5; // if not zero, stereo rendering IPD

export async function createSceneController({ canvas, width, height, log }) {
  const gl = canvas.getContext('webgl2', {
    antialias: false,
    preserveDrawingBuffer: true,
    alpha: false
  });
  if (!gl) {
    throw new Error('WebGL2 context not available');
  }
  // WebGLコンテキスト取得後にエラーフックを仕込む
  installShaderErrorHooks(gl, log);

  const renderer = new THREE.WebGLRenderer({
    canvas,
    context: gl,
    antialias: false,
    preserveDrawingBuffer: true,
    alpha: false
  });
  renderer.setSize(width, height, false);
  renderer.setPixelRatio(1);
  renderer.autoClear = false;
  if (renderer.debug) {
    renderer.debug.checkShaderErrors = false;
  }

  const scene = new THREE.Scene();
  const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);

  const uniforms = {
    uTime: { value: 0 },
    uResolution: { value: new THREE.Vector2(width, height) },
    uCameraPos: { value: new THREE.Vector3(0.0, 0.5, 4.0) },
    uCameraTarget: { value: new THREE.Vector3(0.0, -0.1, -1.0) },
    uCameraUp: { value: new THREE.Vector3(0.0, 1.0, 0.0) },
    uCameraFovY: { value: 45.0 },
    uStereoEye: { value:0. }
  };

  const { vertex: vertexShader, fragment: fragmentShader } = await loadShaderSources(log);

  let shaderMaterial;
  try {
    shaderMaterial = new THREE.ShaderMaterial({
      uniforms,
      vertexShader,
      fragmentShader,
      depthTest: false
    });
  } catch (err) {
    log?.(`ShaderMaterial creation failed: ${err?.message || err}`);
    throw err;
  }

  const quad = new THREE.Mesh(
    new THREE.PlaneGeometry(2, 2),
    shaderMaterial
  );

  scene.add(quad);

  try {
    renderer.compile(scene, camera);
  } catch (err) {
    log?.(`Shader compile failed: ${err?.message || err}`);
    emitShaderDiagnostics(renderer, log);
    throw err;
  }
  // コンパイル時にThree.jsが溜めた診断ログを反映
  emitShaderDiagnostics(renderer, log);
  assertShaderProgramsRunnable(renderer, log);

  async function renderFrame(tSec) {
    uniforms.uTime.value = tSec;
    try {
      if(stereo==0) 
        renderer.render(scene, camera);
      else {
        const w = uniforms.uResolution.value.x/2 ;
        const h = uniforms.uResolution.value.y ;
        uniforms.uStereoEye.value = -stereo/2 ;
        renderer.setViewport(0,0,w,h)   
        renderer.render(scene, camera);
        uniforms.uStereoEye.value = stereo/2 ;
        renderer.setViewport(w,0,w,h)   
        renderer.render(scene, camera);
      }
    } catch (err) {
      log?.(`Shader render failed: ${err?.message || err}`);
      emitShaderDiagnostics(renderer, log);
      const glContext = renderer?.getContext?.();
      const glError = glContext?.getError?.();
      if (glError && glContext && glError !== glContext.NO_ERROR) {
        log?.(`WebGL error code: 0x${glError.toString(16)}`);
      }
      throw err;
    }
  }

  function assignVec3Uniform(uniform, value) {
    if (!value) return;
    if (Array.isArray(value)) {
      const [x = uniform.value.x, y = uniform.value.y, z = uniform.value.z] = value;
      uniform.value.set(x, y, z);
      return;
    }
    if (value.isVector3 === true || value instanceof THREE.Vector3) {
      uniform.value.copy(value);
      return;
    }
    const {
      x = uniform.value.x,
      y = uniform.value.y,
      z = uniform.value.z
    } = value;
    uniform.value.set(x, y, z);
  }

  function setCamera({
    position,
    target,
    up,
    fovY
  } = {}) {
    assignVec3Uniform(uniforms.uCameraPos, position);
    assignVec3Uniform(uniforms.uCameraTarget, target);
    assignVec3Uniform(uniforms.uCameraUp, up);
    if (typeof fovY === 'number') {
      uniforms.uCameraFovY.value = fovY;
    }
  }

  function resize(nextWidth, nextHeight) {
    renderer.setSize(nextWidth, nextHeight, false);
    uniforms.uResolution.value.set(nextWidth, nextHeight);
  }

  await renderFrame(0);

  return {
    renderer,
    renderFrame,
    resize,
    setCamera
  };
}

const VERTEX_SHADER_SOURCE = `
  out vec2 vUv;

  void main() {
    vUv = vec2(uv.x, uv.y);
    gl_Position = vec4(position, 1.0);
  }
`;

async function loadShaderChunk(filename) {
  // GLSLチャンクをキャッシュ無効で読み込み
  const url = new URL(`./chunk/${filename}`, import.meta.url);
  url.searchParams.set('_', Date.now().toString());
  const response = await fetch(url, { cache: 'no-store' });
  if (!response.ok) {
    throw new Error(`Failed to load shader chunk ${filename} (status ${response.status})`);
  }
  return response.text();
}

/**
 * GLSLチャンク群をまとめて取得し、失敗時はlog経由でエラー内容を通知して例外を投げる。
 * 非同期処理のどこで失敗したかを特定しやすくするため、catch節で明示的にログ出力する。
 */
async function loadShaderSources(log) {
  try {
    const fragmentChunks = await Promise.all(
      SHADER_CHUNK_FILES.map((name) => loadShaderChunk(name))
    );
    return {
      vertex: VERTEX_SHADER_SOURCE,
      fragment: fragmentChunks.join('\n')
    };
  } catch (err) {
    log?.(`Shader source load failed: ${err?.message || err}`);
    throw err;
  }
}

/**
 * WebGLコンテキストにフックを差し込み、コンパイル／リンク／検証時のログをlogへ流す。
 * Three.js内部で捕まえきれないネイティブエラーも拾えるように、各種APIをラップする。
 */
function installShaderErrorHooks(gl, log) {
  if (!gl || gl.__shaderHooksInstalled) {
    return;
  }

  // WebGLのコンパイル／リンクエラーをlogコールバックへ転送する共通処理
  const getShaderTypeLabel = (shader) => {
    if (!shader || typeof gl.getShaderParameter !== 'function') {
      return 'unknown shader';
    }
    const type = gl.getShaderParameter(shader, gl.SHADER_TYPE);
    switch (type) {
      case gl.VERTEX_SHADER:
        return 'vertex shader';
      case gl.FRAGMENT_SHADER:
        return 'fragment shader';
      default:
        return `shader type 0x${Number(type).toString(16)}`;
    }
  };

  const wrapInfoGetter = (method, label, makeLabel) => {
    const original = gl[method];
    if (typeof original !== 'function') {
      return;
    }
    const bound = original.bind(gl);
    gl[method] = function wrapped(target) {
      const result = bound(target);
      const text = typeof result === 'string' ? result.trim() : '';
      if (text) {
        const resolvedLabel = typeof makeLabel === 'function'
          ? makeLabel(target, text)
          : label;
        log?.(`${resolvedLabel}: ${text}`);
      }
      return result;
    };
  };

  // シェーダー単位のコンパイルログを取得するたびにフックする
  wrapInfoGetter('getShaderInfoLog', 'WebGL shader log', (shader) => {
    const typeLabel = getShaderTypeLabel(shader);
    return `WebGL shader log (${typeLabel})`;
  });
  // プログラム単位のリンク／検証ログも同様にフック
  wrapInfoGetter('getProgramInfoLog', 'WebGL program log');

  const linkProgram = typeof gl.linkProgram === 'function' ? gl.linkProgram.bind(gl) : null;
  if (linkProgram) {
    gl.linkProgram = function wrappedLink(program) {
      // Three.js内部からリンクが呼ばれたタイミングでエラー情報を吸い上げる
      linkProgram(program);
      const linked = typeof gl.getProgramParameter === 'function'
        ? gl.getProgramParameter(program, gl.LINK_STATUS)
        : true;
      if (!linked) {
        if (typeof gl.getAttachedShaders === 'function') {
          try {
            const shaders = gl.getAttachedShaders(program) || [];
            shaders.forEach((shader) => {
              const compiled = typeof gl.getShaderParameter === 'function'
                ? gl.getShaderParameter(shader, gl.COMPILE_STATUS)
                : true;
              if (compiled === false) {
                // リンク失敗時に該当シェーダーのログ取得を強制する
                gl.getShaderInfoLog?.(shader);
              }
            });
          } catch (err) {
            log?.(`WebGL getAttachedShaders failed: ${err?.message || err}`);
          }
        }
        const info = typeof gl.getProgramInfoLog === 'function'
          ? gl.getProgramInfoLog(program)
          : '';
        const text = typeof info === 'string' ? info.trim() : '';
        if (text) {
          log?.(`WebGL linkProgram log: ${text}`);
        }
      }
    };
  }

  const compileShader = typeof gl.compileShader === 'function' ? gl.compileShader.bind(gl) : null;
  if (compileShader) {
    gl.compileShader = function wrappedCompile(shader) {
      // コンパイル直後の状態をチェックして失敗時にログを確実に出す
      compileShader(shader);
      const compiled = typeof gl.getShaderParameter === 'function'
        ? gl.getShaderParameter(shader, gl.COMPILE_STATUS)
        : true;
      if (compiled === false) {
        gl.getShaderInfoLog?.(shader);
      }
    };
  }

  const validateProgram = typeof gl.validateProgram === 'function' ? gl.validateProgram.bind(gl) : null;
  if (validateProgram) {
    gl.validateProgram = function wrappedValidate(program) {
      validateProgram(program);
      const info = typeof gl.getProgramInfoLog === 'function'
        ? gl.getProgramInfoLog(program)
        : '';
      const text = typeof info === 'string' ? info.trim() : '';
      if (text) {
        log?.(`WebGL validateProgram log: ${text}`);
      }
    };
  }

  gl.__shaderHooksInstalled = true;
}

/**
 * Three.jsのdiagnostics情報を走査し、ログ行と実行可否ステータスを抽出する。
 * renderer.info.programsは内部構造が変わる可能性があるため、nullチェックを徹底する。
 */
function collectProgramDiagnostics(renderer) {
  // Three.jsのRendererが保持するdiagnosticsを配列化し整形
  const programs = renderer?.info?.programs;
  if (!Array.isArray(programs)) {
    return [];
  }
  return programs.map((program, index) => {
    const diagnostics = program?.diagnostics;
    const entries = [];
    if (diagnostics) {
      [
        ['program', diagnostics.programLog],
        ['vertex', diagnostics.vertexShader?.log],
        ['fragment', diagnostics.fragmentShader?.log]
      ].forEach(([label, message]) => {
        const text = typeof message === 'string' ? message.trim() : '';
        if (text) {
          entries.push({ label, message: text });
        }
      });
    }
    return {
      index,
      entries,
      runnable: diagnostics?.runnable !== false
    };
  });
}

/**
 * collectProgramDiagnosticsで収集したエントリを整形し、logへ順次出力する。
 * Three.jsのinfo.programsは過去の失敗ログも持ち続けるため、都度走査して再出力する。
 */
function emitShaderDiagnostics(renderer, log) {
  // Three.jsが蓄積した診断ログを参照しながらlogへ逐次出力
  collectProgramDiagnostics(renderer).forEach(({ index, entries }) => {
    entries.forEach(({ label, message }) => {
      log?.(`Shader ${label} log [${index}]: ${message}`);
    });
  });
}

/**
 * diagnostics内でrunnable=falseが検出された場合は、詳細ログをまとめて例外化する。
 * Fiber再描画のたびに失敗を握りつぶさないよう、起動直後に検証する。
 */
function assertShaderProgramsRunnable(renderer, log) {
  // Three.jsのdiagnosticsに基づき実行不能なプログラムが存在すれば即時に例外化
  const diagnostics = collectProgramDiagnostics(renderer);
  const failed = diagnostics.filter((item) => item.runnable === false);
  if (!failed.length) {
    return;
  }
  const summary = failed
    .flatMap(({ index, entries }) => {
      if (!entries.length) {
        return [`Program ${index}: compilation failed without log output.`];
      }
      return entries.map(({ label, message }) => `Program ${index} ${label} log: ${message}`);
    })
    .join(' | ');
  const errorMessage = summary || 'Shader compilation failed.';
  log?.(errorMessage);
  throw new Error(errorMessage);
}
