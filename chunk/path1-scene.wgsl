var<private> boxTransform : mat4x4<f32> = mat4x4<f32>(
  vec4<f32>(1.0, 0.0, 0.0, 0.0),
  vec4<f32>(0.0, 1.0, 0.0, 0.0),
  vec4<f32>(0.0, 0.0, 1.0, 0.0),
  vec4<f32>(0.0, 0.0, 0.0, 1.0)
);

fn setCamera(
  camPos : ptr<function, vec3<f32>>,
  camTarget : ptr<function, vec3<f32>>,
  camUp : ptr<function, vec3<f32>>,
  fov : ptr<function, f32>
) {
  let pos = (*camPos);
  (*camPos) = vec3<f32>(pos.x, pos.y + getTime() * 1.0, pos.z);
}

fn environment(ray : Ray) -> vec3<f32> {
  let t = 0.5 * (ray.direction.y + 1.0);
  let top = vec3<f32>(1.2, 1.2, 2.3) * 0.5;
  let bottom = vec3<f32>(0.05, 0.07, 0.10);
  return mix(bottom, top, clamp(t, 0.0, 2.0));
}

fn setupScene() {
  let time = getTime();
  let boxSpin = time * 2.6;
  let c = cos(boxSpin);
  let s = sin(boxSpin);
  let boxOffset = vec3<f32>(0.0, 0.05, -1.8 + sin(time * 2.0) * 2.0);
  let rotation = mat4x4<f32>(
    vec4<f32>(c, 0.0, -s, 0.0),
    vec4<f32>(0.0, 1.0, 0.0, 0.0),
    vec4<f32>(s, 0.0, c, 0.0),
    vec4<f32>(0.0, 0.0, 0.0, 1.0)
  );
  let translation = mat4x4<f32>(
    vec4<f32>(1.0, 0.0, 0.0, 0.0),
    vec4<f32>(0.0, 1.0, 0.0, 0.0),
    vec4<f32>(0.0, 0.0, 1.0, 0.0),
    vec4<f32>(boxOffset, 1.0)
  );
  boxTransform = translation * rotation;
}

fn intersectScene(ray : Ray, hit : ptr<function, HitInfo>) {
  let groundMaterial = Material(vec3<f32>(0.0), vec3<f32>(0.0), vec3<f32>(0.0), 1.0, MATERIAL_LAMBERT);
  tryGround(ray, groundMaterial, hit);

  let time = getTime();
  let centerA = vec3<f32>(sin(time * 0.6) * 2.0, 0.15 + 2.0 * cos(time * 0.4), -1.5);
  let centerB = vec3<f32>(-1.4 + 0.5 * sin(time * 0.8), -0.2, -0.2 + 1.0 * cos(time * 0.5));
  let centerC = vec3<f32>(1.5 + 0.3 * sin(time * 0.7), 0.2 + 0.25 * sin(time * 0.9 + 1.0), -0.5);

  let redMirror = Material(vec3<f32>(0.85, 0.3, 0.2), vec3<f32>(0.0), vec3<f32>(0.0), 1.0, MATERIAL_MIRROR);
  let blueMirror = Material(vec3<f32>(0.15, 0.16, 0.5), vec3<f32>(0.0), vec3<f32>(0.95), 0.02, MATERIAL_MIRROR);
  let goldGlossy = Material(vec3<f32>(0.55, 0.5, 0.0), vec3<f32>(0.0), vec3<f32>(1.0, 1.0, 0.2) * 2.0, 0.0, MATERIAL_GLOSSY);

  trySphere(ray, centerA, 1.0, redMirror, hit);
  trySphere(ray, centerB, 0.8, blueMirror, hit);
  trySphere(ray, centerC, 0.6, goldGlossy, hit);

  let boxSize = vec3<f32>(1.2, 0.9, 0.8);
  let boxMaterial = Material(vec3<f32>(0.25, 0.8, 0.3), vec3<f32>(0.0), vec3<f32>(0.0), 1.0, MATERIAL_MIRROR);
  tryBoxTransformed(ray, boxSize, boxTransform, boxMaterial, hit);

  let lightPulse = 5.65;
  let lightEmission = vec3<f32>(14.0, 12.0, 9.0) * lightPulse;
  let lightSource = Material(vec3<f32>(0.0), lightEmission, vec3<f32>(0.0), 1.0, MATERIAL_LIGHT);
  if (ray.kind == HIDDEN_LIGHT) {
    trySphere(ray, vec3<f32>(0.0, 6.5, 0.0), 1.0, lightSource, hit);
  }
}
