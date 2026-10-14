//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

// Tellomi（tellomi/tellomi#1595 E5-5、#1597 E5-8）：调色里和位置有关的几项——锐化、颗粒、暗角、模糊（移轴）。
// 数学写在 TellomiImageAdjustmentsRenderer.swift 顶上，和安卓 ImageAdjustmentsGl 的着色器是同一套（自己定的，Telegram 的着色器一行不搬）。
// 进来的是图自己颜色空间里的编码值（Swift 那边用 matchedFromWorkingSpace 转好），不是 CoreImage 的线性工作空间。
// [[stitchable]] 的 CoreImage 内核不用 -fcikernel 编译选项（iOS 15 起），但要链 CoreImage：SignalUI 的 MTLLINKER_FLAGS = -framework CoreImage。

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

namespace tellomi {

/// 颗粒用的噪声块：256 × 256，第 0 行在上；读的是一个格子的中心（采样器的线性插值在格子中心就是原值）。
float noiseAt(coreimage::sampler noise, float2 cell) {
    float2 wrapped = cell - 256.0 * floor(cell / 256.0);
    return noise.sample(noise.transform(float2(wrapped.x + 0.5, 255.5 - wrapped.y))).r * (255.0 / 127.5) - 1.0;
}

}

extern "C" {
namespace coreimage {

/// 锐化：c + amount·(c − 模糊)，模糊是以 step 像素为一格的 3×3 帐篷核（1 2 1 / 2 4 2 / 1 2 1，除以 16）。
/// 颜色是预乘过 alpha 的，结果夹在 0…alpha。
[[stitchable]] float4 tellomiSharpen(sampler image, float step, float amount, destination dest) {
    float2 p = dest.coord();
    float4 center = image.sample(image.transform(p));
    float4 edges = image.sample(image.transform(p + float2(-step, 0.0))) + image.sample(image.transform(p + float2(step, 0.0)))
        + image.sample(image.transform(p + float2(0.0, -step))) + image.sample(image.transform(p + float2(0.0, step)));
    float4 corners = image.sample(image.transform(p + float2(-step, -step))) + image.sample(image.transform(p + float2(step, -step)))
        + image.sample(image.transform(p + float2(-step, step))) + image.sample(image.transform(p + float2(step, step)));
    float4 blur = (center * 4.0 + edges * 2.0 + corners) / 16.0;
    float3 rgb = clamp(center.rgb + amount * (center.rgb - blur.rgb), 0.0, center.a);
    return float4(rgb, center.a);
}

/// 颗粒，然后暗角，最后模糊（顺序照两端 Telegram：颗粒在暗角前，模糊在所有工具之后）。
/// - grain：振幅（0.06 × 值/100）；grainCell：噪声一格多少像素；噪声在像素位置（左上为原点）÷ grainCell 处双线性插值、四边循环。
///   加的量按亮度 y 加权 w = 1 − |2y − 1|³（中间调最多，纯黑纯白不加），三个通道加同一个数（单色颗粒）。
/// - vignette：值/100；frameX / frameY 把图上的单位坐标（左上为原点，0…1）映到画框坐标 d（中心 0，四边 ±1），
///   ρ = min(|d| / √2, 1)，k = vignette · ρ³，c' = c^(1 + 1.2k) · (1 − 0.35k)（暗部比亮部压得多）。
/// - blur：模糊好、查过表的小图放大到整张图的样子；blurKind 0 关、1 径向、2 线性；blurCenter 是单位坐标（左上为原点）；
///   q = (单位坐标 − 中心) · 图宽高 / 短边，径向 d = |q|，线性 d = |q · blurNormal|；m = smoothstep(内半径, 外半径, d)，
///   这个像素 = mix(清楚的, 模糊的（也压暗角）, m)。
[[stitchable]] float4 tellomiGrainVignette(
    sampler image,
    sampler noise,
    sampler blur,
    float grain,
    float grainCell,
    float vignette,
    float2 size,
    float3 frameX,
    float3 frameY,
    float blurKind,
    float2 blurCenter,
    float2 blurRadii,
    float2 blurNormal,
    destination dest
) {
    float2 p = dest.coord();
    float4 color = image.sample(image.transform(p));
    if (color.a <= 0.0) {
        return color;
    }
    float3 rgb = clamp(color.rgb / color.a, 0.0, 1.0);
    float2 topLeft = float2(p.x, size.y - p.y);

    if (grain > 0.0) {
        float2 q = topLeft / grainCell - 0.5;
        float2 cell = floor(q);
        float2 f = q - cell;
        float n = mix(
            mix(tellomi::noiseAt(noise, cell), tellomi::noiseAt(noise, cell + float2(1.0, 0.0)), f.x),
            mix(tellomi::noiseAt(noise, cell + float2(0.0, 1.0)), tellomi::noiseAt(noise, cell + float2(1.0, 1.0)), f.x),
            f.y
        );
        float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        float t = abs(2.0 * y - 1.0);
        rgb = clamp(rgb + grain * (1.0 - t * t * t) * n, 0.0, 1.0);
    }

    float2 unit = topLeft / size;
    float k = 0.0;
    if (vignette > 0.0) {
        float3 homogeneous = float3(unit, 1.0);
        float2 d = float2(dot(frameX, homogeneous), dot(frameY, homogeneous));
        float rho = min(length(d) * M_SQRT1_2_F, 1.0);
        k = vignette * rho * rho * rho;
        rgb = pow(rgb, float3(1.0 + 1.2 * k)) * (1.0 - 0.35 * k);
    }

    if (blurKind > 0.5) {
        float4 blurred = blur.sample(blur.transform(p));
        float3 blurredRGB = blurred.a > 0.0 ? clamp(blurred.rgb / blurred.a, 0.0, 1.0) : rgb;
        if (k > 0.0) {
            blurredRGB = pow(blurredRGB, float3(1.0 + 1.2 * k)) * (1.0 - 0.35 * k);
        }
        float2 q = (unit - blurCenter) * size / min(size.x, size.y);
        float d = blurKind < 1.5 ? length(q) : abs(dot(q, blurNormal));
        rgb = mix(rgb, blurredRGB, smoothstep(blurRadii.x, blurRadii.y, d));
    }

    return float4(rgb * color.a, color.a);
}

}
}
