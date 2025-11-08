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
  float t = pow(0.5*( dot(normalize(vec3(0.5,1.,0.)),normalize(ray.direction))+1.0),2.);
  vec3 top = vec3(1.2, 1.2, 2.3)*0.5;
  vec3 bottom = vec3(0.05, 0.07, 0.10);
  return mix(bottom, top, clamp(t, 0.0, 2.0));
}

//シーン初期化
void setupScene(float time) {

}
//シーンのhit test 
void intersectScene(Ray ray, inout HitInfo hit) {
  float time = uTime;
  // シーン内のオブジェクトとの交差をすべてチェック
    //光源判定
  if( trySphere(ray, hit, vec3(2.0, 6.5, 0.0), 1.)) hit.material = Mat_light(vec3(4.0, 2.0, 9.0) * 5.65) ;
  //地面判定
  if( tryGround(ray, hit)) {
    vec2 checkerCoords = hit.position.xz * 0.5;
    float checker = mod(floor(checkerCoords.x) + floor(checkerCoords.y), 2.0);
    vec3 colorA = vec3(0.85, 0.85, 0.85);
    vec3 colorB = vec3(0.23, 0.25, 0.28);
    Material gmaterial = Mat_lambert(vec3(0.0));
    gmaterial.albedo = mix(colorA, colorB, checker);
    hit.material = gmaterial ;
  };
  // bounding sphere
  if(tryBoundingSphere(ray,hit,vec3(0.,0.,0.),3.)) {
    vec3 centerA = vec3(sin(time * 0.6) * 2.0, 0.15 + 2.0 * cos(time * 0.4), -1.5);
    vec3 centerB = vec3(-1.4 + 0.5 * sin(time * 0.8), -0.2, -0.2 + 1.0 * cos(time * 0.5));
    vec3 centerC = vec3(1.5 + 0.3 * sin(time * 0.7), 0.2 + 0.25 * sin(time * 0.9 + 1.0), -0.5);

    if( trySphere(ray, hit,centerA, 1.0) ) hit.material = Mat_brdf(vec3(0.85, 0.3, 0.2), .3, 0.7,1.); 
    if( trySphere(ray, hit, centerB, 0.8)) hit.material = Mat_mirror(vec3(0.15, 0.16, 0.5));
    if( trySphere(ray, hit, centerC, 0.6)) {
      if((mod((hit.position.y-centerC.y)/0.2,1.)<0.5)) hit.material = Mat_brdf(vec3(1.55, 1.5, 0.0),1.0,0.,1.);
      else hit.material = Mat_brdf(vec3(0, 1.5, 1.5),1.0,0.5,.5);
    }
    vec3 boxSize = vec3(1.2, 0.9, 0.8);
    float boxSpin = time * 2.6;
    vec3 boxOffset = vec3(0.0, 0.05, -1.8 + sin(time * 2.0) * 2.0);
    mat4 boxTransform = composeTransform(vec3(0., boxSpin, boxSpin), vec3(1.), boxOffset);
    if( tryBoxTransformed(ray, hit,boxSize, boxTransform)) hit.material = Mat_mirror(vec3(1.0, 2.0, 1.0));
  }

}
