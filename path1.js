// shader-path.js
// Full-screen path tracing sample using Three.js with a fragment shader.
import * as THREE from 'https://cdn.jsdelivr.net/npm/three@0.180.0/build/three.module.js';

//scene shader 
const fragmentShaderEnvironment = /* glsl */`
        precision highp float;
        precision highp int;

        varying vec2 vUv;
        uniform float uTime;
        uniform vec2 uResolution;

        // シーン全体で共有する定数群
        const float PI = 3.141592653589793;
        const int MATERIAL_NONE = -1;
        const int MATERIAL_LAMBERT = 0;
        const int MATERIAL_MIRROR = 1;
        const int MATERIAL_LIGHT = 2;
        const int MATERIAL_GLOSSY = 3;
        const int MAX_BOUNCES = 6;
        const int SPP = 20; // samples per pixel

         // レイと交差情報を保持する構造体
        struct Ray {
          vec3 origin;
          vec3 direction;
        };

        vec3 environment(Ray ray) {
          // 簡易なグラデーション環境光
          float t = 0.5 * (ray.direction.y + 1.0);
          vec3 top = vec3(0.5, 0.80, 1.25);
          vec3 bottom = vec3(0.05, 0.07, 0.10);
          return mix(bottom, top, clamp(t, 0.0, 1.0));
        }
  `;
  const fragmentShaderScene = /* glsl */`
        void intersectScene(Ray ray, inout HitInfo hit) {
          // シーン内のオブジェクトとの交差をすべてチェック
          hit.material = MATERIAL_NONE;
          hit.t = 1e20;
          hit.specular = vec3(0.1,0.1,0.1);
          hit.roughness = 0.5;

          tryGround(ray, hit);

          float lightPulse = 2.65 + 0.35 * sin(uTime * 0.4);
          vec3 lightEmission = vec3(14.0, 12.0, 9.0) * lightPulse;

          float time = uTime;
          vec3 centerA = vec3(sin(time * 0.6) * 2., 0.15 + 2.* cos(time * 0.4), -1.5);
          vec3 centerB = vec3(-1.4 + 0.5 * sin(time * 0.8), -0.2, -0.2 + 1. * cos(time * 0.5));
          vec3 centerC = vec3(1.5 + 0.3 * sin(time * 0.7), 0.2 + 0.25 * sin(time * 0.9 + 1.0), -0.5);

          trySphere(ray, centerA, 1.0, vec3(0.85, 0.3, 0.2), vec3(0.0), vec3(0.0), 1.0, MATERIAL_LAMBERT, hit);
          trySphere(ray, centerB, 0.8, vec3(0.15, 0.16, 0.5), vec3(0.0), vec3(0.95), 0.02, MATERIAL_MIRROR, hit);
          trySphere(ray, centerC, 0.6, vec3(0.55, 0.6, 0.2), vec3(0.0), vec3(0.5, 0.5, 0.5), 0.7, MATERIAL_GLOSSY, hit);
          vec3 boxMin = vec3(-0.6, -0.45, -0.4);
          vec3 boxMax = vec3(0.6, 0.45, 0.4);
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
          mat4 boxTransform = translation * rotation;
          tryBoxTransformed(ray, boxMin, boxMax, boxTransform, vec3(0.25, 0.8, 0.3), vec3(0.0), vec3(0.0), 1.0, MATERIAL_LAMBERT, hit);
          trySphere(ray, vec3(0.0, 3.5, 0.0), 0.1, vec3(0.0), lightEmission, vec3(0.0), 1.0, MATERIAL_LIGHT, hit);
        }
  `;


export async function createSceneController({ canvas, width, height, log }) {
  const gl = canvas.getContext('webgl2', {
    antialias: false,
    preserveDrawingBuffer: true,
    alpha: false
  });
  if (!gl) {
    throw new Error('WebGL2 context not available');
  }

  const renderer = new THREE.WebGLRenderer({
    canvas,
    context: gl,
    antialias: false,
    preserveDrawingBuffer: true,
    alpha: false
  });
  renderer.setSize(width, height, false);
  renderer.setPixelRatio(1);
  renderer.autoClear = true;

  const scene = new THREE.Scene();
  const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);

  const uniforms = {
    uTime: { value: 0 },
    uResolution: { value: new THREE.Vector2(width, height) }
  };

    const fragmentShaderCommon = /* glsl */`

        struct HitInfo {
          float t;
          vec3 position;
          vec3 normal;
          vec3 albedo;
          vec3 emission;
          vec3 specular;
          float roughness;
          int material;
        };       
        uint hashUint(uint x) {
          x ^= x >> 16;
          x *= 0x7feb352du;
          x ^= x >> 15;
          x *= 0x846ca68bu;
          x ^= x >> 16;
          return x;
        }

        float rand(inout uint state) {
          state = hashUint(state);
          return float(state) / 4294967296.0;
        }

        vec2 rand2(inout uint state) {
          return vec2(rand(state), rand(state));
        }

        void orthonormalBasis(vec3 n, out vec3 tangent, out vec3 bitangent) {
          if (abs(n.z) > 0.999) {
            tangent = normalize(cross(vec3(0.0, 1.0, 0.0), n));
          } else {
            tangent = normalize(cross(vec3(0.0, 0.0, 1.0), n));
          }
          bitangent = cross(n, tangent);
        }
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

        void trySphere(
          Ray ray,
          vec3 center,
          float radius,
          vec3 albedo,
          vec3 emission,
          vec3 specular,
          float roughness,
          int material,
          inout HitInfo hit
        ) {
          // 球体との交差判定
          vec3 oc = ray.origin - center;
          float b = dot(oc, ray.direction);
          float c = dot(oc, oc) - radius * radius;
          float disc = b * b - c;
          if (disc < 0.0) return;
          float s = sqrt(disc);
          float t = -b - s;
          if (t < 0.001) {
            t = -b + s;
            if (t < 0.001) return;
          }
          if (t >= hit.t) return;
          vec3 pos = ray.origin + ray.direction * t;
          vec3 normal = normalize(pos - center);
          hit.t = t;
          hit.position = pos;
          hit.normal = normal;
          hit.albedo = albedo;
          hit.emission = emission;
          hit.specular = specular;
          hit.roughness = roughness;
          hit.material = material;
        }

        void tryBox(
          Ray ray,
          vec3 minBounds,
          vec3 maxBounds,
          vec3 albedo,
          vec3 emission,
          vec3 specular,
          float roughness,
          int material,
          inout HitInfo hit
        ) {
          // 軸平行境界ボックス（AABB）との交差判定
          vec3 invDir = 1.0 / ray.direction;
          vec3 t0 = (minBounds - ray.origin) * invDir;
          vec3 t1 = (maxBounds - ray.origin) * invDir;
          vec3 tMin = min(t0, t1);
          vec3 tMax = max(t0, t1);
          float tNear = max(max(tMin.x, tMin.y), tMin.z);
          float tFar = min(min(tMax.x, tMax.y), tMax.z);
          if (tFar < 0.001 || tNear > tFar || tNear >= hit.t) {
            return;
          }
          float tHit = max(tNear, 0.001);
          vec3 pos = ray.origin + ray.direction * tHit;
          vec3 normal = vec3(0.0);
          const float EPS = 0.001;
          if (abs(pos.x - minBounds.x) < EPS) normal = vec3(-1.0, 0.0, 0.0);
          else if (abs(pos.x - maxBounds.x) < EPS) normal = vec3(1.0, 0.0, 0.0);
          else if (abs(pos.y - minBounds.y) < EPS) normal = vec3(0.0, -1.0, 0.0);
          else if (abs(pos.y - maxBounds.y) < EPS) normal = vec3(0.0, 1.0, 0.0);
          else if (abs(pos.z - minBounds.z) < EPS) normal = vec3(0.0, 0.0, -1.0);
          else normal = vec3(0.0, 0.0, 1.0);
          hit.t = tHit;
          hit.position = pos;
          hit.normal = normal;
          hit.albedo = albedo;
          hit.emission = emission;
          hit.specular = specular;
          hit.roughness = roughness;
          hit.material = material;
        }

        void tryBoxTransformed(
          Ray ray,
          vec3 minBounds,
          vec3 maxBounds,
          mat4 transform,
          vec3 albedo,
          vec3 emission,
          vec3 specular,
          float roughness,
          int material,
          inout HitInfo hit
        ) {
          mat4 invTransform = inverse(transform);
          Ray localRay = Ray(
            (invTransform * vec4(ray.origin, 1.0)).xyz,
            (invTransform * vec4(ray.direction, 0.0)).xyz
          );

          HitInfo localHit;
          localHit.t = hit.t;
          localHit.position = vec3(0.0);
          localHit.normal = vec3(0.0);
          localHit.albedo = albedo;
          localHit.emission = emission;
          localHit.specular = specular;
          localHit.roughness = roughness;
          localHit.material = MATERIAL_NONE;

          tryBox(localRay, minBounds, maxBounds, albedo, emission, specular, roughness, material, localHit);
          if (localHit.material == MATERIAL_NONE) {
            return;
          }

          vec3 worldPos = (transform * vec4(localHit.position, 1.0)).xyz;
          float tWorld = dot(worldPos - ray.origin, ray.direction);
          if (tWorld < 0.001 || tWorld >= hit.t) {
            return;
          }

          vec3 worldNormal = normalize(mat3(transpose(invTransform)) * localHit.normal);
          if (dot(worldNormal, ray.direction) > 0.0) {
            worldNormal = -worldNormal;
          }

          hit.t = tWorld;
          hit.position = worldPos;
          hit.normal = worldNormal;
          hit.albedo = localHit.albedo;
          hit.emission = localHit.emission;
          hit.specular = localHit.specular;
          hit.roughness = localHit.roughness;
          hit.material = localHit.material;
        }

        void tryGround(Ray ray, inout HitInfo hit) {
          vec3 normal = vec3(0.0, 1.0, 0.0);
          float denom = dot(ray.direction, normal);
          if (abs(denom) < 0.001) return;
          float t = (-1.0 - ray.origin.y) / denom;
          if (t < 0.001 || t >= hit.t) return;
          vec3 pos = ray.origin + ray.direction * t;
          vec2 checkerCoords = pos.xz * 0.5;
          float checker = mod(floor(checkerCoords.x) + floor(checkerCoords.y), 2.0);
          vec3 colorA = vec3(0.85, 0.85, 0.85);
          vec3 colorB = vec3(0.23, 0.25, 0.28);
          vec3 albedo = mix(colorA, colorB, checker);
          hit.t = t;
          hit.position = pos;
          hit.normal = normal;
          hit.albedo = albedo;
          hit.emission = vec3(0.0);
          hit.specular = vec3(0.0);
          hit.roughness = 1.0;
          hit.material = MATERIAL_LAMBERT;
        }

        void intersectScene(Ray ray, inout HitInfo hit);

        vec3 traceRay(Ray ray, inout uint seed) {
          // パストレーシングで放射輝度を積算
          vec3 throughput = vec3(1.0);
          vec3 radiance = vec3(0.0);

          for (int bounce = 0; bounce < MAX_BOUNCES; ++bounce) {
            HitInfo hit;
            hit.t = 1e20;
            hit.material = MATERIAL_NONE;
            intersectScene(ray, hit);

            if (hit.material == MATERIAL_NONE) {
              radiance += throughput * environment(ray);
              break;
            }

            radiance += throughput * hit.emission;
            if (hit.material == MATERIAL_LIGHT) {
              break;
            }

            vec3 origin = hit.position + hit.normal * 0.001;

            if (hit.material == MATERIAL_MIRROR) {
              ray = Ray(origin, reflect(ray.direction, hit.normal));
              throughput *= hit.albedo;
              continue;
            }

            vec3 newDir;

            if (hit.material == MATERIAL_GLOSSY) {
              float specIntensity = max(hit.specular.r, max(hit.specular.g, hit.specular.b));
              float diffIntensity = max(hit.albedo.r, max(hit.albedo.g, hit.albedo.b));
              float totalIntensity = specIntensity + diffIntensity;
              float specProb = (totalIntensity > 0.0) ? (specIntensity / totalIntensity) : 0.0;
              specProb = min(specProb, 0.95);

              float choice = rand(seed);
              if (choice < specProb && specIntensity > 0.0) {
                vec2 xiSpec = rand2(seed);
                float gloss = clamp(1.0 - hit.roughness, 0.0, 0.999);
                float exponent = mix(5.0, 200.0, gloss * gloss);
                vec3 reflectDir = reflect(ray.direction, hit.normal);
                newDir = samplePhongLobe(reflectDir, exponent, xiSpec);
                if (dot(newDir, hit.normal) <= 0.0) {
                  newDir = reflectDir;
                }
                throughput *= hit.specular / max(specProb, 0.001);
              } else {
                vec2 xiDiff = rand2(seed);
                newDir = cosineSampleHemisphere(xiDiff, hit.normal);
                float diffuseProb = max(1.0 - specProb, 0.001);
                throughput *= hit.albedo / diffuseProb;
              }

              float p = max(
                max(hit.albedo.r, max(hit.albedo.g, hit.albedo.b)),
                max(hit.specular.r, max(hit.specular.g, hit.specular.b))
              );
              p = clamp(p, 0.1, 0.95);
              if (bounce > 2) {
                float rr = rand(seed);
                if (rr > p) {
                  break;
                }
                throughput *= 1.0 / p;
              }
            } else {
              vec2 xi = rand2(seed);
              newDir = cosineSampleHemisphere(xi, hit.normal);
              throughput *= hit.albedo;

              float p = max(hit.albedo.r, max(hit.albedo.g, hit.albedo.b));
              if (bounce > 2) {
                float rr = rand(seed);
                if (rr > p) {
                  break;
                }
                throughput *= 1.0 / p;
              }
            }

            ray = Ray(origin, newDir);
          }

          return radiance;
        }

        void main() {
          // ピクセルごとに複数サンプルを集めて平均化
          vec2 pixel = gl_FragCoord.xy;
          vec2 ndc = (pixel / uResolution) * 2.0 - 1.0;
          float aspect = uResolution.x / uResolution.y;

          vec3 camPos = vec3(0.0, 0.1, 4.0);
          vec3 target = vec3(0.0, -0.1, -1.0);
          vec3 up = vec3(0.0, 1.0, 0.0);
          vec3 forward = normalize(target - camPos);
          vec3 right = normalize(cross(forward, up));
          vec3 camUp = cross(right, forward);
          float tanHalfFov = tan(radians(45.0) * 0.5);

          uint baseSeed = uint(pixel.y) * 1973u + uint(pixel.x) * 9277u + 374761393u;
          baseSeed ^= uint(SPP) * 668265263u;

          vec3 accum = vec3(0.0);
          for (int s = 0; s < SPP; ++s) {
            uint seed = baseSeed + uint(s) * 1597334677u;
            vec2 jitter = rand2(seed) - 0.5;
            vec2 jittered = ndc + jitter / uResolution;
            vec3 dir = normalize(
              forward +
              right * jittered.x * aspect * tanHalfFov +
              camUp * jittered.y * tanHalfFov
            );
            Ray ray = Ray(camPos, dir);
            accum += traceRay(ray, seed);
          }

          vec3 color = accum / float(SPP);
          color = color / (color + vec3(1.0));
          color = pow(color, vec3(1.0 / 2.2));
          gl_FragColor = vec4(color, 1.0);
        }
  `;

  const fragmentShader = [
    fragmentShaderEnvironment,
    fragmentShaderCommon,
    fragmentShaderScene
  ].join('\n');

  let shaderMaterial;
  try {
    shaderMaterial = new THREE.ShaderMaterial({
      uniforms,
      vertexShader: `
        varying vec2 vUv;
        void main() {
          vUv = uv;
          gl_Position = vec4(position, 1.0);
        }
      `,
      fragmentShader,
      depthTest: false
    });
  } catch (err) {
    log?.(`ShaderMaterial creation failed: ${err?.message || err}`);
    throw err;
  }

  const quad = new THREE.Mesh(
    new THREE.PlaneGeometry(2, 2),
    shaderMaterial
  );

  scene.add(quad);

  async function renderFrame(tSec) {
    uniforms.uTime.value = tSec;
    try {
      renderer.render(scene, camera);
    } catch (err) {
      log?.(`Shader render failed: ${err?.message || err}`);
      const glContext = renderer?.getContext?.();
      const glError = glContext?.getError?.();
      if (glError && glContext && glError !== glContext.NO_ERROR) {
        log?.(`WebGL error code: 0x${glError.toString(16)}`);
      }
      throw err;
    }
  }

  function resize(nextWidth, nextHeight) {
    renderer.setSize(nextWidth, nextHeight, false);
    uniforms.uResolution.value.set(nextWidth, nextHeight);
  }

  await renderFrame(0);

  return {
    renderer,
    renderFrame,
    resize
  };
}
