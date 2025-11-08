// SDF ray marching

const boundingRadius = 1e32 ;
const maxSteps = 20 ;

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
// metaball 
fn metaballSDF(p : vec3<f32>, time:f32) ->f32 {
  let k = 0.5; // スムージング係数
  var d = 1e9 ;
  let d1 = sphereSDF(p, vec3<f32>(0.0, 1.-sin(time)*0.2, 0.0), 0.5);
  d = smin(d,d1,k) ;
  let d2 = sphereSDF(p, vec3<f32>(0.0, 0.0+sin(time)*0.2, 0.0), 0.5);
  d = smin(d,d2,k) ;
  let d3 = sphereSDF(p, vec3<f32>(0.0+sin(time*0.5)*0.5, 0.5,0.0), 0.6);
  d = smin(d,d3,k) ;
  return d ;  
}
fn mod_vec3(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
  return a - b * floor(a / b);
}

// SDF function
fn sdfDistanceFieldObject(p : vec3<f32>, time:f32) -> f32 {
//  let c:vec3<f32> = vec3<f32>(2.0) ;
//  let pp = mod_vec3(p ,c) ; 
  let m = metaballSDF(p,time) ;
  let t = torusSDF(p, vec3<f32>(0.,0.4,0.),1.2,time*.2) ;
  return smin(m,t,0.2);
}

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

 // if (!tryBoundingSphere(ray, hit, center, boundingRadius)) {
 //   return false;
 // }

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
