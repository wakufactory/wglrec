#line 2 3
const int MATERIAL_NONE = -1;
const int MATERIAL_LAMBERT = 0;
const int MATERIAL_MIRROR = 1;
const int MATERIAL_LIGHT = 2;
const int MATERIAL_GLOSSY = 3;

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