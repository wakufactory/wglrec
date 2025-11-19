// path tracing scene 


// SDF ray marching
const boundingRadius = 1e32 ;
const maxSteps = 40 ;

fn sphereSDF(p : vec3<f32>, c:vec3<f32>, r:f32) ->f32 {
    return length(p - c) - r;
}
//torus
fn torusSDF(p : vec3<f32>, c:vec3<f32>, r:f32, time:f32) ->f32 {
  let radius = r+sin(time)*0.1 ;
  let majorRadius = max(radius, 0.001);
  let minorRadius = max(majorRadius * 0.35, 0.05);
  let q = vec2<f32>(length(p.xy-c.xy) - majorRadius, p.z-c.z);
  return length(q) - minorRadius;
}
// "smooth union" でブレンド
fn smin(a:f32, b:f32, k:f32) -> f32{
    let h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h*h*0.25*k;
}

fn mod_vec3(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
  return a - b * floor(a / b);
}

//*****************************************
// SDF function
fn sdfDistanceFieldObject(p : vec3<f32>, time:f32) -> f32 {
//  let pp = mod_vec3(p ,vec3<f32>(2.0)) ; 
  let k = 0.5; // スムージング係数
  var d = 1e9 ;
  let d1 = sphereSDF(p, vec3<f32>(sin(time)*0.5, 0.0,0.0), 1.);
  d = smin(d,d1,k) ;
  let d2 = sphereSDF(p, vec3<f32>(sin(time*2)*0.6, 0.5,0.0), 1.);
  d = smin(d,d2,k) ;
  let d3 = sphereSDF(p, vec3<f32>(sin(time*6)*0.5, 1.,0.0), 1.);
  d = smin(d,d3,k) ;
// let t = torusSDF(p, vec3<f32>(0.,0.4,0.),1.2,time*.2) ;
  return d;
}
//*****************************************

//法線算出 ∇SDF
fn estimateDistanceFieldNormal(
  p : vec3<f32>,
  epsilon : f32,
  time:f32
) -> vec3<f32> {
  let ex = vec3<f32>(epsilon, 0.0, 0.0);
  let ey = vec3<f32>(0.0, epsilon, 0.0);
  let ez = vec3<f32>(0.0, 0.0, epsilon);
  let dx = sdfDistanceFieldObject(p + ex,time) -
    sdfDistanceFieldObject(p - ex, time);
  let dy = sdfDistanceFieldObject(p + ey, time) -
    sdfDistanceFieldObject(p - ey, time);
  let dz = sdfDistanceFieldObject(p + ez, time) -
    sdfDistanceFieldObject(p - ez, time);
  return normalize(vec3<f32>(dx, dy, dz));
}

// ray marching SDF
fn tryDistanceFieldObject(
  ray : Ray,
  hit : ptr<function, HitInfo>,
  time : f32
) -> bool {
  let center = vec3(0.,0.,0.) ;
  let epsilon = 0.0008;
  let maxDistance = min((*hit).t, boundingRadius * 2.);
  var t = 0.001;

  for (var i = 0; i < maxSteps; i = i + 1) {
    if (t >= maxDistance) {
      break;
    }

    let worldPos = ray.origin + ray.direction * t;
    let localPos = worldPos - center;
    let dist = sdfDistanceFieldObject(localPos, time);

    if (abs(dist) < epsilon) {
      let normalLocal = estimateDistanceFieldNormal(localPos, epsilon * 0.5,time);
      var worldNormal = normalLocal;
      if (dot(worldNormal, ray.direction) > 0.0) {
        worldNormal = -worldNormal;
      }
      (*hit).t = t;
      (*hit).position = worldPos;
      (*hit).normal = worldNormal;
      return true;
    }

    if (dist < 0.0) {
      t = t - dist;
    } else {
      t = t + dist;
    }
    if (t < 0.0) {
      t = 0.0;
    }
  }

  return false;
}

//*****************************************
//frameごとのカメラ設定
fn setCamera(
  camPos : ptr<function, vec3<f32>>,
  camTarget : ptr<function, vec3<f32>>,
  camUp : ptr<function, vec3<f32>>,
  fov : ptr<function, f32>
) {
  //let current = (*camPos);
  let current = vec3(0.,.5,4.) ;
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
  let ts = time * 2*PI * 0.1 ;
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
    var groundMaterial = Mat_brdf(vec3<f32>(0.0),0.2,0.8,1.);
    groundMaterial.albedo = mix(colorA, colorB, checker);
    (*hit).material = groundMaterial;
  }

  // bounding sphere
  if (true && tryBoundingSphere(ray, hit, vec3<f32>(0.0, 0.0, 0.0), 2.5)) {

    // SDF object 
    if(tryDistanceFieldObject(ray,hit,ts)) {
      (*hit).material = Mat_mirror(vec3<f32>(0.85, 0.8, 0.1)*2.);
      
        if (modFloat(((*hit).position.z - 0.) / 0.1, 1.0) < 0.5) {
          (*hit).material = Mat_brdf(hsl2rgb(vec3<f32>(0.1, 0.5, 1.)),0.8,0.2,1.);
        } else {
          (*hit).material = Mat_brdf(hsl2rgb(vec3<f32>(0.1, 0.5, 0.8)),0.8,0.2,1.);
        }
      
    }
  }
}
