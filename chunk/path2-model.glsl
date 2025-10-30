#line 2 2

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

void tryBoxTransformed(
  Ray ray,
  vec3 size,
  mat4 transform,
  Material material,
  inout HitInfo hit
) {
  mat4 invTransform = inverse(transform);
  Ray localRay = Ray(
    (invTransform * vec4(ray.origin, 1.0)).xyz,
    (invTransform * vec4(ray.direction, 0.0)).xyz,
    0
  );

  // 軸平行境界ボックス（AABB）との交差判定（ローカル座標系）
  vec3 halfSize = size * 0.5;
  vec3 minBounds = -halfSize;
  vec3 maxBounds = halfSize;
  vec3 invDir = 1.0 / localRay.direction;
  vec3 t0 = (minBounds - localRay.origin) * invDir;
  vec3 t1 = (maxBounds - localRay.origin) * invDir;
  vec3 tMin = min(t0, t1);
  vec3 tMax = max(t0, t1);
  float tNear = max(max(tMin.x, tMin.y), tMin.z);
  float tFar = min(min(tMax.x, tMax.y), tMax.z);
  if (tFar < 0.001 || tNear > tFar) {
    return;
  }

  float tLocal = max(tNear, 0.001);
  vec3 localPos = localRay.origin + localRay.direction * tLocal;
  vec3 localNormal = vec3(0.0);
  const float EPS = 0.001;
  if (abs(localPos.x + halfSize.x) < EPS) localNormal = vec3(-1.0, 0.0, 0.0);
  else if (abs(localPos.x - halfSize.x) < EPS) localNormal = vec3(1.0, 0.0, 0.0);
  else if (abs(localPos.y + halfSize.y) < EPS) localNormal = vec3(0.0, -1.0, 0.0);
  else if (abs(localPos.y - halfSize.y) < EPS) localNormal = vec3(0.0, 1.0, 0.0);
  else if (abs(localPos.z + halfSize.z) < EPS) localNormal = vec3(0.0, 0.0, -1.0);
  else localNormal = vec3(0.0, 0.0, 1.0);

  vec3 worldPos = (transform * vec4(localPos, 1.0)).xyz;
  float tWorld = dot(worldPos - ray.origin, ray.direction);
  if (tWorld < 0.001 || tWorld >= hit.t) {
    return;
  }

  vec3 worldNormal = normalize(mat3(transpose(invTransform)) * localNormal);
  if (dot(worldNormal, ray.direction) > 0.0) {
    worldNormal = -worldNormal;
  }

  hit.t = tWorld;
  hit.position = worldPos;
  hit.normal = worldNormal;
  hit.material = material;
}

void tryGround(Ray ray, Material material, inout HitInfo hit) {
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
  hit.material = material ;
  hit.material.albedo = albedo;
}
