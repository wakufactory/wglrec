// path.js
// path tracing scene
export {createSceneController} from './shader_modgpu.js?' ;
//settings
globalThis.shader_settings = {
  SETTINGS:`
    const MAX_BOUNCES : i32 = 6;
    const SPP : i32 = 10;
    const STEREO : f32 = 0.4;        // stereo ipd
    const STEREO_TARGET : bool = true; // stereo target
    const RANDOM_SEED : i32 = 1 ; //random noize seed par frame
  `,
  VIEWPORT_GRID : { columns: 4, rows: 2 },
  SHADER_CHUNK_FILES : [
  'path5-define.wgsl',
  'shader-snoise.wgsl',
  'path5-material.wgsl',
  'path5-model.wgsl',
  'path5-s9.wgsl',
  'path5-main.wgsl'
  ]
}
