#line 2 4
// path tracing scene 

//frameごとのカメラ設定
void setCamera(inout vec3 camPos,inout vec3 target,inout vec3 up,inout float fov) {
  camPos.y += uTime*1. ;
//  fov = fov - uTime*4. ;
  return ;
}
//環境光の設定
vec3 environment(Ray ray) {
  // 簡易なグラデーション環境光
  float t = 0.5 * (ray.direction.y + 1.0);
  vec3 top = vec3(1.2, 1.2, 2.3)*0.5;
  vec3 bottom = vec3(0.05, 0.07, 0.10);
  return mix(bottom, top, clamp(t, 0.0, 2.0));
}
mat4 boxTransform  ;
//シーン初期化
void setupScene() {
  // transform計算を初期化時に一回だけ
  float time = uTime;
  float boxSpin = time * 2.6;
  float c = cos(boxSpin);
  float s = sin(boxSpin);
  vec3 boxOffset = vec3(0.0, 0.05, -1.8 + sin(time * 2.0) * 2.0);
  mat4 rotation = mat4(
    vec4(c, 0.0, -s, 0.0),
    vec4(0.0, 1.0, 0.0, 0.0),
    vec4(s, 0.0, c, 0.0),
    vec4(0.0, 0.0, 0.0, 1.0)
  );
  mat4 translation = mat4(
    vec4(1.0, 0.0, 0.0, 0.0),
    vec4(0.0, 1.0, 0.0, 0.0),
    vec4(0.0, 0.0, 1.0, 0.0),
    vec4(boxOffset, 1.0)
  );
  boxTransform = translation * rotation;
}
//シーンのhit test 
void intersectScene(Ray ray, inout HitInfo hit) {
  // シーン内のオブジェクトとの交差をすべてチェック
  //地面判定
  Material gmaterial = Material(vec3(0.0),vec3(0.0),vec3(0.0),1.0,MATERIAL_LAMBERT) ;
  tryGround(ray, gmaterial,hit);

  float time = uTime;
  vec3 centerA = vec3(sin(time * 0.6) * 2.0, 0.15 + 2.0 * cos(time * 0.4), -1.5);
  vec3 centerB = vec3(-1.4 + 0.5 * sin(time * 0.8), -0.2, -0.2 + 1.0 * cos(time * 0.5));
  vec3 centerC = vec3(1.5 + 0.3 * sin(time * 0.7), 0.2 + 0.25 * sin(time * 0.9 + 1.0), -0.5);

  Material redLambert = Material(vec3(0.85, 0.3, 0.2), vec3(0.0), vec3(0.0), 1.0, MATERIAL_MIRROR);
  Material blueMirror = Material(vec3(0.15, 0.16, 0.5), vec3(0.0), vec3(0.95), 0.02, MATERIAL_MIRROR);
  Material goldGlossy = Material(vec3(0.55, 0.5, 0.0), vec3(0.0), vec3(1.0, 1.0, 0.2)*2., 0., MATERIAL_GLOSSY);

  trySphere(ray, centerA, 1.0, redLambert, hit);
  trySphere(ray, centerB, 0.8, blueMirror, hit);
  trySphere(ray, centerC, 0.6, goldGlossy, hit);
  vec3 boxSize = vec3(1.2, 0.9, 0.8);
  Material boxLambert = Material(vec3(0.25, 0.8, 0.3), vec3(0.0), vec3(0.0), 1.0, MATERIAL_MIRROR);
  tryBoxTransformed(ray, boxSize, boxTransform, boxLambert, hit);

  //光源判定
  float lightPulse =5.65;
  vec3 lightEmission = vec3(14.0, 12.0, 9.0) * lightPulse;
  Material lightSource = Material(vec3(0.0), lightEmission, vec3(0.0), 1.0, MATERIAL_LIGHT);
  if(ray.kind==0) {
    trySphere(ray, vec3(0.0, 6.5, 0.0), 1., lightSource, hit);
  }

}
