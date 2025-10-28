#line 2 1
precision highp float;
precision highp int;

varying vec2 vUv;
uniform float uTime;
uniform vec2 uResolution;
uniform vec3 uCameraPos;
uniform vec3 uCameraTarget;
uniform vec3 uCameraUp;
uniform float uCameraFovY;
uniform float uStereoEye;

// シーン全体で共有する定数群
const float PI = 3.141592653589793;
const int MATERIAL_NONE = -1;
const int MATERIAL_LAMBERT = 0;
const int MATERIAL_MIRROR = 1;
const int MATERIAL_LIGHT = 2;
const int MATERIAL_GLOSSY = 3;
const int MAX_BOUNCES = 6;
const int SPP = 20; // samples per pixel

// レイと交差情報を保持する構造体
struct Ray {
  vec3 origin;
  vec3 direction;
};

vec3 environment(Ray ray) {
  // 簡易なグラデーション環境光
  float t = 0.5 * (ray.direction.y + 1.0);
  vec3 top = vec3(1.2, 1.2, 2.3);
  vec3 bottom = vec3(0.05, 0.07, 0.10);
  return mix(bottom, top, clamp(t, 0.0, 2.0));
}
