// path.js
// path tracing scene
export {createSceneController} from './shader_mod.js' ;
//settings
globalThis.shader_settings = {
  SHADER_CHUNK_FILES : [
  'path2-setting.glsl',
  'path2-define.glsl',
  'path2-material.glsl',
  'path3-model.glsl',
  'path3-scene.glsl',
  'path2-main.glsl'
  ]
}

