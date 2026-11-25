//
//  MonitorShaders.metal
//  CineView Pro
//
//  专业监视器 Metal 着色器管线：
//  1. 顶点/片元管线：双源输入 (RGB / YCbCr Rec.709) + 变形镜头反挤压 + 3D LUT 三线性插值
//                    + 12 段 Rec.709 IRE 假色 + Sobel 峰值对焦 (红/绿/黄) + 动态斑马纹
//  2. 计算管线 (Compute)：并行生成 亮度波形图 (Waveform) 与 RGB+Luma 直方图 (Histogram)
//

#include <metal_stdlib>
using namespace metal;

// MARK: - 共享 Uniform 结构 (严格 16 字节对齐，总长 112 字节，与 Swift MonitorUniforms 一一对应)

struct MonitorUniforms {
    // Block 0 (0...15)
    float2 sourceSize;          // 原始画面分辨率 (px)
    float2 viewportSize;        // MTKView Drawable 物理分辨率 (px)

    // Block 1 (16...31)
    float desqueezeFactor;      // 变形镜头反挤压倍率 (1.0, 1.33, 1.5, 2.0)
    float time;                 // 累计时间 (秒)，用于驱动动态斜纹斑马纹
    uint  inputFormat;          // 0 = RGB/BGRA 单纹理, 1 = YCbCr Rec.709 VideoRange, 2 = YCbCr Rec.709 FullRange
    uint  lutEnabled;           // 0 = 关闭, 1 = 启用 3D LUT

    // Block 2 (32...47)
    float lutIntensity;         // 3D LUT 混合强度 [0.0, 1.0]
    float lutDimension;         // 3D LUT 尺寸 (如 17.0, 33.0, 65.0)
    uint  falseColorEnabled;    // 0 = 关闭, 1 = 启用 12 段假色
    uint  peakingEnabled;       // 0 = 关闭, 1 = 启用 Sobel 峰值对焦

    // Block 3 (48...63)
    float peakingSensitivity;   // 峰值对焦灵敏度 [0.0, 1.0]，值越高边缘触发阈值越低
    uint  peakingColorMode;     // 0 = 红, 1 = 绿, 2 = 黄
    uint  zebraEnabled;         // 0 = 关闭, 1 = 启用斑马纹
    float zebraThresholdIRE;    // 斑马纹触发阈值 [0.0, 100.0] IRE

    // Block 4 (64...79)
    float4 lutDomainMin;        // .cube DOMAIN_MIN (xyz 有效)

    // Block 5 (80...95)
    float4 lutDomainMax;        // .cube DOMAIN_MAX (xyz 有效)

    // Block 6 (96...111)
    uint  scopesApplyLUT;       // Compute 示波器是否基于 3D LUT 还原后的数据计算 (0 = Raw/Log, 1 = Post-LUT)
    uint  waveformWidth;        // 波形图水平列数 (默认 256)
    uint  waveformHeight;       // 波形图垂直 IRE 级数 (默认 128)
    uint  sampleStride;         // Compute 采样步长 (>= 1)，平衡 60fps 性能与统计精度
};

struct VertexOut {
    float4 position [[position]];
    float2 screenUV; // [0, 1] 视口归一化坐标，原点左上
};

// MARK: - 公共色彩与采样辅助函数

/// Rec.709 标准亮度系数 (BT.709 Luma Y)
constant float3 kRec709LumaWeights = float3(0.2126f, 0.7152f, 0.0722f);

/// 统一双源采样：兼容单纹理 RGBA/BGRA (PTP LiveView / 32BGRA) 与双平面 YCbCr (UVC HDMI 采集卡)
inline float3 sampleUnifiedRGB(
    float2 uv,
    texture2d<float, access::sample> primaryTex,
    texture2d<float, access::sample> chromaTex,
    sampler linearSampler,
    uint inputFormat
) {
    if (inputFormat == 0u) {
        return primaryTex.sample(linearSampler, uv).rgb;
    }

    float ySample = primaryTex.sample(linearSampler, uv).r;
    float2 cbcr   = chromaTex.sample(linearSampler, uv).rg;

    if (inputFormat == 1u) {
        // ITU-R BT.709 Video Range (Y ∈ [16/255, 235/255], CbCr ∈ [16/255, 240/255])
        float y  = (ySample - (16.0f / 255.0f)) * (255.0f / 219.0f);
        float cb = (cbcr.x - 0.5f) * (255.0f / 224.0f);
        float cr = (cbcr.y - 0.5f) * (255.0f / 224.0f);
        float r  = y + 1.5748f * cr;
        float g  = y - 0.187324f * cb - 0.468124f * cr;
        float b  = y + 1.8556f * cb;
        return saturate(float3(r, g, b));
    } else {
        // ITU-R BT.709 Full Range (Y ∈ [0, 1], CbCr ∈ [0, 1] 中心 0.5)
        float y  = ySample;
        float cb = cbcr.x - 0.5f;
        float cr = cbcr.y - 0.5f;
        float r  = y + 1.5748f * cr;
        float g  = y - 0.187324f * cb - 0.468124f * cr;
        float b  = y + 1.8556f * cb;
        return saturate(float3(r, g, b));
    }
}

/// 3D LUT 硬件三线性插值调色 (用于 Sony S-Log3 / S-Gamut3.Cine -> Rec.709 还原)
inline float3 apply3DLUT(
    float3 color,
    texture3d<float, access::sample> lutTex,
    sampler lutSampler,
    constant MonitorUniforms& u
) {
    if (u.lutEnabled == 0u || u.lutDimension < 2.0f || u.lutIntensity <= 0.0001f) {
        return color;
    }

    // 1. 按 .cube 文件的 DOMAIN_MIN / DOMAIN_MAX 归一化到 [0, 1]
    float3 domainRange = max(u.lutDomainMax.rgb - u.lutDomainMin.rgb, float3(1e-5f));
    float3 normalized  = saturate((color - u.lutDomainMin.rgb) / domainRange);

    // 2. 映射到 3D 纹理体素中心坐标：避免边缘半像素偏移导致的黑位/高光色偏
    //    coord = (normalized * (N - 1) + 0.5) / N
    float size  = u.lutDimension;
    float3 uvw  = (normalized * (size - 1.0f) + 0.5f) / size;

    // 3. 硬件三线性插值采样 (R -> x, G -> y, B -> z，与 .cube 排列完全一致)
    float3 graded = lutTex.sample(lutSampler, uvw).rgb;
    return mix(color, saturate(graded), saturate(u.lutIntensity));
}

/// 12 段专业电影监视器假色映射 (Rec.709 Luma 0–100 IRE)
///
/// 段位对照 (ARRI / SmallHD / Atomos 行业通用参考):
///  0:  0 -  2 IRE  深紫 (黑位死黑裁切)
///  1:  2 - 10 IRE  深蓝 (极暗部)
///  2: 10 - 20 IRE  钴蓝 (暗部细节)
///  3: 20 - 30 IRE  青色 (暗中灰)
///  4: 30 - 40 IRE  青绿 (中灰偏暗 / S-Log3 18% 灰附近)
///  5: 40 - 48 IRE  中暗灰 (常规保留细节区)
///  6: 48 - 55 IRE  翠绿 (Rec.709 18% 中性灰曝光基准)
///  7: 55 - 65 IRE  浅灰 (中亮部)
///  8: 65 - 73 IRE  粉红 (标准肤色高光基准 ~70 IRE)
///  9: 73 - 85 IRE  亮灰 (亮部细节)
/// 10: 85 - 95 IRE  亮黄 (临近过曝警告)
/// 11: 95 -100 IRE  纯红 (高光过曝裁切)
inline float3 mapFalseColor12Band(float luma) {
    float ire = clamp(luma, 0.0f, 1.0f) * 100.0f;

    if (ire < 2.0f)  return float3(0.32f, 0.00f, 0.58f); // Band  1: 深紫 (0-2 IRE)
    if (ire < 10.0f) return float3(0.05f, 0.10f, 0.65f); // Band  2: 深蓝 (2-10 IRE)
    if (ire < 20.0f) return float3(0.00f, 0.38f, 0.92f); // Band  3: 钴蓝 (10-20 IRE)
    if (ire < 30.0f) return float3(0.00f, 0.72f, 0.88f); // Band  4: 青色 (20-30 IRE)
    if (ire < 40.0f) return float3(0.08f, 0.56f, 0.52f); // Band  5: 青绿 (30-40 IRE)
    if (ire < 48.0f) return float3(0.38f, 0.38f, 0.38f); // Band  6: 中暗灰 (40-48 IRE)
    if (ire < 55.0f) return float3(0.16f, 0.82f, 0.24f); // Band  7: 翠绿 (48-55 IRE, 中性灰基准)
    if (ire < 65.0f) return float3(0.58f, 0.58f, 0.58f); // Band  8: 浅灰 (55-65 IRE)
    if (ire < 73.0f) return float3(0.98f, 0.45f, 0.68f); // Band  9: 粉红 (65-73 IRE, 肤色基准)
    if (ire < 85.0f) return float3(0.80f, 0.80f, 0.80f); // Band 10: 亮灰 (73-85 IRE)
    if (ire < 95.0f) return float3(0.98f, 0.84f, 0.08f); // Band 11: 亮黄 (85-95 IRE, 高光预警)
    return float3(0.95f, 0.08f, 0.08f);                  // Band 12: 纯红 (95-100 IRE, 过曝裁切)
}

/// 快速获取单像素 Rec.709 亮度，用于 Sobel 3x3 边缘检测
inline float sampleLumaFast(
    float2 uv,
    texture2d<float, access::sample> primaryTex,
    sampler linearSampler,
    uint inputFormat
) {
    if (inputFormat == 0u) {
        return dot(primaryTex.sample(linearSampler, uv).rgb, kRec709LumaWeights);
    } else if (inputFormat == 1u) {
        // YCbCr Video Range 直接用 Y 平面即可，省去 CbCr 9 次采样开销
        return saturate((primaryTex.sample(linearSampler, uv).r - (16.0f / 255.0f)) * (255.0f / 219.0f));
    } else {
        return primaryTex.sample(linearSampler, uv).r;
    }
}

// MARK: - 1. 全屏三角形顶点着色器 (零顶点缓冲开销)

vertex VertexOut monitorVertexShader(uint vertexID [[vertex_id]]) {
    // 单个超大三角形覆盖 NDC [-1, 1]，比双三角形四边形减少一次对角线光栅化接缝
    constexpr float2 positions[3] = {
        float2(-1.0f, -1.0f),
        float2( 3.0f, -1.0f),
        float2(-1.0f,  3.0f)
    };
    constexpr float2 uvs[3] = {
        float2(0.0f, 1.0f),
        float2(2.0f, 1.0f),
        float2(0.0f, -1.0f)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0f, 1.0f);
    out.screenUV = uvs[vertexID];
    return out;
}

// MARK: - 2. 专业监视器片元着色器

fragment float4 monitorFragmentShader(
    VertexOut in [[stage_in]],
    constant MonitorUniforms& u [[buffer(0)]],
    texture2d<float, access::sample> primaryTex [[texture(0)]],
    texture2d<float, access::sample> chromaTex  [[texture(1)]],
    texture3d<float, access::sample> lutTex     [[texture(2)]]
) {
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler lutSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    // ---------------------------------------------------------
    // Step 1: 变形镜头反挤压 (Anamorphic De-squeeze) 与等比信箱裁剪
    // ---------------------------------------------------------
    // 反挤压仅拉伸画面等效水平宽高比: effectiveAspect = (srcW / srcH) * desqueezeFactor
    float srcW = max(u.sourceSize.x, 1.0f);
    float srcH = max(u.sourceSize.y, 1.0f);
    float vpW  = max(u.viewportSize.x, 1.0f);
    float vpH  = max(u.viewportSize.y, 1.0f);

    float effectiveAspect = (srcW / srcH) * max(u.desqueezeFactor, 1.0f);
    float viewportAspect  = vpW / vpH;

    float2 uv = in.screenUV;
    if (viewportAspect > effectiveAspect) {
        // 视口更宽 -> 左右加黑边 (Pillarbox)
        float scaleX = viewportAspect / effectiveAspect;
        uv.x = (uv.x - 0.5f) * scaleX + 0.5f;
    } else {
        // 视口更高 -> 上下加黑边 (Letterbox)
        float scaleY = effectiveAspect / viewportAspect;
        uv.y = (uv.y - 0.5f) * scaleY + 0.5f;
    }

    // 画面有效区以外输出纯黑信箱背景，不叠加任何辅助线或斑马纹
    if (uv.x < 0.0f || uv.x > 1.0f || uv.y < 0.0f || uv.y > 1.0f) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    // ---------------------------------------------------------
    // Step 2: 统一双源采样 + 3D LUT 三线性插值还原
    // ---------------------------------------------------------
    float3 rawRGB     = sampleUnifiedRGB(uv, primaryTex, chromaTex, videoSampler, u.inputFormat);
    float3 displayRGB = apply3DLUT(rawRGB, lutTex, lutSampler, u);
    float  luma       = dot(displayRGB, kRec709LumaWeights);

    // ---------------------------------------------------------
    // Step 3: 假色 (False Color, 12 段 Rec.709 IRE)
    // ---------------------------------------------------------
    float3 outColor = (u.falseColorEnabled != 0u) ? mapFalseColor12Band(luma) : displayRGB;

    // ---------------------------------------------------------
    // Step 4: 斑马纹 (Zebra - 过曝动态 45° 斜纹)
    // ---------------------------------------------------------
    if (u.zebraEnabled != 0u && u.falseColorEnabled == 0u) {
        float ire = luma * 100.0f;
        if (ire >= u.zebraThresholdIRE) {
            // 基于物理像素坐标生成 45° 动态斜纹，周期 12px，滚动速度 36px/s
            float diag = in.position.x + in.position.y - u.time * 36.0f;
            float stripe = fract(diag / 12.0f);
            // 亮暗交替高对比斜纹 (半透明黑条叠加，保证强光下依然清晰可辨)
            float mask = step(0.5f, stripe);
            float3 zebraColor = mix(float3(0.05f, 0.05f, 0.05f), float3(0.98f, 0.98f, 0.98f), mask);
            outColor = mix(outColor, zebraColor, 0.72f);
        }
    }

    // ---------------------------------------------------------
    // Step 5: 峰值对焦 (Focus Peaking - 3x3 Sobel 边缘算子)
    // ---------------------------------------------------------
    if (u.peakingEnabled != 0u) {
        float2 texel = 1.0f / float2(srcW, srcH);

        // 3x3 邻域亮度采样
        float tl = sampleLumaFast(uv + float2(-texel.x, -texel.y), primaryTex, videoSampler, u.inputFormat);
        float tc = sampleLumaFast(uv + float2(    0.0f, -texel.y), primaryTex, videoSampler, u.inputFormat);
        float tr = sampleLumaFast(uv + float2( texel.x, -texel.y), primaryTex, videoSampler, u.inputFormat);

        float ml = sampleLumaFast(uv + float2(-texel.x,     0.0f), primaryTex, videoSampler, u.inputFormat);
        float mr = sampleLumaFast(uv + float2( texel.x,     0.0f), primaryTex, videoSampler, u.inputFormat);

        float bl = sampleLumaFast(uv + float2(-texel.x,  texel.y), primaryTex, videoSampler, u.inputFormat);
        float bc = sampleLumaFast(uv + float2(    0.0f,  texel.y), primaryTex, videoSampler, u.inputFormat);
        float br = sampleLumaFast(uv + float2( texel.x,  texel.y), primaryTex, videoSampler, u.inputFormat);

        // 标准 Sobel 卷积核:
        // Gx = [-1 0 +1; -2 0 +2; -1 0 +1]
        // Gy = [-1 -2 -1; 0 0 0; +1 +2 +1]
        float gx = -tl + tr - 2.0f * ml + 2.0f * mr - bl + br;
        float gy = -tl - 2.0f * tc - tr + bl + 2.0f * bc + br;
        float edgeMag = length(float2(gx, gy));

        // 灵敏度 [0.0, 1.0] 反向映射为梯度阈值 [0.55 -> 0.06]
        float sens = saturate(u.peakingSensitivity);
        float threshold = mix(0.55f, 0.06f, sens);
        float peakingAlpha = smoothstep(threshold, threshold + 0.12f, edgeMag);

        if (peakingAlpha > 0.001f) {
            float3 peakColor;
            if (u.peakingColorMode == 1u) {
                peakColor = float3(0.05f, 1.00f, 0.25f); // 绿
            } else if (u.peakingColorMode == 2u) {
                peakColor = float3(1.00f, 0.92f, 0.05f); // 黄
            } else {
                peakColor = float3(1.00f, 0.12f, 0.12f); // 红 (默认)
            }
            outColor = mix(outColor, peakColor, peakingAlpha * 0.90f);
        }
    }

    return float4(outColor, 1.0f);
}

// MARK: - 3. 计算着色器 (Compute Shader)：并行亮度波形图 + RGB 直方图

/// 直方图缓冲布局: 4 个通道 × 256 档 = 1024 个 uint
/// [0...255]    Red
/// [256...511]  Green
/// [512...767]  Blue
/// [768...1023] Luma (Rec.709 Y)
constant uint kHistBins = 256u;

/// Step A: 并行清零直方图与波形图缓冲
kernel void clearScopesKernel(
    device uint* histogramBuffer [[buffer(0)]],
    device uint* waveformBuffer  [[buffer(1)]],
    constant MonitorUniforms& u  [[buffer(2)]],
    uint gid                     [[thread_position_in_grid]]
) {
    uint histTotal = kHistBins * 4u;
    if (gid < histTotal) {
        histogramBuffer[gid] = 0u;
    }

    uint waveTotal = u.waveformWidth * u.waveformHeight;
    if (gid < waveTotal) {
        waveformBuffer[gid] = 0u;
    }
}

/// Step B: 并行统计当前帧的 RGB+Luma 直方图与 2D 亮度波形图分布
/// - 使用 threadgroup 共享内存做直方图局部归约，大幅降低全局原子写竞争，保证 60fps 极低 GPU 耗时。
kernel void analyzeScopesKernel(
    texture2d<float, access::sample> primaryTex [[texture(0)]],
    texture2d<float, access::sample> chromaTex  [[texture(1)]],
    texture3d<float, access::sample> lutTex     [[texture(2)]],
    device atomic_uint* histogramBuffer         [[buffer(0)]],
    device atomic_uint* waveformBuffer          [[buffer(1)]],
    constant MonitorUniforms& u                 [[buffer(2)]],
    uint2 gid                                   [[thread_position_in_grid]],
    uint  localIndex                            [[thread_index_in_threadgroup]],
    uint2 tgSize                                [[threads_per_threadgroup]]
) {
    // Threadgroup 局部直方图 (4 × 256 × 4B = 4KB，远低于 Apple GPU 32KB 共享内存上限)
    threadgroup atomic_uint localR[kHistBins];
    threadgroup atomic_uint localG[kHistBins];
    threadgroup atomic_uint localB[kHistBins];
    threadgroup atomic_uint localY[kHistBins];

    uint tgTotalThreads = tgSize.x * tgSize.y;
    for (uint i = localIndex; i < kHistBins; i += tgTotalThreads) {
        atomic_store_explicit(&localR[i], 0u, memory_order_relaxed);
        atomic_store_explicit(&localG[i], 0u, memory_order_relaxed);
        atomic_store_explicit(&localB[i], 0u, memory_order_relaxed);
        atomic_store_explicit(&localY[i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // 映射当前线程到源画面采样点 (按 sampleStride 降采样)
    uint stride = max(u.sampleStride, 1u);
    uint sampleX = gid.x * stride;
    uint sampleY = gid.y * stride;
    uint srcW = uint(max(u.sourceSize.x, 1.0f));
    uint srcH = uint(max(u.sourceSize.y, 1.0f));

    if (sampleX < srcW && sampleY < srcH) {
        constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        constexpr sampler lutSampler(coord::normalized, address::clamp_to_edge, filter::linear);

        float2 uv = (float2(float(sampleX), float(sampleY)) + 0.5f) / float2(float(srcW), float(srcH));
        float3 rgb = sampleUnifiedRGB(uv, primaryTex, chromaTex, videoSampler, u.inputFormat);

        if (u.scopesApplyLUT != 0u) {
            rgb = apply3DLUT(rgb, lutTex, lutSampler, u);
        }

        float luma = saturate(dot(rgb, kRec709LumaWeights));

        // 1. 累加到线程组局部 RGB + Luma 直方图
        uint binR = min(uint(saturate(rgb.r) * 255.0f + 0.5f), 255u);
        uint binG = min(uint(saturate(rgb.g) * 255.0f + 0.5f), 255u);
        uint binB = min(uint(saturate(rgb.b) * 255.0f + 0.5f), 255u);
        uint binY = min(uint(luma * 255.0f + 0.5f), 255u);

        atomic_fetch_add_explicit(&localR[binR], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&localG[binG], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&localB[binB], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&localY[binY], 1u, memory_order_relaxed);

        // 2. 累加到亮度波形图 (Waveform): X 轴对应画面水平列，Y 轴对应 0–100 IRE (0=底部, H-1=顶部)
        uint wfW = max(u.waveformWidth, 1u);
        uint wfH = max(u.waveformHeight, 1u);
        uint wfX = min(uint(uv.x * float(wfW)), wfW - 1u);
        uint wfY = min(uint(luma * float(wfH - 1u) + 0.5f), wfH - 1u);
        uint wfIdx = wfY * wfW + wfX;
        atomic_fetch_add_explicit(&waveformBuffer[wfIdx], 1u, memory_order_relaxed);
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    // 3. 将线程组局部直方图一次性合并回全局 Device Buffer
    for (uint i = localIndex; i < kHistBins; i += tgTotalThreads) {
        uint r = atomic_load_explicit(&localR[i], memory_order_relaxed);
        uint g = atomic_load_explicit(&localG[i], memory_order_relaxed);
        uint b = atomic_load_explicit(&localB[i], memory_order_relaxed);
        uint y = atomic_load_explicit(&localY[i], memory_order_relaxed);

        if (r > 0u) atomic_fetch_add_explicit(&histogramBuffer[i],               r, memory_order_relaxed);
        if (g > 0u) atomic_fetch_add_explicit(&histogramBuffer[kHistBins + i],   g, memory_order_relaxed);
        if (b > 0u) atomic_fetch_add_explicit(&histogramBuffer[kHistBins*2 + i], b, memory_order_relaxed);
        if (y > 0u) atomic_fetch_add_explicit(&histogramBuffer[kHistBins*3 + i], y, memory_order_relaxed);
    }
}
