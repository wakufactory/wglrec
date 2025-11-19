// 4D simplex noise functions from Ashima Arts (WGSL port)

fn splat2(v: f32) -> vec2<f32> {
  return vec2<f32>(v, v);
}

fn splat3(v: f32) -> vec3<f32> {
  return vec3<f32>(v, v, v);
}

fn splat4(v: f32) -> vec4<f32> {
  return vec4<f32>(v, v, v, v);
}

fn mod289_vec4(x: vec4<f32>) -> vec4<f32> {
  return x - floor(x * (1.0 / 289.0)) * 289.0;
}

fn mod289_f32(x: f32) -> f32 {
  return x - floor(x * (1.0 / 289.0)) * 289.0;
}

fn permute_vec4(x: vec4<f32>) -> vec4<f32> {
  return mod289_vec4(((x * 34.0) + 10.0) * x);
}

fn permute_f32(x: f32) -> f32 {
  return mod289_f32(((x * 34.0) + 10.0) * x);
}

fn taylor_inv_sqrt_vec4(r: vec4<f32>) -> vec4<f32> {
  return splat4(1.79284291400159) - splat4(0.85373472095314) * r;
}

fn taylor_inv_sqrt_f32(r: f32) -> f32 {
  return 1.79284291400159 - 0.85373472095314 * r;
}

fn grad4(j: f32, ip: vec4<f32>) -> vec4<f32> {
  let ones = vec4<f32>(1.0, 1.0, 1.0, -1.0);
  let xyz = floor(fract(splat3(j) * ip.xyz) * splat3(7.0)) * splat3(ip.z) - splat3(1.0);
  var p = vec4<f32>(xyz, 0.0);
  p.w = 1.5 - dot(abs(xyz), ones.xyz);
  let s = select(vec4<f32>(0.0), vec4<f32>(1.0), p < vec4<f32>(0.0));
  let adjusted_xyz = xyz + (s.xyz * splat3(2.0) - splat3(1.0)) * s.www;
  return vec4<f32>(adjusted_xyz, p.w);
}

const F4: f32 = 0.309016994374947451; // (sqrt(5) - 1)/4
const GRAD_IP: vec4<f32> = vec4<f32>(1.0 / 294.0, 1.0 / 49.0, 1.0 / 7.0, 0.0);

fn wrap_component(value: vec4<f32>, repeat: vec4<f32>) -> vec4<f32> {
  let mask = repeat > splat4(0.0);
  let safe_repeat = select(splat4(1.0), repeat, mask);
  let wrapped = value - safe_repeat * floor(value / safe_repeat);
  return select(value, wrapped, mask);
}

fn fade4(t: vec4<f32>) -> vec4<f32> {
  return t * t * t * (t * (t * splat4(6.0) - splat4(15.0)) + splat4(10.0));
}

fn grad_dot(hash: f32, offset: vec4<f32>) -> f32 {
  return dot(grad4(hash, GRAD_IP), offset);
}

fn snoise(v: vec4<f32>) -> f32 {
  let C = vec4<f32>(
    0.138196601125011,
    0.276393202250021,
    0.414589803375032,
    -0.447213595499958
  );

  // First corner
  var i = floor(v + splat4(dot(v, splat4(F4))));
  let x0 = v - i + splat4(dot(i, C.xxxx));

  // Other corners
  var i0 = vec4<f32>(0.0);
  let isX = step(x0.yzw, x0.xxx);
  let isYZ = step(x0.zww, x0.yyz);
  i0.x = isX.x + isX.y + isX.z;
  i0.y = 1.0 - isX.x;
  i0.z = 1.0 - isX.y;
  i0.w = 1.0 - isX.z;
  i0.y = i0.y + isYZ.x + isYZ.y;
  i0.z = i0.z + (1.0 - isYZ.x);
  i0.w = i0.w + (1.0 - isYZ.y);
  i0.z = i0.z + isYZ.z;
  i0.w = i0.w + (1.0 - isYZ.z);

  let i3 = clamp(i0, splat4(0.0), splat4(1.0));
  let i2 = clamp(i0 - splat4(1.0), splat4(0.0), splat4(1.0));
  let i1 = clamp(i0 - splat4(2.0), splat4(0.0), splat4(1.0));

  let x1 = x0 - i1 + C.xxxx;
  let x2 = x0 - i2 + C.yyyy;
  let x3 = x0 - i3 + C.zzzz;
  let x4 = x0 + C.wwww;

  i = mod289_vec4(i);
  let j0 = permute_f32(permute_f32(permute_f32(permute_f32(i.w) + i.z) + i.y) + i.x);
  let j1 = permute_vec4(
    permute_vec4(
      permute_vec4(
        permute_vec4(i.w + vec4<f32>(i1.w, i2.w, i3.w, 1.0))
        + i.z + vec4<f32>(i1.z, i2.z, i3.z, 1.0)
      )
      + i.y + vec4<f32>(i1.y, i2.y, i3.y, 1.0)
    )
    + i.x + vec4<f32>(i1.x, i2.x, i3.x, 1.0)
  );

  var p0 = grad4(j0, GRAD_IP);
  var p1 = grad4(j1.x, GRAD_IP);
  var p2 = grad4(j1.y, GRAD_IP);
  var p3 = grad4(j1.z, GRAD_IP);
  var p4 = grad4(j1.w, GRAD_IP);

  let norm = taylor_inv_sqrt_vec4(vec4<f32>(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
  p0 *= splat4(norm.x);
  p1 *= splat4(norm.y);
  p2 *= splat4(norm.z);
  p3 *= splat4(norm.w);
  p4 *= splat4(taylor_inv_sqrt_f32(dot(p4, p4)));

  let m0 = max(
    splat3(0.6) - vec3<f32>(dot(x0, x0), dot(x1, x1), dot(x2, x2)),
    splat3(0.0)
  );
  let m1 = max(
    splat2(0.6) - vec2<f32>(dot(x3, x3), dot(x4, x4)),
    splat2(0.0)
  );

  let m0_sq = m0 * m0;
  let m1_sq = m1 * m1;

  return 49.0 * (
    dot(m0_sq * m0_sq, vec3<f32>(dot(p0, x0), dot(p1, x1), dot(p2, x2))) +
    dot(m1_sq * m1_sq, vec2<f32>(dot(p3, x3), dot(p4, x4)))
  );
}

fn pnoise(v: vec4<f32>, repeat: vec4<f32>) -> f32 {
  var Pi0 = floor(v);
  var Pf0 = fract(v);
  var Pi1 = Pi0 + splat4(1.0);
  let Pf1 = Pf0 - splat4(1.0);

  Pi0 = wrap_component(Pi0, repeat);
  Pi1 = wrap_component(Pi1, repeat);

  let Pi0_mod = mod289_vec4(Pi0);
  let Pi1_mod = mod289_vec4(Pi1);

  let ix = vec4<f32>(Pi0_mod.x, Pi1_mod.x, Pi0_mod.x, Pi1_mod.x);
  let iy = vec4<f32>(Pi0_mod.y, Pi0_mod.y, Pi1_mod.y, Pi1_mod.y);
  let iz0 = vec4<f32>(Pi0_mod.z, Pi0_mod.z, Pi0_mod.z, Pi0_mod.z);
  let iz1 = vec4<f32>(Pi1_mod.z, Pi1_mod.z, Pi1_mod.z, Pi1_mod.z);
  let iw0 = vec4<f32>(Pi0_mod.w, Pi0_mod.w, Pi0_mod.w, Pi0_mod.w);
  let iw1 = vec4<f32>(Pi1_mod.w, Pi1_mod.w, Pi1_mod.w, Pi1_mod.w);

  let ixy = permute_vec4(permute_vec4(ix) + iy);
  let ixy0 = permute_vec4(ixy + iz0);
  let ixy1 = permute_vec4(ixy + iz1);

  let j0 = permute_vec4(ixy0 + iw0);
  let j1 = permute_vec4(ixy0 + iw1);
  let j2 = permute_vec4(ixy1 + iw0);
  let j3 = permute_vec4(ixy1 + iw1);

  let x0 = vec4<f32>(Pf0.x, Pf1.x, Pf0.x, Pf1.x);
  let y0 = vec4<f32>(Pf0.y, Pf0.y, Pf1.y, Pf1.y);
  let z0 = splat4(Pf0.z);
  let z1 = splat4(Pf1.z);
  let w0 = splat4(Pf0.w);
  let w1 = splat4(Pf1.w);

  let n0000 = grad_dot(j0.x, vec4<f32>(x0.x, y0.x, z0.x, w0.x));
  let n1000 = grad_dot(j0.y, vec4<f32>(x0.y, y0.y, z0.y, w0.y));
  let n0100 = grad_dot(j0.z, vec4<f32>(x0.z, y0.z, z0.z, w0.z));
  let n1100 = grad_dot(j0.w, vec4<f32>(x0.w, y0.w, z0.w, w0.w));

  let n0001 = grad_dot(j1.x, vec4<f32>(x0.x, y0.x, z0.x, w1.x));
  let n1001 = grad_dot(j1.y, vec4<f32>(x0.y, y0.y, z0.y, w1.y));
  let n0101 = grad_dot(j1.z, vec4<f32>(x0.z, y0.z, z0.z, w1.z));
  let n1101 = grad_dot(j1.w, vec4<f32>(x0.w, y0.w, z0.w, w1.w));

  let n0010 = grad_dot(j2.x, vec4<f32>(x0.x, y0.x, z1.x, w0.x));
  let n1010 = grad_dot(j2.y, vec4<f32>(x0.y, y0.y, z1.y, w0.y));
  let n0110 = grad_dot(j2.z, vec4<f32>(x0.z, y0.z, z1.z, w0.z));
  let n1110 = grad_dot(j2.w, vec4<f32>(x0.w, y0.w, z1.w, w0.w));

  let n0011 = grad_dot(j3.x, vec4<f32>(x0.x, y0.x, z1.x, w1.x));
  let n1011 = grad_dot(j3.y, vec4<f32>(x0.y, y0.y, z1.y, w1.y));
  let n0111 = grad_dot(j3.z, vec4<f32>(x0.z, y0.z, z1.z, w1.z));
  let n1111 = grad_dot(j3.w, vec4<f32>(x0.w, y0.w, z1.w, w1.w));

  let u = fade4(Pf0);

  let nx00 = mix(n0000, n1000, u.x);
  let nx10 = mix(n0100, n1100, u.x);
  let nx01 = mix(n0010, n1010, u.x);
  let nx11 = mix(n0110, n1110, u.x);
  let nxy0 = mix(nx00, nx10, u.y);
  let nxy1 = mix(nx01, nx11, u.y);
  let nz0 = mix(nxy0, nxy1, u.z);

  let nx00_w = mix(n0001, n1001, u.x);
  let nx10_w = mix(n0101, n1101, u.x);
  let nx01_w = mix(n0011, n1011, u.x);
  let nx11_w = mix(n0111, n1111, u.x);
  let nxy0_w = mix(nx00_w, nx10_w, u.y);
  let nxy1_w = mix(nx01_w, nx11_w, u.y);
  let nz1 = mix(nxy0_w, nxy1_w, u.z);

  return mix(nz0, nz1, u.w);
}

fn hsl2rgb(c: vec3<f32>) -> vec3<f32> {
  let q = splat3(c.x * 6.0) + vec3<f32>(0.0, 4.0, 2.0);
  let mod6 = q - splat3(6.0) * floor(q / splat3(6.0));
  let rgb = clamp(abs(mod6 - splat3(3.0)) - splat3(1.0), splat3(0.0), splat3(1.0));
  let k = 1.0 - abs(2.0 * c.z - 1.0);
  return splat3(c.z) + splat3(c.y) * (rgb - splat3(0.5)) * splat3(k);
}
