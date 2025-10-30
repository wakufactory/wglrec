#line 2 5

//シーン定義関数prototype
void setCamera(inout vec3 camPos,inout vec3 target,inout vec3 up,inout float fov) ;
void setupScene() ;
vec3 environment(Ray ray) ;   // 環境光 
void intersectScene(Ray ray, inout HitInfo hit);  // シーンの交差判定 

// rayをトレース
vec3 traceRay(Ray ray, inout uint seed) {
  // パストレーシングで放射輝度を積算
  vec3 throughput = vec3(1.0);
  vec3 radiance = vec3(0.0);

  //反射上限回数分のループ
  for (int bounce = 0; bounce < MAX_BOUNCES; ++bounce) {
    HitInfo hit;
    hit.t = 1e20;
    hit.material.albedo = vec3(0.0);
    hit.material.emission = vec3(0.0);
    hit.material.specular = vec3(0.0);
    hit.material.roughness = 1.0;
    hit.material.type = MATERIAL_NONE;
    //シーンの交差判定
    intersectScene(ray, hit);

    if (hit.material.type == MATERIAL_NONE) {  //物体にヒットしなかった場合
      radiance += throughput * environment(ray);  //環境光を加える
      break;
    }

    radiance += throughput * hit.material.emission;  //自己発光を加える
    if (hit.material.type == MATERIAL_LIGHT) { //光源ならそこで打ち切り
      break;
    }

    ray.origin = hit.position + hit.normal * 0.001;  //物体表面からちょっと浮かす
    updateRay(bounce,hit, ray,throughput,seed) ;
  }

  return radiance;
}

void main() {
  vec2 pixel = gl_FragCoord.xy;
  vec2 res = uResolution;
  float aspect = res.x / res.y;
  vec3 camPos = uCameraPos;
  vec3 target = uCameraTarget;
  vec3 up = normalize(uCameraUp);
  float fov = uCameraFovY ;

  //カメラのアニメーション設定
  setCamera(camPos,target,up,fov) ;
  //シーンの初期化
  setupScene() ;

  // for stereo render
  if (uStereoEye != 0.0) {
    res.x /= 2.0;
    if (uStereoEye > 0.0) pixel -= vec2(res.x, 0.0);
    aspect /= 2.0;
    vec3  eyeofs = uStereoEye * normalize(cross(target - camPos, up));
    camPos = camPos +eyeofs ;
    target = target +eyeofs ;
  }
  vec2 ndc = (pixel / res) * 2.0 - 1.0;
  vec3 forward = normalize(target - camPos);
  vec3 right = normalize(cross(forward, up));
  vec3 camUp = cross(right, forward);
  float tanHalfFov = tan(radians(fov) * 0.5);

  uint baseSeed = uint(pixel.y) * 1973u + uint(pixel.x) * 9277u + 374761393u;
  baseSeed ^= uint(SPP) * 668265263u;
  // ピクセルごとに複数サンプルを集めて平均化
  vec3 accum = vec3(0.0);
  for (int s = 0; s < SPP; ++s) {
    uint seed = baseSeed + uint(s) * 1597334677u;
    vec2 jitter = rand2(seed) - 0.5;
    vec2 jittered = ndc + jitter / res;
    vec3 dir = normalize(
      forward +
      right * jittered.x * aspect * tanHalfFov +
      camUp * jittered.y * tanHalfFov
    );
    Ray ray = Ray(camPos, dir,0);
    accum += traceRay(ray, seed);
  }

  vec3 color = accum / float(SPP);
  color = color / (color + vec3(1.0));
  color = pow(color, vec3(1.0 / 2.2));
  gl_FragColor = vec4(color, 1.0);
}
