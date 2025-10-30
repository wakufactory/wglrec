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

