#line 2 2
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
const int MATERIAL_NONE = -1;
const int MATERIAL_LAMBERT = 0;
const int MATERIAL_MIRROR = 1;
const int MATERIAL_LIGHT = 2;
const int MATERIAL_GLOSSY = 3;

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

// 各オブジェクトとの交差判定
void trySphere(
  Ray ray,
  vec3 center,
  float radius,
  Material material,
  inout HitInfo hit
) {
  // 球体との交差判定
  vec3 oc = ray.origin - center;
  float b = dot(oc, ray.direction);
  float c = dot(oc, oc) - radius * radius;
  float disc = b * b - c;
  if (disc < 0.0) return;
  float s = sqrt(disc);
  float t = -b - s;
  if (t < 0.001) {
    t = -b + s;
    if (t < 0.001) return;
  }
  if (t >= hit.t) return;
  vec3 pos = ray.origin + ray.direction * t;
  vec3 normal = normalize(pos - center);
  hit.t = t;
  hit.position = pos;
  hit.normal = normal;
  hit.material = material;
}

void tryBox(
  Ray ray,
  vec3 minBounds,
  vec3 maxBounds,
  Material material,
  inout HitInfo hit
) {
  // 軸平行境界ボックス（AABB）との交差判定
  vec3 invDir = 1.0 / ray.direction;
  vec3 t0 = (minBounds - ray.origin) * invDir;
  vec3 t1 = (maxBounds - ray.origin) * invDir;
  vec3 tMin = min(t0, t1);
  vec3 tMax = max(t0, t1);
  float tNear = max(max(tMin.x, tMin.y), tMin.z);
  float tFar = min(min(tMax.x, tMax.y), tMax.z);
  if (tFar < 0.001 || tNear > tFar || tNear >= hit.t) {
    return;
  }
  float tHit = max(tNear, 0.001);
  vec3 pos = ray.origin + ray.direction * tHit;
  vec3 normal = vec3(0.0);
  const float EPS = 0.001;
  if (abs(pos.x - minBounds.x) < EPS) normal = vec3(-1.0, 0.0, 0.0);
  else if (abs(pos.x - maxBounds.x) < EPS) normal = vec3(1.0, 0.0, 0.0);
  else if (abs(pos.y - minBounds.y) < EPS) normal = vec3(0.0, -1.0, 0.0);
  else if (abs(pos.y - maxBounds.y) < EPS) normal = vec3(0.0, 1.0, 0.0);
  else if (abs(pos.z - minBounds.z) < EPS) normal = vec3(0.0, 0.0, -1.0);
  else normal = vec3(0.0, 0.0, 1.0);
  hit.t = tHit;
  hit.position = pos;
  hit.normal = normal;
  hit.material = material;
}

void tryBoxTransformed(
  Ray ray,
  vec3 minBounds,
  vec3 maxBounds,
  mat4 transform,
  Material material,
  inout HitInfo hit
) {
  mat4 invTransform = inverse(transform);
  Ray localRay = Ray(
    (invTransform * vec4(ray.origin, 1.0)).xyz,
    (invTransform * vec4(ray.direction, 0.0)).xyz
  );

  HitInfo localHit;
  localHit.t = hit.t;
  localHit.position = vec3(0.0);
  localHit.normal = vec3(0.0);
  localHit.material = material;
  localHit.material.type = MATERIAL_NONE;

  tryBox(localRay, minBounds, maxBounds, material, localHit);
  if (localHit.material.type == MATERIAL_NONE) {
    return;
  }

  vec3 worldPos = (transform * vec4(localHit.position, 1.0)).xyz;
  float tWorld = dot(worldPos - ray.origin, ray.direction);
  if (tWorld < 0.001 || tWorld >= hit.t) {
    return;
  }

  vec3 worldNormal = normalize(mat3(transpose(invTransform)) * localHit.normal);
  if (dot(worldNormal, ray.direction) > 0.0) {
    worldNormal = -worldNormal;
  }

  hit.t = tWorld;
  hit.position = worldPos;
  hit.normal = worldNormal;
  hit.material = localHit.material;
}

void tryGround(Ray ray, inout HitInfo hit) {
  vec3 normal = vec3(0.0, 1.0, 0.0);
  float denom = dot(ray.direction, normal);
  if (abs(denom) < 0.001) return;
  float t = (-1.0 - ray.origin.y) / denom;
  if (t < 0.001 || t >= hit.t) return;
  vec3 pos = ray.origin + ray.direction * t;
  vec2 checkerCoords = pos.xz * 0.5;
  float checker = mod(floor(checkerCoords.x) + floor(checkerCoords.y), 2.0);
  vec3 colorA = vec3(0.85, 0.85, 0.85);
  vec3 colorB = vec3(0.23, 0.25, 0.28);
  vec3 albedo = mix(colorA, colorB, checker);
  hit.t = t;
  hit.position = pos;
  hit.normal = normal;
  hit.material.albedo = albedo;
  hit.material.emission = vec3(0.0);
  hit.material.specular = vec3(0.0);
  hit.material.roughness = 1.0;
  hit.material.type = MATERIAL_LAMBERT;
}


//反射方向を決める関数
vec3 cosineSampleHemisphere(vec2 xi, vec3 normal) {
  // コサイン加重サンプリングで半球方向に新しいレイを生成
  float phi = 2.0 * PI * xi.x;
  float cosTheta = sqrt(1.0 - xi.y);
  float sinTheta = sqrt(xi.y);
  vec3 tangent, bitangent;
  orthonormalBasis(normal, tangent, bitangent);
  vec3 localDir = vec3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
  return normalize(
    localDir.x * tangent +
    localDir.y * bitangent +
    localDir.z * normal
  );
}

vec3 samplePhongLobe(vec3 reflectDir, float exponent, vec2 xi) {
  // Phongローブに従って鏡面方向まわりをサンプリング
  float cosTheta = pow(xi.x, 1.0 / (exponent + 1.0));
  float sinTheta = sqrt(max(0.0, 1.0 - cosTheta * cosTheta));
  float phi = 2.0 * PI * xi.y;
  vec3 tangent, bitangent;
  orthonormalBasis(reflectDir, tangent, bitangent);
  vec3 localDir = vec3(
    sinTheta * cos(phi),
    sinTheta * sin(phi),
    cosTheta
  );
  return normalize(
    localDir.x * tangent +
    localDir.y * bitangent +
    localDir.z * reflectDir
  );
}

//シーン定義関数prototype
void setCamera(inout vec3 camPos,inout vec3 target,inout vec3 up,inout float fov) ;
vec3 environment(Ray ray) ;   // 環境光 
void intersectScene(Ray ray, inout HitInfo hit);  // シーンの交差判定 

// rayをトレース
vec3 traceRay(Ray ray, inout uint seed) {
  // パストレーシングで放射輝度を積算
  vec3 throughput = vec3(1.0);
  vec3 radiance = vec3(0.0);
  //反射上限回数分のループ
  for (int bounce = 0; bounce < MAX_BOUNCES; ++bounce) {
    HitInfo hit;
    hit.t = 1e20;
    hit.material.albedo = vec3(0.0);
    hit.material.emission = vec3(0.0);
    hit.material.specular = vec3(0.0);
    hit.material.roughness = 1.0;
    hit.material.type = MATERIAL_NONE;
    intersectScene(ray, hit);

    if (hit.material.type == MATERIAL_NONE) {  //物体にヒットしなかった場合
      radiance += throughput * environment(ray);  //環境光を加える
      break;
    }

    radiance += throughput * hit.material.emission;  //自己発光
    if (hit.material.type == MATERIAL_LIGHT) { //光源ならそこで打ち切り
      break;
    }

    vec3 origin = hit.position + hit.normal * 0.001;
    vec3 newDir;

    //鏡面反射
    if (hit.material.type == MATERIAL_MIRROR) {
      newDir = reflect(ray.direction, hit.normal);  //反射方向は一意に定まる
      throughput *= hit.material.albedo;
    }

    //GLOSSY
    if (hit.material.type == MATERIAL_GLOSSY) {
      float specIntensity = max(hit.material.specular.r, max(hit.material.specular.g, hit.material.specular.b));
      float diffIntensity = max(hit.material.albedo.r, max(hit.material.albedo.g, hit.material.albedo.b));
      float totalIntensity = specIntensity + diffIntensity;
      float specProb = (totalIntensity > 0.0) ? (specIntensity / totalIntensity) : 0.0;
      specProb = min(specProb, 0.95);

      float choice = rand(seed);
      if (choice < specProb && specIntensity > 0.0) {
        vec2 xiSpec = rand2(seed);
        float gloss = clamp(1.0 - hit.material.roughness, 0.0, 0.999);
        float exponent = mix(5.0, 200.0, gloss * gloss);
        vec3 reflectDir = reflect(ray.direction, hit.normal);
        newDir = samplePhongLobe(reflectDir, exponent, xiSpec);
        if (dot(newDir, hit.normal) <= 0.0) {
          newDir = reflectDir;
        }
        throughput *= hit.material.specular / max(specProb, 0.001);
      } else {
        vec2 xiDiff = rand2(seed);
        newDir = cosineSampleHemisphere(xiDiff, hit.normal);
        float diffuseProb = max(1.0 - specProb, 0.001);
        throughput *= hit.material.albedo / diffuseProb;
      }

      float p = max(
        max(hit.material.albedo.r, max(hit.material.albedo.g, hit.material.albedo.b)),
        max(hit.material.specular.r, max(hit.material.specular.g, hit.material.specular.b))
      );
      p = clamp(p, 0.1, 0.95);
      if (bounce > 2) {
        float rr = rand(seed);
        if (rr > p) {
          break;
        }
        throughput *= 1.0 / p;
      }
    } 
    //LAMBERT
    if (hit.material.type == MATERIAL_LAMBERT) {
      vec2 xi = rand2(seed);
      newDir = cosineSampleHemisphere(xi, hit.normal);
      throughput *= hit.material.albedo;
      //russian roulette
      float p = max(hit.material.albedo.r, max(hit.material.albedo.g, hit.material.albedo.b));
      if (bounce > 2) {
        float rr = rand(seed);
        if (rr > p) {
          break;
        }
        throughput *= 1.0 / p;
      }
    }

    ray = Ray(origin, newDir);
  }

  return radiance;
}

void main() {
  vec2 pixel = gl_FragCoord.xy;
  vec2 res = uResolution;
  float aspect = res.x / res.y;
  vec3 camPos = uCameraPos;
  vec3 target = uCameraTarget;
  vec3 up = normalize(uCameraUp);
  float fov = uCameraFovY ;

  //カメラのアニメーション設定
  setCamera(camPos,target,up,fov) ;

  // for stereo render
  if (uStereoEye != 0.0) {
    res.x /= 2.0;
    if (uStereoEye > 0.0) pixel -= vec2(res.x, 0.0);
    aspect /= 2.0;
    camPos = camPos + uStereoEye * normalize(cross(target - camPos, up));
  }
  vec2 ndc = (pixel / res) * 2.0 - 1.0;
  vec3 forward = normalize(target - camPos);
  vec3 right = normalize(cross(forward, up));
  vec3 camUp = cross(right, forward);
  float tanHalfFov = tan(radians(fov) * 0.5);

  uint baseSeed = uint(pixel.y) * 1973u + uint(pixel.x) * 9277u + 374761393u;
  baseSeed ^= uint(SPP) * 668265263u;
  // ピクセルごとに複数サンプルを集めて平均化
  vec3 accum = vec3(0.0);
  for (int s = 0; s < SPP; ++s) {
    uint seed = baseSeed + uint(s) * 1597334677u;
    vec2 jitter = rand2(seed) - 0.5;
    vec2 jittered = ndc + jitter / res;
    vec3 dir = normalize(
      forward +
      right * jittered.x * aspect * tanHalfFov +
      camUp * jittered.y * tanHalfFov
    );
    Ray ray = Ray(camPos, dir);
    accum += traceRay(ray, seed);
  }

  vec3 color = accum / float(SPP);
  color = color / (color + vec3(1.0));
  color = pow(color, vec3(1.0 / 2.2));
  gl_FragColor = vec4(color, 1.0);
}
