// path tracing scene 


// SDF ray marching
const boundingRadius = 1e32 ;
const maxSteps = 50 ;

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
  let k = .6; // スムージング係数
  var d = 1e20 ;
  let d1 = sphereSDF(p, vec3<f32>(0.,-4.,0.), 3.1);
  d = smin(d,d1,k) ;
  let d2 = sphereSDF(p, vec3<f32>(0.,(-cos(time)+1.)*2.-2., 0.),0.4);
  d = smin(d,d2,k) ;
  let d3 = sphereSDF(p, vec3<f32>(0.,(-cos(time+PI*0.9)+1.)*2.-2., 0.),0.4);
  d = max(d,d3) ;
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
  let epsilon = 0.001;
  let maxDistance = min((*hit).t, boundingRadius * 5.);
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
      t = t - dist ;
    } else {
      t = t + dist ;
    }
    if (t < 0.0) {
      t = 0.0;
    }
  }

  return false;
}

fn noise(pos:vec3<f32>,time:f32,tr:f32)-> f32 {
  let r = vec4<f32>(0.,0.,0.,tr) ;
  let n1 = pnoise(vec4<f32>(pos,time), r) ;
  let n2 = pnoise(vec4<f32>(pos*2.,time), r) ;
  let n3 = pnoise(vec4<f32>(pos*4.,time), r) ;
  let n4 = pnoise(vec4<f32>(pos*8.,time), r) ;
  return (n1+n2*0.5+n3*0.25+n4*0.125) ;
}
fn pfnoise(pos:vec3<f32>,time:f32)-> f32 {
  let n1 = snoise(vec4<f32>(pos,time)) ;
  let n2 = snoise(vec4<f32>(pos*2.,time)) ;
  let n3 = snoise(vec4<f32>(pos*4.,time)) ;
  let n4 = snoise(vec4<f32>(pos*8.,time)) ;
  return (n1+n2*0.5+n3*0.25+n4*0.125) ;
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
  let current = vec3(0.,.5,3.5) ;
  (*camPos) = vec3<f32>(current.x, current.y + 1.+getTime() * 0., current.z);
  (*camTarget).z = 0.5 ;
  (*fov) = 50. ;
}
//環境光の設定
fn environment(ray : Ray) -> vec3<f32> {
  let baseDir = normalize(vec3<f32>(0.5, 1.0, 0.0));
  let t = pow(0.5 * (dot(baseDir, normalize(ray.direction)) + 1.0), 10.0);
  let top = vec3<f32>(1.2, 1.2, 2.3) * 3.;
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
  if (true && trySphere(ray, hit, vec3<f32>(2.0, 6.5, 0.0)*2., 5.0)) {
    (*hit).material = Mat_light(vec3<f32>(4.0, 4.0, 4.0) * .5);
  }
  //地面判定
  if (true && tryGround(ray, hit)) {
    let checkerCoords = (*hit).position.xz * 0.5;
    let checker = modFloat(floor(checkerCoords.x) + floor(checkerCoords.y), 2.0);
    let colorA = vec3<f32>(0.85, 0.3, 0.3);
    let npos = (*hit).position * 1. ;
    let h = pow(clamp(pfnoise(npos,0.1)*1.,0.,1.),0.5)*0.2+0.5;
    let colorB = hsl2rgb(vec3<f32>(h, 0.8, 0.2)) ;
    var groundMaterial = Mat_brdf(colorB,0.2,0.8,1.);
    (*hit).material = groundMaterial;
  }

  // bounding sphere
  if (true && tryBoundingSphere(ray, hit, vec3<f32>(0.0, 0.0, 0.0), 3.)) {
    let posA = vec3<f32>(cos(ts),0.2,sin(ts)) ;
    if( trySphere(ray,hit,posA,0.6)) {
      let h = noise((*hit).position-posA,time*0.2,4.) ;
      if(h>0.2) {
        (*hit).material = Mat_mirror(hsl2rgb(vec3<f32>(0.,0.,0.5)));
      } else {
        (*hit).material = Mat_lambert(hsl2rgb(vec3<f32>(h,0.8,0.2)));
      }
    }
    let posB = vec3<f32>(cos(ts+PI),0.2,sin(ts+PI)) ;
    if( trySphere(ray,hit,posB,0.6)) {
      let h = noise((*hit).position-posB+vec3<f32>(10.,10.,10.),time*0.2,4.);
      if(h>0.2) {
        (*hit).material = Mat_mirror(hsl2rgb(vec3<f32>(0.,0.,0.5)));
      } else {
        (*hit).material = Mat_lambert(hsl2rgb(vec3<f32>(h+0.6,0.8,0.2)));
      }
    }
  }
}
