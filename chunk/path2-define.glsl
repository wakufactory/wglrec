#line 2 1
// path tracing main module

in vec2 vUv;
uniform float uTime;
uniform vec2 uResolution;
uniform vec3 uCameraPos;
uniform vec3 uCameraTarget;
uniform vec3 uCameraUp;
uniform float uCameraFovY;
uniform float uStereoEye;

// シーン全体で共有する定数群
const float PI = 3.141592653589793;

//material
struct Material {
  vec3 albedo;
  vec3 emission;
  vec3 specular;
  float roughness;
  int type;
};

// hit状態の保持
struct HitInfo {
  float t;
  vec3 position;
  vec3 normal;
  Material material;
};

// レイと交差情報を保持する構造体
struct Ray {
  vec3 origin;
  vec3 direction;
  int kind ;
};

uint hashUint(uint x) {
  x ^= x >> 16;
  x *= 0x7feb352du;
  x ^= x >> 15;
  x *= 0x846ca68bu;
  x ^= x >> 16;
  return x;
}

float rand(inout uint state) {
  state = hashUint(state);
  return float(state) / 4294967296.0;
}

vec2 rand2(inout uint state) {
  return vec2(rand(state), rand(state));
}

void orthonormalBasis(vec3 n, out vec3 tangent, out vec3 bitangent) {
  if (abs(n.z) > 0.999) {
    tangent = normalize(cross(vec3(0.0, 1.0, 0.0), n));
  } else {
    tangent = normalize(cross(vec3(0.0, 0.0, 1.0), n));
  }
  bitangent = cross(n, tangent);
}