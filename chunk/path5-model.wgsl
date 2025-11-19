// path tracing model

fn composeTransform(rotation : vec3<f32>, scale : vec3<f32>, translation : vec3<f32>) -> mat4x4<f32> {
  var mat = mat4x4<f32>(
    vec4<f32>(1.0, 0.0, 0.0, 0.0),
    vec4<f32>(0.0, 1.0, 0.0, 0.0),
    vec4<f32>(0.0, 0.0, 1.0, 0.0),
    vec4<f32>(translation, 1.0)
  );

  if (rotation.z != 0.0) {
    let cz = cos(rotation.z);
    let sz = sin(rotation.z);
    let rotZ = mat4x4<f32>(
      vec4<f32>(cz, sz, 0.0, 0.0),
      vec4<f32>(-sz, cz, 0.0, 0.0),
      vec4<f32>(0.0, 0.0, 1.0, 0.0),
      vec4<f32>(0.0, 0.0, 0.0, 1.0)
    );
    mat = mat * rotZ;
  }

  if (rotation.y != 0.0) {
    let cy = cos(rotation.y);
    let sy = sin(rotation.y);
    let rotY = mat4x4<f32>(
      vec4<f32>(cy, 0.0, -sy, 0.0),
      vec4<f32>(0.0, 1.0, 0.0, 0.0),
      vec4<f32>(sy, 0.0, cy, 0.0),
      vec4<f32>(0.0, 0.0, 0.0, 1.0)
    );
    mat = mat * rotY;
  }

  if (rotation.x != 0.0) {
    let cx = cos(rotation.x);
    let sx = sin(rotation.x);
    let rotX = mat4x4<f32>(
      vec4<f32>(1.0, 0.0, 0.0, 0.0),
      vec4<f32>(0.0, cx, sx, 0.0),
      vec4<f32>(0.0, -sx, cx, 0.0),
      vec4<f32>(0.0, 0.0, 0.0, 1.0)
    );
    mat = mat * rotX;
  }

  if (!all(scale == vec3<f32>(1.0, 1.0, 1.0))) {
    let scaleMat = mat4x4<f32>(
      vec4<f32>(scale.x, 0.0, 0.0, 0.0),
      vec4<f32>(0.0, scale.y, 0.0, 0.0),
      vec4<f32>(0.0, 0.0, scale.z, 0.0),
      vec4<f32>(0.0, 0.0, 0.0, 1.0)
    );
    mat = mat * scaleMat;
  }

  return mat;
}

fn inverseMat3(m : mat3x3<f32>) -> mat3x3<f32> {
  let c0 = cross(m[1], m[2]);
  let c1 = cross(m[2], m[0]);
  let c2 = cross(m[0], m[1]);
  let det = dot(m[0], c0);
  if (abs(det) < 1e-8) {
    return mat3x3<f32>(
      vec3<f32>(1.0, 0.0, 0.0),
      vec3<f32>(0.0, 1.0, 0.0),
      vec3<f32>(0.0, 0.0, 1.0)
    );
  }
  let invDet = 1.0 / det;
  let row0 = c0 * invDet;
  let row1 = c1 * invDet;
  let row2 = c2 * invDet;
  return mat3x3<f32>(
    vec3<f32>(row0.x, row1.x, row2.x),
    vec3<f32>(row0.y, row1.y, row2.y),
    vec3<f32>(row0.z, row1.z, row2.z)
  );
}

fn trySphere(id : u32, ray : Ray, hit : ptr<function, HitInfo>, center : vec3<f32>, radius : f32) -> bool {
  let oc = ray.origin - center;
  let b = dot(oc, ray.direction);
  let c = dot(oc, oc) - radius * radius;
  let disc = b * b - c;
  if (disc < 0.0) {
    return false;
  }
  let s = sqrt(disc);
  var t = -b - s;
  if (t < 0.001) {
    t = -b + s;
    if (t < 0.001) {
      return false;
    }
  }
  if (t >= (*hit).t) {
    return false;
  }
  let pos = ray.origin + ray.direction * t;
  let normal = normalize(pos - center);
  (*hit).t = t;
  (*hit).position = pos;
  (*hit).normal = normal;
  (*hit).localPosition = pos - center ;
  (*hit).id = id ;
  return true;
}

fn tryBoundingSphere(ray : Ray, hit : ptr<function, HitInfo>, center : vec3<f32>, radius : f32) -> bool {
  let oc = ray.origin - center;
  if (dot(oc, oc) <= radius * radius) {
    return true;
  }

  let b = dot(oc, ray.direction);
  let c = dot(oc, oc) - radius * radius;
  let disc = b * b - c;
  if (disc < 0.0) {
    return false;
  }
  let s = sqrt(disc);
  var t = -b - s;
  if (t < 0.001) {
    t = -b + s;
    if (t < 0.001) {
      return false;
    }
  }
  if (t >= (*hit).t) {
    return false;
  }
  return true;
}

fn trySphereTransformed(
  id :u32,
  ray : Ray,
  hit : ptr<function, HitInfo>,
  center : vec3<f32>,
  radius : f32,
  transform : mat4x4<f32>
) -> bool {
  let linear = mat3x3<f32>(
    transform[0].xyz,
    transform[1].xyz,
    transform[2].xyz
  );
  let invLinear = inverseMat3(linear);
  let translation = transform[3].xyz;

  let localOrigin = invLinear * (ray.origin - translation);
  let localDirection = invLinear * ray.direction;
  var localRay = makeRay(localOrigin, localDirection, 0);

  let oc = localRay.origin - center;
  let b = dot(oc, localRay.direction);
  let c = dot(oc, oc) - radius * radius;
  let disc = b * b - c;
  if (disc < 0.0) {
    return false;
  }
  let s = sqrt(disc);
  var t = -b - s;
  if (t < 0.001) {
    t = -b + s;
    if (t < 0.001) {
      return false;
    }
  }

  let localPos = localRay.origin + localRay.direction * t;
  let localNormal = normalize(localPos - center);
  let worldPos = linear * localPos + translation;
  let tWorld = dot(worldPos - ray.origin, ray.direction);
  if ((tWorld < 0.001) || (tWorld >= (*hit).t)) {
    return false;
  }

  let normalMatrix = transpose(invLinear);
  var worldNormal = normalize(normalMatrix * localNormal);
  if (dot(worldNormal, ray.direction) > 0.0) {
    worldNormal = -worldNormal;
  }

  (*hit).t = tWorld;
  (*hit).position = worldPos;
  (*hit).normal = worldNormal;
  (*hit).localPosition = localPos ;
  (*hit).id = id ;
  return true;
}

fn tryBoxTransformed(
  id : u32,
  ray : Ray,
  hit : ptr<function, HitInfo>,
  size : vec3<f32>,
  transform : mat4x4<f32>
) -> bool {
  let linear = mat3x3<f32>(
    transform[0].xyz,
    transform[1].xyz,
    transform[2].xyz
  );
  let invLinear = inverseMat3(linear);
  let translation = transform[3].xyz;

  let localOrigin = invLinear * (ray.origin - translation);
  let localDirection = invLinear * ray.direction;
  let localRay = makeRay(localOrigin, localDirection, 0);

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
  if ((tFar < 0.001) || (tNear > tFar)) {
    return false;
  }

  let tLocal = max(tNear, 0.001);
  let localPos = localRay.origin + localRay.direction * tLocal;
  var localNormal = vec3<f32>(0.0);
  let eps = 0.001;
  if (abs(localPos.x + halfSize.x) < eps) {
    localNormal = vec3<f32>(-1.0, 0.0, 0.0);
  } else if (abs(localPos.x - halfSize.x) < eps) {
    localNormal = vec3<f32>(1.0, 0.0, 0.0);
  } else if (abs(localPos.y + halfSize.y) < eps) {
    localNormal = vec3<f32>(0.0, -1.0, 0.0);
  } else if (abs(localPos.y - halfSize.y) < eps) {
    localNormal = vec3<f32>(0.0, 1.0, 0.0);
  } else if (abs(localPos.z + halfSize.z) < eps) {
    localNormal = vec3<f32>(0.0, 0.0, -1.0);
  } else {
    localNormal = vec3<f32>(0.0, 0.0, 1.0);
  }

  let worldPos = linear * localPos + translation;
  let tWorld = dot(worldPos - ray.origin, ray.direction);
  if ((tWorld < 0.001) || (tWorld >= (*hit).t)) {
    return false;
  }

  let normalMatrix = transpose(invLinear);
  var worldNormal = normalize(normalMatrix * localNormal);
  if (dot(worldNormal, ray.direction) > 0.0) {
    worldNormal = -worldNormal;
  }

  (*hit).t = tWorld;
  (*hit).position = worldPos;
  (*hit).normal = worldNormal;
  (*hit).localPosition = localPos ;
  (*hit).id = id ;
  return true;
}

fn tryGround(id : u32, ray : Ray, hit : ptr<function, HitInfo>) -> bool {
  let normal = vec3<f32>(0.0, 1.0, 0.0);
  let denom = dot(ray.direction, normal);
  if (abs(denom) < 0.001) {
    return false;
  }
  let t = (-1.0 - ray.origin.y) / denom;
  if ((t < 0.001) || (t >= (*hit).t)) {
    return false;
  }
  let pos = ray.origin + ray.direction * t;
  (*hit).t = t;
  (*hit).position = pos;
  (*hit).normal = normal;
  (*hit).id = id ;
  return true;
}
