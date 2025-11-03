// path.js
// path tracing scene
export {createSceneController} from './shader_mod.js?' ;
//settings
globalThis.shader_settings = {
  SETTINGS:`
    const int MAX_BOUNCES = 4;
    const int SPP = 4; // samples per pixel
    const float STEREO = 0.4 ;       // stereo ipd 
    const bool STEREO_TARGET = true ; //stereo target   
    const int RANDOM_SEED = 1 ; //random noize seed par frame
 
    const int HIDDEN_LIGHT = 0 ;    //invisible mirror 
  `,
  SHADER_CHUNK_FILES : [
  'path2-define.glsl',
  'path2-material.glsl',
  'path4-model.glsl',
  'path4-scene.glsl',
  'path2-main.glsl'
  ]
}