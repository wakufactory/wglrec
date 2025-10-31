// path.js
// path tracing scene

//settings
globalThis.shader_settings = {
  SHADER_CHUNK_FILES : [
  'path2-setting.glsl',
  'path2-define.glsl',
  'path2-material.glsl',
  'path2-model.glsl',
  'path2-scene1.glsl',
  'path2-main.glsl'
  ]
}
export {createSceneController} from './shader_mod.js' ;
