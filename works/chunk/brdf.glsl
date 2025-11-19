// ========== 共通ユーティリティ ==========
const float PI = 3.14159265359;

float saturate(float x){ return clamp(x, 0.0, 1.0); }
vec3  saturate(vec3  x){ return clamp(x, 0.0, 1.0); }

// 乱数（適当に差し替え可）
uint seed;
uint xorshift(){ seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return seed; }
float rand(){ return float(xorshift()) * (1.0/4294967296.0); }

// ========== Cosine-weighted Diffuse サンプル ==========
vec3 cosineHemisphereSample(vec2 u){
    float phi = 2.0*PI*u.x;
    float r   = sqrt(u.y);
    float x = r * cos(phi);
    float y = r * sin(phi);
    float z = sqrt(max(0.0, 1.0 - x*x - y*y));
    return vec3(x,y,z); // +Z半球
}
float cosineHemispherePDF(float NdotL){
    return NdotL / PI;
}

// ========== GGX / Cook-Torrance ==========
float D_GGX(float NdotH, float a){
    float a2 = a*a;
    float d = (NdotH*NdotH)*(a2 - 1.0) + 1.0;
    return a2 / (PI * d*d + 1e-7);
}
float G1_Smith_GGX(float NdotX, float a){
    float a2 = a*a;
    float tan2 = (1.0 - NdotX*NdotX) / (NdotX*NdotX + 1e-7);
    return 2.0 / (1.0 + sqrt(1.0 + a2 * tan2));
}
float G_Smith(float NdotL, float NdotV, float a){
    return G1_Smith_GGX(NdotL, a) * G1_Smith_GGX(NdotV, a);
}
vec3 Fresnel_Schlick(float VdotH, vec3 F0){
    return F0 + (1.0 - F0)*pow(1.0 - VdotH, 5.0);
}

// ========== GGX VNDF サンプリング（Heitz 2018 簡易実装） ==========
vec3 sampleGGX_VNDF(vec3 N, vec3 V, float a, vec2 u){
    // TBN
    vec3 T = normalize(abs(N.z) < 0.999 ? cross(N, vec3(0,0,1)) : cross(N, vec3(0,1,0)));
    vec3 B = cross(N, T);

    // viewをローカルへ（Nを(0,0,1)に合わせる）
    vec3 Vh = normalize(vec3(dot(V,T), dot(V,B), dot(V,N)));

    // stretch
    vec3 Vh_s = normalize(vec3(a*Vh.x, a*Vh.y, Vh.z));

    // サンプル半ベクトル
    float r = sqrt(u.x);
    float phi = 2.0*PI*u.y;
    float t1 = r * cos(phi);
    float t2 = r * sin(phi);
    float s = 0.5 * (1.0 + Vh_s.z);
    t2 = mix(sqrt(1.0 - t1*t1), t2, s);

    vec3 Hs = normalize(vec3(t1, t2, sqrt(max(0.0, 1.0 - t1*t1 - t2*t2))));

    // unstretch
    vec3 H = normalize(vec3(a*Hs.x, a*Hs.y, max(1e-7, Hs.z)));

    // 戻し
    vec3 Hw = normalize(T*H.x + B*H.y + N*H.z);
    return Hw;
}

// GGXのpdf（ハーフベクトル法）
float pdf_GGX_VisibleNormal(vec3 N, vec3 V, vec3 H, float a){
    // Smith masking付き可視分布の簡易pdf: D*G1(V)*NdotH / (4*VdotH)
    float NdotH = saturate(dot(N,H));
    float VdotH = saturate(dot(V,H));
    float NdotV = saturate(dot(N,V));
    float G1v = G1_Smith_GGX(NdotV, a);
    float D = D_GGX(NdotH, a);
    return (D * NdotH * G1v) / (4.0 * max(1e-7, VdotH));
}

// ========== マテリアル ==========
struct Material {
    vec3  baseColor;  // アルベド
    float metallic;   // 0..1
    float roughness;  // 0..1 (perceptual)
    float ior;        // 屈折率（F0計算用、金属は無視してF0=baseColor推奨）
};

// F0を決定（プラ：0.04基準、金属：baseColor）
vec3 computeF0(Material m){
    float f0_dielectric = pow((m.ior - 1.0)/(m.ior + 1.0), 2.0); // ~0.04@ior=1.5
    vec3  F0 = mix(vec3(f0_dielectric), m.baseColor, m.metallic);
    return F0;
}

// Cook-Torrance BRDF評価（拡散+鏡面）
vec3 evalBRDF(Material m, vec3 N, vec3 V, vec3 L){
    float NdotL = saturate(dot(N,L));
    float NdotV = saturate(dot(N,V));
    if(NdotL<=0.0 || NdotV<=0.0) return vec3(0);

    float a = max(0.001, m.roughness*m.roughness); // GGXのalpha
    vec3  H = normalize(V+L);
    float NdotH = saturate(dot(N,H));
    float VdotH = saturate(dot(V,H));

    vec3 F0 = computeF0(m);
    vec3  F = Fresnel_Schlick(VdotH, F0);
    float D = D_GGX(NdotH, a);
    float G = G_Smith(NdotL, NdotV, a);

    vec3  spec = (D*G*F) / max(1e-7, 4.0*NdotL*NdotV);

    // 金属は拡散ほぼゼロ。非金属はLambert
    vec3  kd = (1.0 - F) * (1.0 - m.metallic);
    vec3  diff = kd * m.baseColor / PI;

    return diff + spec;
}

// ========== サンプリング（拡散とGGXのミックス） ==========
// 戻り値：新方向dir、pdf、f（BRDF値）、weight（f*cos/pdf）
struct SampleResult { vec3 dir; float pdf; vec3 f; vec3 weight; };

SampleResult sampleBRDF(Material m, vec3 N, vec3 V){
    SampleResult s;
    float a = max(0.001, m.roughness*m.roughness);
    vec3 F0 = computeF0(m);
    float specBias = clamp(mix(0.1, 0.9, m.metallic) * mix(0.7, 1.0, 1.0 - m.roughness), 0.05, 0.95);
    float pSpec = specBias; // ミックス確率（経験則）

    float u = rand();
    if(u < pSpec){
        // GGX（可視法線）サンプル
        vec3 H = sampleGGX_VNDF(N, V, a, vec2(rand(), rand()));
        vec3 L = reflect(-V, H);
        if(dot(N,L) <= 0.0){ // 裏に飛んだら捨てて再サンプルしても良い
            s.dir = L; s.pdf = 0.0; s.f = vec3(0); s.weight = vec3(0); return s;
        }
        float pdf_h = pdf_GGX_VisibleNormal(N, V, H, a);
        float VdotH = saturate(dot(V,H));
        float NdotL = saturate(dot(N,L));
        float pdf_l = pdf_h / max(2.0*VdotH, 1e-7); // ハーフ→ライト方向への変換

        vec3 f = evalBRDF(m, N, V, L);
        float pdf = mix(0.0, pdf_l, 1.0) * pSpec + cosineHemispherePDF(NdotL) * (1.0 - pSpec); // 混合pdf
        s.dir = L;
        s.pdf = max(pdf, 1e-7);
        s.f = f;
        s.weight = f * (NdotL / s.pdf);
        return s;
    }else{
        // 拡散コサイン重み
        vec3 T = normalize(abs(N.z) < 0.999 ? cross(N, vec3(0,0,1)) : cross(N, vec3(0,1,0)));
        vec3 B = cross(N, T);
        vec3 Llocal = cosineHemisphereSample(vec2(rand(), rand()));
        vec3 L = normalize(T*Llocal.x + B*Llocal.y + N*Llocal.z);

        float NdotL = saturate(dot(N,L));
        vec3 f = evalBRDF(m, N, V, L);

        float pdf_diff = cosineHemispherePDF(NdotL);
        // 混合pdf
        // spec側pdfは厳密にはH経由で要再計算だが、ここでは0として混合（実装簡略）
        float pdf = pSpec * 0.0 + (1.0 - pSpec) * pdf_diff;

        s.dir = L;
        s.pdf = max(pdf, 1e-7);
        s.f = f;
        s.weight = f * (NdotL / s.pdf);
        return s;
    }
}

// 交差でN, pos, matが出たとする
vec3 V = normalize(-rayDir);
SampleResult smp = sampleBRDF(mat, N, V);

if(smp.pdf > 0.0){
    throughput *= smp.weight;   // f * cos / pdf を掛ける
    rayOrigin = pos + smp.dir * 1e-3;
    rayDir    = smp.dir;
}else{
    // ヒット無効（吸収扱い）
    alive = false;
}
