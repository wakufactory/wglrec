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
  vec3 top = vec3(1.2, 1.2, 2.3)*1.;
  vec3 bottom = vec3(0., 0.0, 0.);
  return mix(bottom, top, clamp(t, 0.0, 2.0));
}

const int OBJNUM  = 6 ;

//シーン初期化
void setupScene(float time) {
  // object計算を初期化時に一回だけ
  int on = 0 ;

  //bounding sphere 
  initObject(
    on++,
    false,
    4,
    OBJ_SPHERE,
    ObjParam(vec3(0.,0.,0.), vec3(3.)),
    Mat_none(),
    false,
    m4unit
  );
  //box
  float boxSpin = time * 2.6;
  vec3 boxOffset = vec3(0.0, 0.05, -1.8 + sin(time * 2.0) * 2.0);
  mat4 boxTransform = composeTransform(vec3(0., boxSpin, boxSpin), vec3(1.), boxOffset);
  initObject(
    on++,
    true,
    0,
    OBJ_BOX,
    ObjParam(vec3(1.2, 0.9, 0.8), vec3(0.)),
    Mat_mirror(vec3(1.0, 2.0, 1.0)),
    true,
    boxTransform
  );
  // red ball
  vec3 redOffset = vec3(sin(time * 0.6) * 2.0, 0.15 + 2.0 * cos(time * 0.4), -1.5);
  mat4 redTransform = composeTransform(vec3(0.), vec3(1.0), redOffset);
  initObject(
    on++,
    true,
    0,
    OBJ_SPHERE,
    ObjParam(redOffset, vec3(1.)),
    Mat_brdf(vec3(0.85, 0.3, 0.2), .3, 0.7, 1.),
    false,
    redTransform
  );
  //blue ball
  initObject(
    on++,
    true,
    0,
    OBJ_SPHERE,
    ObjParam(vec3(-1.4 + 0.5 * sin(time * 0.8), -0.2, -0.2 + 1.0 * cos(time * 0.5)), vec3(0.8)),
    Mat_mirror(vec3(0.15, 0.16, 0.5)),
    false,
    m4unit
  );
  // gold ball
  initObject(
    on++,
    true,
    0,
    OBJ_SPHERE,
    ObjParam(vec3(1.5 + 0.3 * sin(time * 0.7), 0.2 + 0.25 * sin(time * 0.9 + 1.0), -0.5), vec3(0.6)),
    Mat_lambert(vec3(0.55, 0.5, 0.0)),
    false,
    m4unit
  );
  //light
  float lightPulse = 5.65;
  vec3 lightEmission = vec3(4.0, 2.0, 9.0) * lightPulse;
  initObject(
    on++,
    true,
    0,
    OBJ_SPHERE,
    ObjParam(vec3(2.0, 6.5, 0.0), vec3(1.)),
    Mat_light(lightEmission),
    false,
    m4unit
  );
}
//シーンのhit test 
void intersectScene(Ray ray, inout HitInfo hit) {
  // シーン内のオブジェクトとの交差をすべてチェック
  //地面判定
  Material gmaterial = Mat_lambert(vec3(0.0));
  tryGround(ray, gmaterial,hit);
/*
  if(trySphere(0,ray, hit)) {
    tryBoxTransformed(1,ray,hit) ;
    trySphereTransformed(2,ray, hit);
    trySphere(3,ray, hit);
    trySphere(4,ray, hit);
  }
  trySphere(5,ray, hit);
  return ;
*/
  for(int i=0;i<OBJNUM;i++) {
    int bounding = objects.bounding[i];
    bool isVisible = objects.visible[i];
    if(bounding > 0) {
      if(!trySphere(i,ray,hit)){
        i += bounding;
        continue ;
      }
      if(!isVisible) continue;
    } else if(!isVisible) {
      continue;
    }
    int type = objects.type[i];
    if(type==OBJ_BOX) {
      tryBoxTransformed(i,ray,hit);
    } else if(type==OBJ_SPHERE) {
      if(objects.useTrans[i]) {
        trySphereTransformed(i,ray, hit);
      } else {
        trySphere(i,ray, hit);
      }
    }
  }

}
