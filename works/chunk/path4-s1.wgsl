// path tracing scene 

//frameごとのカメラ設定
fn setCamera(
  camPos : ptr<function, vec3<f32>>,
  camTarget : ptr<function, vec3<f32>>,
  camUp : ptr<function, vec3<f32>>,
  fov : ptr<function, f32>
) {
  let current = (*camPos);
  (*camPos) = vec3<f32>(current.x, current.y + 1.+getTime() * 0., current.z);
  (*fov) = 60. ;
}
//環境光の設定
fn environment(ray : Ray) -> vec3<f32> {
  let baseDir = normalize(vec3<f32>(0.5, 1.0, 0.0));
  let t = pow(0.5 * (dot(baseDir, normalize(ray.direction)) + 1.0), 10.0);
  let top = vec3<f32>(1.2, 1.2, 2.3) * 5.;
  let bottom = vec3<f32>(0.05, 0.07, 0.10);
  return mix(bottom, top, clamp(t, 0.0, 2.0));
}
//ピクセルレンダリング最初に一回呼ばれる
fn setupScene(_time : f32) {
}

//シーンのhit test 
fn intersectScene(ray : Ray, hit : ptr<function, HitInfo>) {
  let time = getTime();
  let ts = time * 2*PI * 1. ;
  //光源判定
  if (false && trySphere(ray, hit, vec3<f32>(2.0, 6.5, 0.0)*2., 5.0)) {
    (*hit).material = Mat_light(vec3<f32>(4.0, 4.0, 4.0) * 1.);
  }
  //地面判定
  if (true && tryGround(ray, hit)) {
    let checkerCoords = (*hit).position.xz * 0.5;
    let checker = modFloat(floor(checkerCoords.x) + floor(checkerCoords.y), 2.0);
    let colorA = vec3<f32>(0.85, 0.85, 0.85);
    let colorB = vec3<f32>(0.23, 0.25, 0.28);
    var groundMaterial = Mat_lambert(vec3<f32>(0.0));
    groundMaterial.albedo = mix(colorA, colorB, checker);
    (*hit).material = groundMaterial;
  }

// bounding sphere
  if (false && tryBoundingSphere(ray, hit, vec3<f32>(0.0, 0.0, 0.0), 3.)) {

    let centerA = vec3<f32>(
      sin(ts*.2) * 1.0,
      0.15 + 1.0 * cos(ts*.2),
      -0.3);
    let centerB = vec3<f32>(
      -1.4 + 0.5 * sin(ts*.4),
      -0.2,
      -0.2 + 1.0 * cos(ts*.4));
    let centerC = vec3<f32>(
     1.5,
      0.2 + 0.6 * sin(ts + 1.0),
       -.2 + 0.6 * sin(ts));
    //red sphere
    if (trySphere(ray, hit, centerA, 0.8)) {
      (*hit).material = Mat_brdf(vec3<f32>(0.85, 0.1, 0.1)*2., 0.3, 0.7, 1.0);
    }
    // blue sphere
    if (trySphere(ray, hit, centerB, 0.8)) {
      (*hit).material = Mat_mirror(vec3<f32>(0.15, 0.16, 0.5)*2.);
      let lpos = ((*hit).position - centerB) ;
      (*hit).normal += vec3<f32>(0.,clamp(abs(sin(lpos.y*30.*PI)*0.2)-.1,0.,0.1),0.) ;  //擬似バンプ
    }
    //yellow sphere
    if (trySphere(ray, hit, centerC, 0.8)) {
      //しましまつける
      if (modFloat(((*hit).position.y - centerC.y) / 0.2, 1.0) < 0.5) {
        (*hit).material = Mat_brdf(vec3<f32>(1.55, 1.5, 0.0), 1.0, 0.0, 1.0);
      } else {
        (*hit).material = Mat_brdf(vec3<f32>(0.0, 1.5, 1.5), 0.5, 0.5, 1.);
      }
    }
    //spin box 
    let boxSize = vec3<f32>(1.2, 0.9, 0.8);
    let boxSpin = ts*0.5;
    let boxOffset = vec3<f32>(0.0, 0.05, -1.8 + sin(time * 2.0) * 2.0);
    let boxTransform = composeTransform(vec3<f32>(0.0, boxSpin, boxSpin), vec3<f32>(1.0, 1.0, 1.0), boxOffset);
    if (false && tryBoxTransformed(ray, hit, boxSize, boxTransform)) {
      (*hit).material = Mat_mirror(vec3<f32>(1.0, 2.0, 1.0));
    }
  }
  // SDF object 
  if(tryDistanceFieldObject(ray,hit,ts)) {
    (*hit).material = Mat_mirror(vec3<f32>(0.85, 0.8, 0.1)*2.);
    
      if (modFloat(((*hit).position.z - 0.) / 0.05, 1.0) < 0.5) {
        (*hit).material = Mat_mirror(vec3<f32>(0.85, 0.8, 0.1));
      } else {
        (*hit).material = Mat_mirror(vec3<f32>(0.45, 0.4, 0.1));
      }
    
  }
}
