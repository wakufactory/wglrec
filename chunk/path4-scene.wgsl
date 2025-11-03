fn setCamera(
  camPos : ptr<function, vec3<f32>>,
  camTarget : ptr<function, vec3<f32>>,
  camUp : ptr<function, vec3<f32>>,
  fov : ptr<function, f32>
) {
  let current = (*camPos);
  (*camPos) = vec3<f32>(current.x, current.y + getTime() * 1.0, current.z);
}

fn environment(ray : Ray) -> vec3<f32> {
  let baseDir = normalize(vec3<f32>(0.5, 1.0, 0.0));
  let t = pow(0.5 * (dot(baseDir, normalize(ray.direction)) + 1.0), 2.0);
  let top = vec3<f32>(1.2, 1.2, 2.3) * 0.5;
  let bottom = vec3<f32>(0.05, 0.07, 0.10);
  return mix(bottom, top, clamp(t, 0.0, 2.0));
}

fn setupScene(_time : f32) {
}

fn intersectScene(ray : Ray, hit : ptr<function, HitInfo>) {
  let time = getTime();

  if (trySphere(ray, hit, vec3<f32>(2.0, 6.5, 0.0), 1.0)) {
    (*hit).material = Mat_light(vec3<f32>(4.0, 2.0, 9.0) * 5.65);
  }

  if (tryGround(ray, hit)) {
    let checkerCoords = (*hit).position.xz * 0.5;
    let checker = modFloat(floor(checkerCoords.x) + floor(checkerCoords.y), 2.0);
    let colorA = vec3<f32>(0.85, 0.85, 0.85);
    let colorB = vec3<f32>(0.23, 0.25, 0.28);
    var groundMaterial = Mat_lambert(vec3<f32>(0.0));
    groundMaterial.albedo = mix(colorA, colorB, checker);
    (*hit).material = groundMaterial;
  }

  if (tryBoundingSphere(ray, hit, vec3<f32>(0.0, 0.0, 0.0), 2.5)) {
    let centerA = vec3<f32>(sin(time * 0.6) * 2.0, 0.15 + 2.0 * cos(time * 0.4), -1.5);
    let centerB = vec3<f32>(-1.4 + 0.5 * sin(time * 0.8), -0.2, -0.2 + 1.0 * cos(time * 0.5));
    let centerC = vec3<f32>(1.5 + 0.3 * sin(time * 0.7), 0.2 + 0.25 * sin(time * 0.9 + 1.0), -0.5);

    if (trySphere(ray, hit, centerA, 1.0)) {
      (*hit).material = Mat_brdf(vec3<f32>(0.85, 0.3, 0.2), 0.3, 0.7, 1.0);
    }

    if (trySphere(ray, hit, centerB, 0.8)) {
      (*hit).material = Mat_mirror(vec3<f32>(0.15, 0.16, 0.5));
    }

    if (trySphere(ray, hit, centerC, 0.6)) {
      if (modFloat(((*hit).position.y - centerC.y) / 0.2, 1.0) < 0.5) {
        (*hit).material = Mat_brdf(vec3<f32>(1.55, 1.5, 0.0), 1.0, 0.0, 1.0);
      } else {
        (*hit).material = Mat_brdf(vec3<f32>(0.0, 1.5, 1.5), 1.0, 0.5, 0.5);
      }
    }

    let boxSize = vec3<f32>(1.2, 0.9, 0.8);
    let boxSpin = time * 2.6;
    let boxOffset = vec3<f32>(0.0, 0.05, -1.8 + sin(time * 2.0) * 2.0);
    let boxTransform = composeTransform(vec3<f32>(0.0, boxSpin, boxSpin), vec3<f32>(1.0, 1.0, 1.0), boxOffset);
    if (tryBoxTransformed(ray, hit, boxSize, boxTransform)) {
      (*hit).material = Mat_mirror(vec3<f32>(1.0, 2.0, 1.0));
    }
  }
}
