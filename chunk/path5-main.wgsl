// path tracing main

// ray tracer 
fn traceRay(initialRay : Ray, seed : ptr<function, u32>) -> vec3<f32> {
  var ray = initialRay;
  var throughput = vec3<f32>(1.0, 1.0, 1.0);
  var radiance = vec3<f32>(0.0, 0.0, 0.0);

  for (var bounce : i32 = 0; bounce < MAX_BOUNCES; bounce = bounce + 1) {
    var hit = defaultHitInfo();
    intersectScene(ray, &hit);

    radiance = radiance + throughput * hit.material.emission;
    if (hit.material.noref) {
      break;
    }

    ray.origin = hit.position + hit.normal * 0.001;
    if (!updateRay(bounce, hit, &ray, &throughput, seed)) {
      break;
    }
  }

  return radiance;
}

// vshader
@vertex
fn vs_main(@builtin(vertex_index) vertexIndex : u32) -> @builtin(position) vec4<f32> {
  let positions = array<vec2<f32>, 3>(
    vec2<f32>(-1.0, -3.0),
    vec2<f32>(-1.0, 1.0),
    vec2<f32>(3.0, 1.0)
  );
  return vec4<f32>(positions[vertexIndex], 0.0, 1.0);
}

// fshader main
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
  setupScene(getTime());

  let stereoSeparation = STEREO;
  if (stereoSeparation != 0.0) {
    var eye = -stereoSeparation * 0.5;
    res.x = res.x * 0.5;
    aspect = aspect * 0.5;
    if (pixel.x > res.x) {
      pixel = pixel - vec2<f32>(res.x, 0.0);
      eye = -eye;
    }
    let eyeOffset = eye * normalize(cross(camTarget - camPos, up));
    camPos = camPos + eyeOffset;
    if (STEREO_TARGET) {
      camTarget = camTarget + eyeOffset;
    }
  }

  let ndc = (pixel / res) * 2.0 - vec2<f32>(1.0, 1.0);
  let forward = normalize(camTarget - camPos);
  let right = normalize(cross(forward, up));
  let camUp = cross(right, forward);
  let tanHalfFov = tan(radians(fov) * 0.5);

  var baseSeed =
    u32(pixel.y) * 1973u +
    u32(pixel.x) * 9277u +
    374761393u +
    u32(RANDOM_SEED) * u32(getTime() * 100.0);
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
