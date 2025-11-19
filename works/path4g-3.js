// path.js
// path tracing scene
export {createSceneController} from './shader_modgpu.js?' ;
//settings
globalThis.shader_settings = {
  SETTINGS:`
    const MAX_BOUNCES : i32 = 6;
    const SPP : i32 = 10;
    const STEREO : f32 = 0.5;        // stereo ipd
    const STEREO_TARGET : bool = false; // stereo target
    const RANDOM_SEED : i32 = 1 ; //random noize seed par frame
  `,
  VIEWPORT_GRID : { columns: 4, rows: 2 },
  SHADER_CHUNK_FILES : [
  'path2-define.wgsl',
  'shader-snoize.wgsl',
  'path2-material.wgsl',
  'path4-model.wgsl',
  'path4-s3.wgsl',
  'path2-main.wgsl'
  ]
}
