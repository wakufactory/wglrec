fn traceRay(initialRay : Ray, seed : ptr<function, u32>) -> vec3<f32> {
  var ray = initialRay;
  var throughput = vec3<f32>(1.0, 1.0, 1.0);
  var radiance = vec3<f32>(0.0, 0.0, 0.0);

  for (var bounce : i32 = 0; bounce < MAX_BOUNCES; bounce = bounce + 1) {
    var rayKind : i32 = 0;
    var hit = HitInfo(1e20, vec3<f32>(0.0, 0.0, 0.0), vec3<f32>(0.0, 0.0, 0.0), defaultMaterial());
    hit.material.albedo = vec3<f32>(0.0, 0.0, 0.0);
    hit.material.emission = vec3<f32>(0.0, 0.0, 0.0);
    hit.material.specular = vec3<f32>(0.0, 0.0, 0.0);
    hit.material.roughness = 1.0;
    hit.material.kind = MATERIAL_NONE;
    intersectScene(ray, &hit);

    if (hit.material.kind == MATERIAL_NONE) {
      radiance = radiance + throughput * environment(ray);
      break;
    }

    radiance = radiance + throughput * hit.material.emission;
    if (hit.material.kind == MATERIAL_LIGHT) {
      break;
    }

    let origin = hit.position + hit.normal * 0.001;
    var newDir = ray.direction;

    if (hit.material.kind == MATERIAL_MIRROR) {
      newDir = reflect(ray.direction, hit.normal);
      throughput = throughput * hit.material.albedo;
      rayKind = HIDDEN_LIGHT;
    }

    if (hit.material.kind == MATERIAL_GLOSSY) {
      let specIntensity = max(hit.material.specular.x, max(hit.material.specular.y, hit.material.specular.z));
      let diffIntensity = max(hit.material.albedo.x, max(hit.material.albedo.y, hit.material.albedo.z));
      let totalIntensity = specIntensity + diffIntensity;
      var specProb = select(0.0, specIntensity / totalIntensity, totalIntensity > 0.0);
      specProb = min(specProb, 0.95);

      let choice = rand(seed);
      if ((choice < specProb) && (specIntensity > 0.0)) {
        let xiSpec = rand2(seed);
        let gloss = clamp(1.0 - hit.material.roughness, 0.0, 0.999);
        let exponent = mix(5.0, 200.0, gloss * gloss);
        let reflectDir = reflect(ray.direction, hit.normal);
        newDir = samplePhongLobe(reflectDir, exponent, xiSpec);
        if (dot(newDir, hit.normal) <= 0.0) {
          newDir = reflectDir;
        }
        throughput = throughput * (hit.material.specular / max(specProb, 0.001));
      } else {
        let xiDiff = rand2(seed);
        newDir = cosineSampleHemisphere(xiDiff, hit.normal);
        let diffuseProb = max(1.0 - specProb, 0.001);
        throughput = throughput * (hit.material.albedo / diffuseProb);
      }

      var p = max(
        max(hit.material.albedo.x, max(hit.material.albedo.y, hit.material.albedo.z)),
        max(hit.material.specular.x, max(hit.material.specular.y, hit.material.specular.z))
      );
      p = clamp(p, 0.1, 0.95);
      if (bounce > 2) {
        let rr = rand(seed);
        if (rr > p) {
          break;
        }
        throughput = throughput * (1.0 / p);
      }
    }

    if (hit.material.kind == MATERIAL_LAMBERT) {
      let xi = rand2(seed);
      newDir = cosineSampleHemisphere(xi, hit.normal);
      throughput = throughput * hit.material.albedo;
      let p = max(hit.material.albedo.x, max(hit.material.albedo.y, hit.material.albedo.z));
      if (bounce > 2) {
        let rr = rand(seed);
        if (rr > p) {
          break;
        }
        throughput = throughput * (1.0 / p);
      }
    }

    ray = makeRay(origin, newDir, rayKind);
  }

  return radiance;
}

@vertex
fn vs_main(@builtin(vertex_index) vertexIndex : u32) -> @builtin(position) vec4<f32> {
  var positions = array<vec2<f32>, 3>(
    vec2<f32>(-1.0, -3.0),
    vec2<f32>(-1.0, 1.0),
    vec2<f32>(3.0, 1.0)
  );
  return vec4<f32>(positions[vertexIndex], 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) fragCoord : vec4<f32>) -> @location(0) vec4<f32> {
  var pixel = fragCoord.xy;
  var res = getResolution();
  pixel.y = res.y - pixel.y;
  var aspect = res.x / res.y;
  var camPos = getCameraPosUniform();
  var camTarget = getCameraTargetUniform();
  var up = normalize(getCameraUpUniform());
  var fov = getCameraFovY();

  setCamera(&camPos, &camTarget, &up, &fov);
  setupScene();

  let stereoEye = getStereoEye();
  if (stereoEye != 0.0) {
    res.x = res.x * 0.5;
    if (stereoEye > 0.0) {
      pixel = pixel - vec2<f32>(res.x, 0.0);
    }
    aspect = aspect * 0.5;
    let eyeOffset = stereoEye * normalize(cross(camTarget - camPos, up));
    camPos = camPos + eyeOffset;
    camTarget = camTarget + eyeOffset;
  }

  let ndc = (pixel / res) * 2.0 - vec2<f32>(1.0, 1.0);
  let forward = normalize(camTarget - camPos);
  let right = normalize(cross(forward, up));
  let camUp = cross(right, forward);
  let tanHalfFov = tan(radians(fov) * 0.5);

  var baseSeed = u32(floor(pixel.y)) * 1973u + u32(floor(pixel.x)) * 9277u + 374761393u;
  baseSeed = baseSeed ^ (u32(SPP) * 668265263u);

  var accum = vec3<f32>(0.0, 0.0, 0.0);
  for (var s : i32 = 0; s < SPP; s = s + 1) {
    var seed = baseSeed + u32(s) * 1597334677u;
    let jitter = rand2(&seed) - vec2<f32>(0.5, 0.5);
    let jittered = ndc + jitter / res;
    let dir = normalize(
      forward +
      right * jittered.x * aspect * tanHalfFov +
      camUp * jittered.y * tanHalfFov
    );
    let ray = makeRay(camPos, dir, 0);
    accum = accum + traceRay(ray, &seed);
  }

  var color = accum / f32(SPP);
  color = color / (color + vec3<f32>(1.0, 1.0, 1.0));
  color = pow(color, vec3<f32>(1.0 / 2.2));
  return vec4<f32>(color, 1.0);
}
