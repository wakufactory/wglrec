// path tracing material 


fn Mat_none() -> Material {
  return defaultMaterial();
}

fn Mat_lambert(color : vec3<f32>) -> Material {
  return Material(
    false,
    color,
    vec3<f32>(0.0),
    vec3<f32>(0.0),
    0.0,
    0.0,
    1.0,
    MATERIAL_LAMBERT
  );
}

fn Mat_brdf(color : vec3<f32>, roughness : f32, metalness : f32, ior : f32) -> Material {
  return Material(
    false,
    color,
    vec3<f32>(0.0),
    vec3<f32>(0.0),
    roughness,
    metalness,
    ior,
    MATERIAL_BRDF
  );
}

fn Mat_mirror(color : vec3<f32>) -> Material {
  return Material(
    false,
    color,
    vec3<f32>(0.0),
    vec3<f32>(0.0),
    0.0,
    0.0,
    1.0,
    MATERIAL_MIRROR
  );
}

fn Mat_trans(color : vec3<f32>, refColor : vec3<f32>, ior : f32) -> Material {
  return Material(
    false,
    color,
    vec3<f32>(0.0),
    refColor,
    0.0,
    0.0,
    ior,
    MATERIAL_TRANSPARENT
  );
}

fn Mat_light(color : vec3<f32>) -> Material {
  return Material(
    true,
    vec3<f32>(0.0),
    color,
    vec3<f32>(0.0),
    0.0,
    0.0,
    1.0,
    MATERIAL_LIGHT
  );
}

fn cosineSampleHemisphere(xi : vec2<f32>, normal : vec3<f32>) -> vec3<f32> {
  let phi = 2.0 * PI * xi.x;
  let cosTheta = sqrt(1.0 - xi.y);
  let sinTheta = sqrt(xi.y);
  let basis = buildOrthonormalBasis(normal);
  let localDir = vec3<f32>(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
  return normalize(
    localDir.x * basis.tangent +
    localDir.y * basis.bitangent +
    localDir.z * normal
  );
}

fn samplePhongLobe(reflectDir : vec3<f32>, exponent : f32, xi : vec2<f32>) -> vec3<f32> {
  let cosTheta = pow(xi.x, 1.0 / (exponent + 1.0));
  let sinTheta = sqrt(max(0.0, 1.0 - cosTheta * cosTheta));
  let phi = 2.0 * PI * xi.y;
  let basis = buildOrthonormalBasis(reflectDir);
  let localDir = vec3<f32>(
    sinTheta * cos(phi),
    sinTheta * sin(phi),
    cosTheta
  );
  return normalize(
    localDir.x * basis.tangent +
    localDir.y * basis.bitangent +
    localDir.z * reflectDir
  );
}

fn ct_CosineHemispherePDF(ndotl : f32) -> f32 {
  return max(ndotl, 0.0) / PI;
}

fn ct_D_GGX(ndoth : f32, alpha : f32) -> f32 {
  let a2 = alpha * alpha;
  let denom = (ndoth * ndoth) * (a2 - 1.0) + 1.0;
  return a2 / max(PI * denom * denom, 1e-7);
}

fn ct_G1_GGX(ndotx : f32, alpha : f32) -> f32 {
  let a2 = alpha * alpha;
  let ndotxClamped = max(ndotx, 1e-4);
  let tan2 = (1.0 - ndotxClamped * ndotxClamped) / (ndotxClamped * ndotxClamped + 1e-7);
  return 2.0 / (1.0 + sqrt(1.0 + a2 * tan2));
}

fn ct_G_Smith(ndotl : f32, ndotv : f32, alpha : f32) -> f32 {
  return ct_G1_GGX(ndotl, alpha) * ct_G1_GGX(ndotv, alpha);
}

fn ct_FresnelSchlick(vdotH : f32, F0 : vec3<f32>) -> vec3<f32> {
  return F0 + (vec3<f32>(1.0) - F0) * pow(1.0 - vdotH, 5.0);
}

fn ct_SampleGGXVNDF(N : vec3<f32>, V : vec3<f32>, alpha : f32, u : vec2<f32>) -> vec3<f32> {
  var T = vec3<f32>(0.0);
  if (abs(N.z) < 0.999) {
    T = normalize(cross(N, vec3<f32>(0.0, 0.0, 1.0)));
  } else {
    T = normalize(cross(N, vec3<f32>(0.0, 1.0, 0.0)));
  }
  let B = cross(N, T);

  let Vh = normalize(vec3<f32>(dot(V, T), dot(V, B), dot(V, N)));
  let VhStretched = normalize(vec3<f32>(alpha * Vh.x, alpha * Vh.y, Vh.z));

  let r = sqrt(u.x);
  let phi = 2.0 * PI * u.y;
  let t1 = r * cos(phi);
  var t2 = r * sin(phi);
  let s = 0.5 * (1.0 + VhStretched.z);
  t2 = mix(sqrt(max(0.0, 1.0 - t1 * t1)), t2, s);

  let Hs = normalize(vec3<f32>(t1, t2, sqrt(max(0.0, 1.0 - t1 * t1 - t2 * t2))));
  let H = normalize(vec3<f32>(alpha * Hs.x, alpha * Hs.y, max(1e-7, Hs.z)));
  return normalize(T * H.x + B * H.y + N * H.z);
}

fn ct_PdfGGXVisibleNormal(N : vec3<f32>, V : vec3<f32>, H : vec3<f32>, alpha : f32) -> f32 {
  let ndoth = max(dot(N, H), 0.0);
  let vdotH = max(dot(V, H), 0.0);
  let ndotv = max(dot(N, V), 0.0);
  let G1v = ct_G1_GGX(ndotv, alpha);
  let D = ct_D_GGX(ndoth, alpha);
  return (D * ndoth * G1v) / max(4.0 * vdotH, 1e-7);
}

fn ct_ComputeF0(baseColor : vec3<f32>, metallic : f32, ior : f32) -> vec3<f32> {
  let f0Dielectric = pow((ior - 1.0) / (ior + 1.0), 2.0);
  let dielectric = vec3<f32>(f0Dielectric);
  return mix(dielectric, baseColor, clamp(metallic, 0.0, 1.0));
}


struct CookTorranceSample {
  direction : vec3<f32>,
  weight : vec3<f32>,
  pdf : f32,
};



fn ct_EvalCookTorrance(
  baseColor : vec3<f32>,
  metallic : f32,
  F0 : vec3<f32>,
  alpha : f32,
  N : vec3<f32>,
  V : vec3<f32>,
  L : vec3<f32>
) -> vec3<f32> {
  let ndotl = max(dot(N, L), 0.0);
  let ndotv = max(dot(N, V), 0.0);
  if ((ndotl <= 0.0) || (ndotv <= 0.0)) {
    return vec3<f32>(0.0);
  }

  let H = normalize(V + L);
  let ndoth = max(dot(N, H), 0.0);
  let vdotH = max(dot(V, H), 0.0);
  let F = ct_FresnelSchlick(vdotH, F0);
  let D = ct_D_GGX(ndoth, alpha);
  let G = ct_G_Smith(ndotl, ndotv, alpha);
  let spec = (D * G) * F / max(4.0 * ndotl * ndotv, 1e-7);

  let kd = (vec3<f32>(1.0) - F) * (1.0 - metallic);
  let diff = kd * baseColor / PI;
  return diff + spec;
}

fn sampleCookTorranceBRDF(mat : Material, N : vec3<f32>, V : vec3<f32>, seed : ptr<function, u32>) -> CookTorranceSample {
  var result = CookTorranceSample(vec3<f32>(0.0), vec3<f32>(0.0), 0.0);

  let baseColor = max(mat.albedo, vec3<f32>(0.0));
  let metallic = clamp(mat.metalness, 0.0, 1.0);
  let ior = max(mat.ior, 1.0);
  let perceptualRoughness = clamp(mat.roughness, 0.001, 1.0);
  let alpha = max(0.001, perceptualRoughness * perceptualRoughness);
  let F0 = ct_ComputeF0(baseColor, metallic, ior);

  let specWeight = clamp(mix(0.1, 0.9, metallic) * mix(0.7, 1.0, 1.0 - perceptualRoughness), 0.05, 0.95);

  let choice = rand(seed);
  if (choice < specWeight) {
    let xi = rand2(seed);
    let H = ct_SampleGGXVNDF(N, V, alpha, xi);
    let L = reflect(-V, H);
    let ndotl = max(dot(N, L), 0.0);
    if (ndotl <= 0.0) {
      return result;
    }
    let pdfH = ct_PdfGGXVisibleNormal(N, V, H, alpha);
    let vdotH = max(dot(V, H), 0.0);
    let pdfSpec = pdfH / max(4.0 * vdotH, 1e-7);
    let pdfDiff = ct_CosineHemispherePDF(ndotl);
    let pdf = specWeight * pdfSpec + (1.0 - specWeight) * pdfDiff;

    let f = ct_EvalCookTorrance(baseColor, metallic, F0, alpha, N, V, L);
    result.direction = normalize(L);
    result.pdf = pdf;
    result.weight = f * (ndotl / max(pdf, 1e-7));
    return result;
  }

  let xi = rand2(seed);
  let L = cosineSampleHemisphere(xi, N);
  let ndotl = max(dot(N, L), 0.0);
  if (ndotl <= 0.0) {
    return result;
  }

  let f = ct_EvalCookTorrance(baseColor, metallic, F0, alpha, N, V, L);
  let H = normalize(V + L);
  var pdfSpec = 0.0;
  if (length(H) > 1e-5) {
    let pdfH = ct_PdfGGXVisibleNormal(N, V, H, alpha);
    let vdotH = max(dot(V, H), 0.0);
    pdfSpec = pdfH / max(4.0 * vdotH, 1e-7);
  }
  let pdfDiff = ct_CosineHemispherePDF(ndotl);
  let pdf = specWeight * pdfSpec + (1.0 - specWeight) * pdfDiff;

  result.direction = normalize(L);
  result.pdf = pdf;
  result.weight = f * (ndotl / max(pdf, 1e-7));
  return result;
}

// calc Ray reflection
fn updateRay(
  bounce : i32,
  hit : HitInfo,
  ray : ptr<function, Ray>,
  throughput : ptr<function, vec3<f32>>,
  seed : ptr<function, u32>
) -> bool {
  var newDir = (*ray).direction;

  if (hit.material.kind == MATERIAL_MIRROR) {
    newDir = reflect((*ray).direction, hit.normal);
    (*throughput) = (*throughput) * hit.material.albedo;
    (*ray).kind = HIDDEN_LIGHT;
  }

  if (hit.material.kind == MATERIAL_GLOSSY) {
    let specIntensity = max(hit.material.specular.x, max(hit.material.specular.y, hit.material.specular.z));
    let diffIntensity = max(hit.material.albedo.x, max(hit.material.albedo.y, hit.material.albedo.z));
    let totalIntensity = specIntensity + diffIntensity;
    var specProb = 0.0;
    if (totalIntensity > 0.0) {
      specProb = specIntensity / totalIntensity;
    }
    specProb = min(specProb, 0.95);

    let choice = rand(seed);
    if ((choice < specProb) && (specIntensity > 0.0)) {
      let xiSpec = rand2(seed);
      let gloss = clamp(1.0 - hit.material.roughness, 0.0, 0.999);
      let exponent = mix(5.0, 200.0, gloss * gloss);
      let reflectDir = reflect((*ray).direction, hit.normal);
      newDir = samplePhongLobe(reflectDir, exponent, xiSpec);
      if (dot(newDir, hit.normal) <= 0.0) {
        newDir = reflectDir;
      }
      (*throughput) = (*throughput) * (hit.material.specular / max(specProb, 0.001));
      (*ray).kind = 0;
    } else {
      let xiDiff = rand2(seed);
      newDir = cosineSampleHemisphere(xiDiff, hit.normal);
      let diffuseProb = max(1.0 - specProb, 0.001);
      (*throughput) = (*throughput) * (hit.material.albedo / diffuseProb);
    }

    var p = max(
      max(hit.material.albedo.x, max(hit.material.albedo.y, hit.material.albedo.z)),
      max(hit.material.specular.x, max(hit.material.specular.y, hit.material.specular.z))
    );
    p = clamp(p, 0.1, 0.95);
    if (bounce > 2) {
      let rr = rand(seed);
      if (rr > p) {
        return false;
      }
      (*throughput) = (*throughput) * (1.0 / p);
    }
  }

  if (hit.material.kind == MATERIAL_TRANSPARENT) {
    let ior = max(hit.material.ior, 1.0);
    let incident = normalize((*ray).direction);
    var surfaceNormal = hit.normal;
    let entering = dot(incident, surfaceNormal) < 0.0;
    var etaI = 1.0;
    var etaT = ior;
    var n = surfaceNormal;
    if (!entering) {
      n = -surfaceNormal;
      let tmp = etaI;
      etaI = etaT;
      etaT = tmp;
    }

    let eta = etaI / etaT;
    let cosIncident = clamp(dot(-incident, n), 0.0, 1.0);
    let sinT2 = eta * eta * (1.0 - cosIncident * cosIncident);
    let reflectDir = reflect(incident, n);

    let r0 = pow((etaT - etaI) / (etaT + etaI), 2.0);
    var fresnel = r0 + (1.0 - r0) * pow(1.0 - cosIncident, 5.0);
    var reflectProb = fresnel;
    var reflectColor = hit.material.specular;
    var refractDir = vec3<f32>(0.0);
    if (sinT2 <= 1.0) {
      refractDir = normalize(refract(incident, n, eta));
    } else {
      reflectProb = 1.0;
      reflectColor = max(reflectColor, hit.material.albedo);
    }

    let transmitColor = hit.material.albedo;
    let reflectStrength = max(reflectColor.x, max(reflectColor.y, reflectColor.z));
    if (sinT2 <= 1.0) {
      reflectProb = reflectProb * clamp(reflectStrength, 0.0, 1.0);
    }

    let choice = rand(seed);
    if (choice < reflectProb) {
      newDir = reflectDir;
      (*throughput) = (*throughput) * (reflectColor / max(reflectProb, 0.001));
      var offsetSign = -1.0;
      if (entering) {
        offsetSign = 1.0;
      }
      (*ray).origin = hit.position + surfaceNormal * offsetSign * 0.001;
    } else {
      newDir = refractDir;
      let transmitProb = max(1.0 - reflectProb, 0.001);
      let etaScale = eta * eta;
      (*throughput) = (*throughput) * (transmitColor * etaScale / transmitProb);
      var offsetSign = 1.0;
      if (entering) {
        offsetSign = -1.0;
      }
      (*ray).origin = hit.position + surfaceNormal * offsetSign * 0.001;
    }

    (*ray).kind = 0;
  }

  if (hit.material.kind == MATERIAL_BRDF) {
    let viewDir = normalize(-(*ray).direction);
    let sample = sampleCookTorranceBRDF(hit.material, hit.normal, viewDir, seed);
    if (sample.pdf <= 0.0) {
      (*throughput) = vec3<f32>(0.0);
      return false;
    }
    newDir = sample.direction;
    (*throughput) = (*throughput) * sample.weight;

    if (bounce > 2) {
      let metallic = clamp(hit.material.metalness, 0.0, 1.0);
      let ior = max(hit.material.ior, 1.0);
      let F0 = ct_ComputeF0(hit.material.albedo, metallic, ior);
      let baseEnergy = max(hit.material.albedo.x, max(hit.material.albedo.y, hit.material.albedo.z));
      let specEnergy = max(F0.x, max(F0.y, F0.z));
      let p = clamp(max(baseEnergy, specEnergy), 0.2, 0.95);
      let rr = rand(seed);
      if (rr > p) {
        (*throughput) = vec3<f32>(0.0);
        return false;
      }
      (*throughput) = (*throughput) * (1.0 / p);
    }

    (*ray).kind = 0;
  }

  if (hit.material.kind == MATERIAL_LAMBERT) {
    let xi = rand2(seed);
    newDir = cosineSampleHemisphere(xi, hit.normal);
    (*throughput) = (*throughput) * hit.material.albedo;
    let p = max(hit.material.albedo.x, max(hit.material.albedo.y, hit.material.albedo.z));
    if (bounce > 2) {
      let rr = rand(seed);
      if (rr > p) {
        return false;
      }
      (*throughput) = (*throughput) * (1.0 / p);
    }
  }

  (*ray).direction = newDir;
  return true;
}
