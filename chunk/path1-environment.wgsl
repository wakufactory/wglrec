const MAX_BOUNCES : i32 = 6;
const SPP : i32 = 20;
const HIDDEN_LIGHT : i32 = 0;

const MATERIAL_NONE : i32 = -1;
const MATERIAL_LAMBERT : i32 = 0;
const MATERIAL_MIRROR : i32 = 1;
const MATERIAL_LIGHT : i32 = 2;
const MATERIAL_GLOSSY : i32 = 3;

const PI : f32 = 3.141592653589793;

struct SceneUniforms {
  timeStereoAspect : vec4<f32>,
  resolution : vec4<f32>,
  cameraPos : vec4<f32>,
  cameraTarget : vec4<f32>,
  cameraUp : vec4<f32>,
  cameraParams : vec4<f32>,
};

@group(0) @binding(0) var<uniform> uniforms : SceneUniforms;

struct Material {
  albedo : vec3<f32>,
  emission : vec3<f32>,
  specular : vec3<f32>,
  roughness : f32,
  kind : i32,
};

struct HitInfo {
  t : f32,
  position : vec3<f32>,
  normal : vec3<f32>,
  material : Material,
};

struct Ray {
  origin : vec3<f32>,
  direction : vec3<f32>,
  kind : i32,
};

struct Basis {
  tangent : vec3<f32>,
  bitangent : vec3<f32>,
};

fn makeRay(origin : vec3<f32>, direction : vec3<f32>, kind : i32) -> Ray {
  return Ray(
    origin,
    direction,
    kind
  );
}

fn defaultMaterial() -> Material {
  return Material(vec3<f32>(0.0), vec3<f32>(0.0), vec3<f32>(0.0), 1.0, MATERIAL_NONE);
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

fn modFloat(a : f32, b : f32) -> f32 {
  return a - b * floor(a / b);
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

fn cosineSampleHemisphere(xi : vec2<f32>, normal : vec3<f32>) -> vec3<f32> {
  let phi = 2.0 * PI * xi.x;
  let cosTheta = sqrt(1.0 - xi.y);
  let sinTheta = sqrt(xi.y);
  let basis = buildOrthonormalBasis(normal);
  let localDir = vec3<f32>(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
  let worldDir = normalize(
    localDir.x * basis.tangent +
    localDir.y * basis.bitangent +
    localDir.z * normal
  );
  return worldDir;
}

fn samplePhongLobe(reflectDir : vec3<f32>, exponent : f32, xi : vec2<f32>) -> vec3<f32> {
  let cosTheta = pow(xi.x, 1.0 / (exponent + 1.0));
  let sinTheta = sqrt(max(0.0, 1.0 - cosTheta * cosTheta));
  let phi = 2.0 * PI * xi.y;
  let basis = buildOrthonormalBasis(reflectDir);
  let localDir = vec3<f32>(
    sinTheta * cos(phi),
    sinTheta * sin(phi),
    cosTheta
  );
  let worldDir = normalize(
    localDir.x * basis.tangent +
    localDir.y * basis.bitangent +
    localDir.z * reflectDir
  );
  return worldDir;
}

fn trySphere(ray : Ray, center : vec3<f32>, radius : f32, material : Material, hit : ptr<function, HitInfo>) {
  let oc = ray.origin - center;
  let b = dot(oc, ray.direction);
  let c = dot(oc, oc) - radius * radius;
  let disc = b * b - c;
  if (disc < 0.0) {
    return;
  }
  let s = sqrt(disc);
  var t = -b - s;
  if (t < 0.001) {
    t = -b + s;
    if (t < 0.001) {
      return;
    }
  }
  if (t >= (*hit).t) {
    return;
  }
  let pos = ray.origin + ray.direction * t;
  let normal = normalize(pos - center);
  (*hit).t = t;
  (*hit).position = pos;
  (*hit).normal = normal;
  (*hit).material = material;
}

fn tryBoxTransformed(ray : Ray, size : vec3<f32>, transform : mat4x4<f32>, material : Material, hit : ptr<function, HitInfo>) {
  let rotation = mat3x3<f32>(
    transform[0].xyz,
    transform[1].xyz,
    transform[2].xyz
  );
  let rotationInv = transpose(rotation);
  let translation = transform[3].xyz;

  let localOrigin = rotationInv * (ray.origin - translation);
  let localDirection = rotationInv * ray.direction;
  var localRay = makeRay(localOrigin, localDirection, 0);

  let halfSize = size * 0.5;
  let minBounds = -halfSize;
  let maxBounds = halfSize;
  let invDir = 1.0 / localRay.direction;
  let t0 = (minBounds - localRay.origin) * invDir;
  let t1 = (maxBounds - localRay.origin) * invDir;
  let tMin = min(t0, t1);
  let tMax = max(t0, t1);
  let tNear = max(max(tMin.x, tMin.y), tMin.z);
  let tFar = min(min(tMax.x, tMax.y), tMax.z);
  if (tFar < 0.001 || tNear > tFar) {
    return;
  }

  let tLocal = max(tNear, 0.001);
  let localPos = localRay.origin + localRay.direction * tLocal;
  var localNormal = vec3<f32>(0.0);
  let EPS = 0.001;
  if (abs(localPos.x + halfSize.x) < EPS) {
    localNormal = vec3<f32>(-1.0, 0.0, 0.0);
  } else if (abs(localPos.x - halfSize.x) < EPS) {
    localNormal = vec3<f32>(1.0, 0.0, 0.0);
  } else if (abs(localPos.y + halfSize.y) < EPS) {
    localNormal = vec3<f32>(0.0, -1.0, 0.0);
  } else if (abs(localPos.y - halfSize.y) < EPS) {
    localNormal = vec3<f32>(0.0, 1.0, 0.0);
  } else if (abs(localPos.z + halfSize.z) < EPS) {
    localNormal = vec3<f32>(0.0, 0.0, -1.0);
  } else {
    localNormal = vec3<f32>(0.0, 0.0, 1.0);
  }

  let tWorld = tLocal;
  if (tWorld < 0.001 || tWorld >= (*hit).t) {
    return;
  }

  let worldPos = ray.origin + ray.direction * tWorld;
  var worldNormal = normalize(rotation * localNormal);
  if (dot(worldNormal, ray.direction) > 0.0) {
    worldNormal = -worldNormal;
  }

  (*hit).t = tWorld;
  (*hit).position = worldPos;
  (*hit).normal = worldNormal;
  (*hit).material = material;
}

fn tryGround(ray : Ray, material : Material, hit : ptr<function, HitInfo>) {
  let normal = vec3<f32>(0.0, 1.0, 0.0);
  let denom = dot(ray.direction, normal);
  if (abs(denom) < 0.001) {
    return;
  }
  let t = (-1.0 - ray.origin.y) / denom;
  if (t < 0.001 || t >= (*hit).t) {
    return;
  }
  let pos = ray.origin + ray.direction * t;
  let checkerCoords = pos.xz * 0.5;
  let checker = modFloat(floor(checkerCoords.x) + floor(checkerCoords.y), 2.0);
  let colorA = vec3<f32>(0.85, 0.85, 0.85);
  let colorB = vec3<f32>(0.23, 0.25, 0.28);
  let albedo = mix(colorA, colorB, checker);
  (*hit).t = t;
  (*hit).position = pos;
  (*hit).normal = normal;
  var updatedMaterial = material;
  updatedMaterial.albedo = albedo;
  (*hit).material = updatedMaterial;
}
