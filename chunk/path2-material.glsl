#line 2 3
const int MATERIAL_NONE = -1;
const int MATERIAL_LAMBERT = 0;
const int MATERIAL_MIRROR = 1;
const int MATERIAL_LIGHT = 2;
const int MATERIAL_GLOSSY = 3;
const int MATERIAL_TRANSPARENT = 4;

//material
struct Material {
  vec3 albedo;
  vec3 emission;
  vec3 specular;
  float roughness;
  int type;
};

// hit状態の保持
struct HitInfo {
  float t;
  vec3 position;
  vec3 normal;
  Material material;
};



//反射方向を決める関数
vec3 cosineSampleHemisphere(vec2 xi, vec3 normal) {
  // コサイン加重サンプリングで半球方向に新しいレイを生成
  float phi = 2.0 * PI * xi.x;
  float cosTheta = sqrt(1.0 - xi.y);
  float sinTheta = sqrt(xi.y);
  vec3 tangent, bitangent;
  orthonormalBasis(normal, tangent, bitangent);
  vec3 localDir = vec3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
  return normalize(
    localDir.x * tangent +
    localDir.y * bitangent +
    localDir.z * normal
  );
}

vec3 samplePhongLobe(vec3 reflectDir, float exponent, vec2 xi) {
  // Phongローブに従って鏡面方向まわりをサンプリング
  float cosTheta = pow(xi.x, 1.0 / (exponent + 1.0));
  float sinTheta = sqrt(max(0.0, 1.0 - cosTheta * cosTheta));
  float phi = 2.0 * PI * xi.y;
  vec3 tangent, bitangent;
  orthonormalBasis(reflectDir, tangent, bitangent);
  vec3 localDir = vec3(
    sinTheta * cos(phi),
    sinTheta * sin(phi),
    cosTheta
  );
  return normalize(
    localDir.x * tangent +
    localDir.y * bitangent +
    localDir.z * reflectDir
  );
}

void updateRay(
  int bounce,
  HitInfo hit,
  inout Ray ray,
  inout vec3 throughput,
  uint seed) 
  {
    vec3 newDir ;
    //鏡面反射
    if (hit.material.type == MATERIAL_MIRROR) {
      newDir = reflect(ray.direction, hit.normal);  //反射方向は一意に定まる
      throughput *= hit.material.albedo;
      ray.kind = HIDDEN_LIGHT ;
    }

    //GLOSSY
    if (hit.material.type == MATERIAL_GLOSSY) {
      float specIntensity = max(hit.material.specular.r, max(hit.material.specular.g, hit.material.specular.b));
      float diffIntensity = max(hit.material.albedo.r, max(hit.material.albedo.g, hit.material.albedo.b));
      float totalIntensity = specIntensity + diffIntensity;
      float specProb = (totalIntensity > 0.0) ? (specIntensity / totalIntensity) : 0.0;
      specProb = min(specProb, 0.95);

      float choice = rand(seed);
      if (choice < specProb && specIntensity > 0.0) {
        vec2 xiSpec = rand2(seed);
        float gloss = clamp(1.0 - hit.material.roughness, 0.0, 0.999);
        float exponent = mix(5.0, 200.0, gloss * gloss);
        vec3 reflectDir = reflect(ray.direction, hit.normal);
        newDir = samplePhongLobe(reflectDir, exponent, xiSpec);
        if (dot(newDir, hit.normal) <= 0.0) {
          newDir = reflectDir;
        }
        throughput *= hit.material.specular / max(specProb, 0.001);
        ray.kind = 0 ;
      } else {
        vec2 xiDiff = rand2(seed);
        newDir = cosineSampleHemisphere(xiDiff, hit.normal);
        float diffuseProb = max(1.0 - specProb, 0.001);
        throughput *= hit.material.albedo / diffuseProb;
      }

      float p = max(
        max(hit.material.albedo.r, max(hit.material.albedo.g, hit.material.albedo.b)),
        max(hit.material.specular.r, max(hit.material.specular.g, hit.material.specular.b))
      );
      p = clamp(p, 0.1, 0.95);
      if (bounce > 2) {
        float rr = rand(seed);
        if (rr > p) {
          return;
        }
        throughput *= 1.0 / p;
      }
    } 
    //TRANSPARENT
    // ガラスなどの透明材質。屈折率の情報は roughness を使って受け取る。
    if (hit.material.type == MATERIAL_TRANSPARENT) {
      // roughness を屈折率として扱う。1.0 未満の場合は空気より密度が低くなるので 1.0 で打ち止め。
      float ior = max(hit.material.roughness, 1.0); // use roughness as IoR slot
      vec3 incident = normalize(ray.direction);
      vec3 surfaceNormal = hit.normal;
      bool entering = dot(incident, surfaceNormal) < 0.0;
      float etaI = 1.0;
      float etaT = ior;
      vec3 n = surfaceNormal;
      if (!entering) {
        n = -surfaceNormal;
        float tmp = etaI;
        etaI = etaT;
        etaT = tmp;
      }

      float eta = etaI / etaT;
      float cosIncident = clamp(dot(-incident, n), 0.0, 1.0);
      float sinT2 = eta * eta * (1.0 - cosIncident * cosIncident);
      vec3 reflectDir = reflect(incident, n);

      // フレネル反射率。屈折・反射のバランスを角度によって計算する。
      float r0 = pow((etaT - etaI) / (etaT + etaI), 2.0);
      float fresnel = r0 + (1.0 - r0) * pow(1.0 - cosIncident, 5.0);
      float reflectProb = fresnel;
      vec3 reflectColor = hit.material.specular;
      vec3 refractDir = vec3(0.0);
      if (sinT2 <= 1.0) {
        refractDir = normalize(refract(incident, n, eta));
      } else {
        // 全反射が発生した場合は屈折側には進めないので反射のみ。
        reflectProb = 1.0;
        reflectColor = max(reflectColor, hit.material.albedo);
      }

      vec3 transmitColor = hit.material.albedo;
      float reflectStrength = max(reflectColor.r, max(reflectColor.g, reflectColor.b));
      if (sinT2 <= 1.0) {
        // specular が 0 なら反射を無効化。非物理だけどノイズ防止のため。
        reflectProb *= clamp(reflectStrength, 0.0, 1.0);
      }

      float choice = rand(seed);
      if (choice < reflectProb) {
        // 反射を選択。確率で割って期待値を一致させる。
        newDir = reflectDir;
        throughput *= reflectColor / max(reflectProb, 0.001);
        float offsetSign = entering ? 1.0 : -1.0;
        ray.origin = hit.position + surfaceNormal * offsetSign * 0.001;
      } else {
        // 屈折を選択。透過時は屈折率比に応じてレイのエネルギーを補正。
        newDir = refractDir;
        float transmitProb = max(1.0 - reflectProb, 0.001);
        float etaScale = eta * eta;
        throughput *= transmitColor * etaScale / transmitProb;
        float offsetSign = entering ? -1.0 : 1.0;
        ray.origin = hit.position + surfaceNormal * offsetSign * 0.001;
      }

      ray.kind = 0;
    }
    //LAMBERT
    if (hit.material.type == MATERIAL_LAMBERT) {
      vec2 xi = rand2(seed);
      newDir = cosineSampleHemisphere(xi, hit.normal);
      throughput *= hit.material.albedo;
      //russian roulette
      float p = max(hit.material.albedo.r, max(hit.material.albedo.g, hit.material.albedo.b));
      if (bounce > 2) {
        float rr = rand(seed);
        if (rr > p) {
          return;
        }
        throughput *= 1.0 / p;
      }
    }
    //新しい反射方向を返す
    ray.direction  =  newDir ;
}
