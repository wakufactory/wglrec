#line 2 2
// rotation (XYZ, radians), scale, translation -> combined transform matrix
mat4 composeTransform(vec3 rotation, vec3 scale, vec3 translation) {

  mat4 mat  = mat4(
    vec4(1.0, 0.0, 0.0, 0.0),
    vec4(0.0, 1.0, 0.0, 0.0),
    vec4(0.0, 0.0, 1.0, 0.0),
    vec4(translation, 1.0)
  );
  if(rotation.z != 0.0) {
    float cz = cos(rotation.z);
    float sz = sin(rotation.z);
    mat4 rotZ = mat4(
    vec4(cz, sz, 0.0, 0.0),
    vec4(-sz, cz, 0.0, 0.0),
    vec4(0.0, 0.0, 1.0, 0.0),
    vec4(0.0, 0.0, 0.0, 1.0)
    );
    mat *= rotZ ;
  }
  if(rotation.y !=0.0) {
    float cy = cos(rotation.y);
    float sy = sin(rotation.y);
    mat4 rotY = mat4(
    vec4(cy, 0.0, -sy, 0.0),
    vec4(0.0, 1.0, 0.0, 0.0),
    vec4(sy, 0.0, cy, 0.0),
    vec4(0.0, 0.0, 0.0, 1.0)
    );
    mat *= rotY ;
  }

  if(rotation.x!=0.0) {
    float cx = cos(rotation.x);
    float sx = sin(rotation.x);
    mat4 rotX = mat4(
    vec4(1.0, 0.0, 0.0, 0.0),
    vec4(0.0, cx, sx, 0.0),
    vec4(0.0, -sx, cx, 0.0),
    vec4(0.0, 0.0, 0.0, 1.0)
    );
    mat *= rotX ;
  }
  if(!all(equal(scale,vec3(1.,1.,1.)))) {
    mat4 scaleMat = mat4(
    vec4(scale.x, 0.0, 0.0, 0.0),
    vec4(0.0, scale.y, 0.0, 0.0),
    vec4(0.0, 0.0, scale.z, 0.0),
    vec4(0.0, 0.0, 0.0, 1.0)
    );
    mat *= scaleMat;
  };
  return mat ;
}
#define m4unit mat4(1.,0.,0.,0.,0.,1.,0.,0.,0.,0.,1.,0.,0.,0.,0.,1.)


// 各オブジェクトとの交差判定
// in ray
// out hit

// 球体との交差判定
bool trySphere(
  Ray ray,
  inout HitInfo hit,
  vec3 center,
  float radius
) {
  vec3 oc = ray.origin - center;
  float b = dot(oc, ray.direction);
  float c = dot(oc, oc) - radius * radius;
  float disc = b * b - c;
  if (disc < 0.0) return false ;
  float s = sqrt(disc);
  float t = -b - s;
  if (t < 0.001) {
    t = -b + s;
    if (t < 0.001) return false ;
  }
  if (t >= hit.t) return false;
  vec3 pos = ray.origin + ray.direction * t;
  vec3 normal = normalize(pos - center);
  hit.t = t;
  hit.position = pos;
  hit.normal = normal;
  return true ;
}

bool tryBoundingSphere(
  Ray ray,
  inout HitInfo hit,
  vec3 center,
  float radius
) {
  vec3 oc = ray.origin - center;
  //boundingで球の中にある場合はtrue
  if (dot(oc, oc) <= radius * radius) {
    return true;
  }
  float b = dot(oc, ray.direction);
  float c = dot(oc, oc) - radius * radius;
  float disc = b * b - c;
  if (disc < 0.0) return false ;
  float s = sqrt(disc);
  float t = -b - s;
  if (t < 0.001) {
    t = -b + s;
    if (t < 0.001) return false ;
  }
  if (t >= hit.t) return false ;
  return true ;
}

// 球体との交差判定（transform対応）
bool trySphereTransformed(
  Ray ray,
  inout HitInfo hit,
  vec3 center,
  float radius,
  mat4 transform 
) {
  mat4 invTransform = inverse(transform);
  Ray localRay = Ray(
    (invTransform * vec4(ray.origin, 1.0)).xyz,
    (invTransform * vec4(ray.direction, 0.0)).xyz,
    0
  );

  vec3 oc = localRay.origin - center;
  float b = dot(oc, localRay.direction);
  float c = dot(oc, oc) - radius * radius;
  float disc = b * b - c;
  if (disc < 0.0) return false ;
  float s = sqrt(disc);
  float t = -b - s;
  if (t < 0.001) {
    t = -b + s;
    if (t < 0.001) return false ;
  }

  vec3 localPos = localRay.origin + localRay.direction * t;
  vec3 localNormal = normalize(localPos - center);

  vec3 worldPos = (transform * vec4(localPos, 1.0)).xyz;
  float tWorld = dot(worldPos - ray.origin, ray.direction);
  if (tWorld < 0.001 || tWorld >= hit.t) {
    return  false ;
  }

  vec3 worldNormal = normalize(mat3(transpose(invTransform)) * localNormal);
  if (dot(worldNormal, ray.direction) > 0.0) {
    worldNormal = -worldNormal;
  }
  hit.t = tWorld;
  hit.position = worldPos;
  hit.normal = worldNormal;
  return true ;
}

bool tryBoxTransformed(
  Ray ray,
  inout HitInfo hit,
  vec3 size,
  mat4 transform
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
    return false ;
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
    return false ;
  }

  vec3 worldNormal = normalize(mat3(transpose(invTransform)) * localNormal);
  if (dot(worldNormal, ray.direction) > 0.0) {
    worldNormal = -worldNormal;
  }

  hit.t = tWorld;
  hit.position = worldPos;
  hit.normal = worldNormal;
  return true ;
}

bool tryGround(Ray ray,inout HitInfo hit) {
  vec3 normal = vec3(0.0, 1.0, 0.0);
  float denom = dot(ray.direction, normal);
  if (abs(denom) < 0.001) return false ;
  float t = (-1.0 - ray.origin.y) / denom;
  if (t < 0.001 || t >= hit.t) return false ;
  vec3 pos = ray.origin + ray.direction * t;
  hit.t = t;
  hit.position = pos;
  hit.normal = normal;
  return true ;
}
