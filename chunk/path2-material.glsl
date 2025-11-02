#line 2 3
const int MATERIAL_NONE = -1;
const int MATERIAL_LAMBERT = 0;
const int MATERIAL_MIRROR = 1;
const int MATERIAL_LIGHT = 2;
const int MATERIAL_GLOSSY = 3;
const int MATERIAL_TRANSPARENT = 4;
const int MATERIAL_BRDF = 5; // Cook-Torrance系のBRDFを用いるマテリアル種別

#define Mat_none() Material(vec3(0.),vec3(0.),vec3(0.),0.,0.,0.,MATERIAL_NONE) 
#define Mat_lambert(color)  Material(color,vec3(0.),vec3(0.),0.,0.,1.,MATERIAL_LAMBERT)
#define Mat_brdf(color,roughness,metalness,ior)  Material(color,vec3(0.),vec3(0.),roughness,metalness,ior,MATERIAL_BRDF)
#define Mat_mirror(color)  Material(color,vec3(0.),vec3(0.),0.,0.,1.,MATERIAL_MIRROR)
#define Mat_trans(color,refcolor,ior)  Material(color,vec3(0.),refcolor,0.,0.,ior,MATERIAL_TRANSPARENT)
#define Mat_light(color)  Material(vec3(0.),color,vec3(0.),0.,0.,1.,MATERIAL_LIGHT)

//material
struct Material {
  vec3 albedo;
  vec3 emission;
  vec3 specular;
  float roughness;
  float metalness; // PBRマテリアル向けのメタリック値(0..1)
  float ior;       // 透過材質やBRDF計算で使用する屈折率
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

// === Cook-Torrance BRDF サンプリングまわりの補助構造体と関数 ===

// Cook-Torrance BRDFで使用するサンプル結果をまとめる構造体
struct CookTorranceSample {
  vec3 direction; // 次に飛ばすレイの方向
  vec3 weight;    // throughput に掛ける f * cos / pdf
  float pdf;      // ミックスPDF。0以下なら無効なサンプル
};

// コサイン分布のPDF。BRDFブレンドの重み付けに利用する。
float ct_CosineHemispherePDF(float ndotl) {
  return max(ndotl, 0.0) / PI;
}

// GGX法線分布関数（D項）
float ct_D_GGX(float ndoth, float alpha) {
  float a2 = alpha * alpha;
  float denom = (ndoth * ndoth) * (a2 - 1.0) + 1.0;
  return a2 / max(PI * denom * denom, 1e-7);
}

// Smithモデリングによる幾何減衰（G1項）
float ct_G1_GGX(float ndotx, float alpha) {
  float a2 = alpha * alpha;
  float ndotxClamped = max(ndotx, 1e-4);
  float tan2 = (1.0 - ndotxClamped * ndotxClamped) / (ndotxClamped * ndotxClamped + 1e-7);
  return 2.0 / (1.0 + sqrt(1.0 + a2 * tan2));
}

// Smithの相互マスキング項（G項）
float ct_G_Smith(float ndotl, float ndotv, float alpha) {
  return ct_G1_GGX(ndotl, alpha) * ct_G1_GGX(ndotv, alpha);
}

// シュリック近似によるフレネル（F項）
vec3 ct_FresnelSchlick(float vdotH, vec3 F0) {
  return F0 + (1.0 - F0) * pow(1.0 - vdotH, 5.0);
}

// Heitz 2018 に基づくGGX VNDFサンプル（視線依存の半ベクトル）
vec3 ct_SampleGGXVNDF(vec3 N, vec3 V, float alpha, vec2 u) {
  vec3 T = normalize(abs(N.z) < 0.999 ? cross(N, vec3(0.0, 0.0, 1.0)) : cross(N, vec3(0.0, 1.0, 0.0)));
  vec3 B = cross(N, T);

  vec3 Vh = normalize(vec3(dot(V, T), dot(V, B), dot(V, N)));
  vec3 VhStretched = normalize(vec3(alpha * Vh.x, alpha * Vh.y, Vh.z));

  float r = sqrt(u.x);
  float phi = 2.0 * PI * u.y;
  float t1 = r * cos(phi);
  float t2 = r * sin(phi);
  float s = 0.5 * (1.0 + VhStretched.z);
  t2 = mix(sqrt(max(0.0, 1.0 - t1 * t1)), t2, s);

  vec3 Hs = normalize(vec3(t1, t2, sqrt(max(0.0, 1.0 - t1 * t1 - t2 * t2))));
  vec3 H = normalize(vec3(alpha * Hs.x, alpha * Hs.y, max(1e-7, Hs.z)));
  return normalize(T * H.x + B * H.y + N * H.z);
}

// 可視法線分布を用いたGGXのPDF（ハーフベクトル経由）
float ct_PdfGGXVisibleNormal(vec3 N, vec3 V, vec3 H, float alpha) {
  float ndoth = max(dot(N, H), 0.0);
  float vdotH = max(dot(V, H), 0.0);
  float ndotv = max(dot(N, V), 0.0);
  float G1v = ct_G1_GGX(ndotv, alpha);
  float D = ct_D_GGX(ndoth, alpha);
  return (D * ndoth * G1v) / max(4.0 * vdotH, 1e-7);
}

// F0（入射0度の反射率）を基底色とメタリック値から算出する
vec3 ct_ComputeF0(vec3 baseColor, float metallic, float ior) {
  float f0Dielectric = pow((ior - 1.0) / (ior + 1.0), 2.0);
  vec3 dielectric = vec3(f0Dielectric);
  return mix(dielectric, baseColor, clamp(metallic, 0.0, 1.0));
}

// Cook-Torrance BRDFを評価し、拡散+鏡面の合計を返す
vec3 ct_EvalCookTorrance(vec3 baseColor, float metallic, vec3 F0, float alpha, vec3 N, vec3 V, vec3 L) {
  float ndotl = max(dot(N, L), 0.0);
  float ndotv = max(dot(N, V), 0.0);
  if (ndotl <= 0.0 || ndotv <= 0.0) {
    return vec3(0.0);
  }

  vec3 H = normalize(V + L);
  float ndoth = max(dot(N, H), 0.0);
  float vdotH = max(dot(V, H), 0.0);
  vec3 F = ct_FresnelSchlick(vdotH, F0);
  float D = ct_D_GGX(ndoth, alpha);
  float G = ct_G_Smith(ndotl, ndotv, alpha);
  vec3 spec = (D * G * F) / max(4.0 * ndotl * ndotv, 1e-7);

  vec3 kd = (1.0 - F) * (1.0 - metallic);
  vec3 diff = kd * baseColor / PI;
  return diff + spec;
}

// Cook-Torrance BRDFに基づいて方向サンプルと重みを算出する
CookTorranceSample sampleCookTorranceBRDF(Material mat, vec3 N, vec3 V, inout uint seed) {
  CookTorranceSample s;
  s.direction = N;
  s.weight = vec3(0.0);
  s.pdf = 0.0;

  vec3 baseColor = max(mat.albedo, vec3(0.0));
  float metallic = clamp(mat.metalness, 0.0, 1.0); // メタリックは専用フィールドから取得
  float ior = max(mat.ior, 1.0);                   // IOR も専用フィールドを使用
  float perceptualRoughness = clamp(mat.roughness, 0.001, 1.0);
  float alpha = max(0.001, perceptualRoughness * perceptualRoughness);
  vec3 F0 = ct_ComputeF0(baseColor, metallic, ior);

  // 拡散と鏡面の混合比。メタリックと粗さから経験的に調整。
  float specWeight = clamp(mix(0.1, 0.9, metallic) * mix(0.7, 1.0, 1.0 - perceptualRoughness), 0.05, 0.95);

  float choice = rand(seed);
  if (choice < specWeight) {
    // 鏡面サンプル：可視法線から半ベクトルを生成し、反射方向へ変換
    vec2 xi = rand2(seed);
    vec3 H = ct_SampleGGXVNDF(N, V, alpha, xi);
    vec3 L = reflect(-V, H);
    float ndotl = max(dot(N, L), 0.0);
    if (ndotl <= 0.0) {
      return s;
    }
    float pdfH = ct_PdfGGXVisibleNormal(N, V, H, alpha);
    float vdotH = max(dot(V, H), 0.0);
    float pdfSpec = pdfH / max(4.0 * vdotH, 1e-7);
    float pdfDiff = ct_CosineHemispherePDF(ndotl);
    float pdf = specWeight * pdfSpec + (1.0 - specWeight) * pdfDiff;

    vec3 f = ct_EvalCookTorrance(baseColor, metallic, F0, alpha, N, V, L);
    s.direction = normalize(L);
    s.pdf = pdf;
    s.weight = f * (ndotl / max(pdf, 1e-7));
    return s;
  } else {
    // 拡散サンプル：既存のコサイン加重ヘミスフィアを利用
    vec2 xi = rand2(seed);
    vec3 L = cosineSampleHemisphere(xi, N);
    float ndotl = max(dot(N, L), 0.0);
    if (ndotl <= 0.0) {
      return s;
    }

    vec3 f = ct_EvalCookTorrance(baseColor, metallic, F0, alpha, N, V, L);
    vec3 H = normalize(V + L);
    float pdfSpec = 0.0;
    if (length(H) > 1e-5) {
      float pdfH = ct_PdfGGXVisibleNormal(N, V, H, alpha);
      float vdotH = max(dot(V, H), 0.0);
      pdfSpec = pdfH / max(4.0 * vdotH, 1e-7);
    }
    float pdfDiff = ct_CosineHemispherePDF(ndotl);
    float pdf = specWeight * pdfSpec + (1.0 - specWeight) * pdfDiff;

    s.direction = normalize(L);
    s.pdf = pdf;
    s.weight = f * (ndotl / max(pdf, 1e-7));
    return s;
  }
}

bool updateRay(
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
          return false;
        }
        throughput *= 1.0 / p;
      }
    } 
    //TRANSPARENT
    // ガラスなどの透明材質。専用フィールドから屈折率(ior)を取得する。
    if (hit.material.type == MATERIAL_TRANSPARENT) {
      // 1.0 未満の場合は空気より密度が低くなるので 1.0 で打ち止め。
      float ior = max(hit.material.ior, 1.0);
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
    //BRDF
    if (hit.material.type == MATERIAL_BRDF) {
      // Cook-Torrance BRDFで定義したPBRマテリアル。metalness と ior フィールドを使用。
      vec3 viewDir = normalize(-ray.direction);
      CookTorranceSample ctSample = sampleCookTorranceBRDF(hit.material, hit.normal, viewDir, seed);
      if (ctSample.pdf <= 0.0) {
        throughput = vec3(0.0);
        return false;
      }
      newDir = ctSample.direction;
      throughput *= ctSample.weight;

      // ロシアンルーレット: 基底色とF0のエネルギーを基準に継続確率を決定
      if (bounce > 2) {
        float metallic = clamp(hit.material.metalness, 0.0, 1.0);
        float ior = max(hit.material.ior, 1.0);
        vec3 F0 = ct_ComputeF0(hit.material.albedo, metallic, ior);
        float baseEnergy = max(hit.material.albedo.r, max(hit.material.albedo.g, hit.material.albedo.b));
        float specEnergy = max(F0.r, max(F0.g, F0.b));
        float p = clamp(max(baseEnergy, specEnergy), 0.2, 0.95);
        float rr = rand(seed);
        if (rr > p) {
          throughput = vec3(0.0);
          return false;
        }
        throughput *= 1.0 / p;
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
          return false;
        }
        throughput *= 1.0 / p;
      }
    }
    //新しい反射方向を返す
    ray.direction  =  newDir ;
    return true ;
}
