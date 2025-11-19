// path tracer definition

struct SceneUniforms {
  timeStereoAspect : vec4<f32>,
  resolution : vec4<f32>,
  cameraPos : vec4<f32>,
  cameraTarget : vec4<f32>,
  cameraUp : vec4<f32>,
  cameraParams : vec4<f32>,
};

@group(0) @binding(0) var<uniform> uniforms : SceneUniforms;

const PI : f32 = 3.141592653589793;

const HIDDEN_LIGHT : i32 = 0;
const MATERIAL_NONE : i32 = -1;
const MATERIAL_LAMBERT : i32 = 0;
const MATERIAL_MIRROR : i32 = 1;
const MATERIAL_LIGHT : i32 = 2;
const MATERIAL_GLOSSY : i32 = 3;
const MATERIAL_TRANSPARENT : i32 = 4;
const MATERIAL_BRDF : i32 = 5;

struct Ray {
  origin : vec3<f32>,
  direction : vec3<f32>,
  kind : i32,
};

struct Basis {
  tangent : vec3<f32>,
  bitangent : vec3<f32>,
};

struct Material {
  noref: bool,
  albedo : vec3<f32>,
  emission : vec3<f32>,
  specular : vec3<f32>,
  roughness : f32,
  metalness : f32,
  ior : f32,
  kind : i32,
};

struct HitInfo {
  id : u32,
  t : f32,
  position : vec3<f32>,
  normal : vec3<f32>,
  material : Material,
  localPosition : vec3<f32>
};

fn defaultMaterial() -> Material {
  return Material(
    true,
    vec3<f32>(0.0),
    vec3<f32>(0.0),
    vec3<f32>(0.0),
    1.0,
    0.0,
    1.5,
    MATERIAL_NONE
  );
}

fn defaultHitInfo() -> HitInfo {
  return HitInfo(
    0,
    1e20,
    vec3<f32>(0.0),
    vec3<f32>(0.0),
    defaultMaterial(),
    vec3<f32>(0.0)
  );
}

fn makeRay(origin : vec3<f32>, direction : vec3<f32>, kind : i32) -> Ray {
  return Ray(origin, direction, kind);
}

fn getTime() -> f32 {
  return uniforms.timeStereoAspect.x;
}

fn getStereoEye() -> f32 {
  return uniforms.timeStereoAspect.y;
}

fn getAspect() -> f32 {
  return uniforms.timeStereoAspect.z;
}

fn getResolution() -> vec2<f32> {
  return uniforms.resolution.xy;
}

fn getInvResolution() -> vec2<f32> {
  return uniforms.resolution.zw;
}

fn getCameraPosUniform() -> vec3<f32> {
  return uniforms.cameraPos.xyz;
}

fn getCameraTargetUniform() -> vec3<f32> {
  return uniforms.cameraTarget.xyz;
}

fn getCameraUpUniform() -> vec3<f32> {
  return uniforms.cameraUp.xyz;
}

fn getCameraFovY() -> f32 {
  return uniforms.cameraParams.x;
}

fn hashUint(x : u32) -> u32 {
  var v = x;
  v = v ^ (v >> 16u);
  v = v * 0x7feb352du;
  v = v ^ (v >> 15u);
  v = v * 0x846ca68bu;
  v = v ^ (v >> 16u);
  return v;
}

fn rand(state : ptr<function, u32>) -> f32 {
  let current = (*state);
  let next = hashUint(current);
  (*state) = next;
  return f32(next) / 4294967296.0;
}

fn rand2(state : ptr<function, u32>) -> vec2<f32> {
  let x = rand(state);
  let y = rand(state);
  return vec2<f32>(x, y);
}

fn buildOrthonormalBasis(n : vec3<f32>) -> Basis {
  var tangent : vec3<f32>;
  if (abs(n.z) > 0.999) {
    tangent = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), n));
  } else {
    tangent = normalize(cross(vec3<f32>(0.0, 0.0, 1.0), n));
  }
  let bitangent = cross(n, tangent);
  return Basis(tangent, bitangent);
}

fn modFloat(a : f32, b : f32) -> f32 {
  return a - b * floor(a / b);
}
