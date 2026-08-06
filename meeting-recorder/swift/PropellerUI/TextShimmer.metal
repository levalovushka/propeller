#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

/// Доля полосы в точке: 1 в центре, 0 за `halfWidth` от пика.
static float shimmerBand(
    float2 position,
    float4 bounds,
    float travel,
    float angleDeg,
    float halfWidth,
    float center
) {
    float2 size = bounds.zw;
    if (size.x < 1.0 || size.y < 1.0 || halfWidth < 0.0001) {
        return 0.0;
    }
    float2 local = position - bounds.xy;
    float rad = angleDeg * (M_PI_F / 180.0);
    float dx = sin(rad);
    float dy = -cos(rad);
    float lengthPx = abs(size.x * dx) + abs(size.y * dy);
    if (lengthPx < 1.0) {
        return 0.0;
    }
    float t = dot(local - size * 0.5, float2(dx, dy)) / lengthPx + 0.5;
    return saturate(1.0 - abs(t - (center + travel)) / halfWidth);
}

/// Блик по уже нарисованному тексту: пиксели светлеют к `peak`.
///
/// Для строки сайдбара — `colorEffect` прямо на `Text`. Буквы сами ярче,
/// отдельной маски нет.
[[ stitchable ]] half4 textShimmer(
    float2 position,
    half4 currentColor,
    float4 bounds,
    float travel,
    float angleDeg,
    float halfWidth,
    float center,
    half4 peak
) {
    if (currentColor.a < 0.001h) {
        return currentColor;
    }
    float band = shimmerBand(position, bounds, travel, angleDeg, halfWidth, center);
    if (band <= 0.0) {
        return currentColor;
    }
    half a = currentColor.a;
    half3 plain = currentColor.rgb / max(a, 0.001h);
    half3 peakRGB = peak.rgb / max(peak.a, 0.001h);
    half3 lit = mix(plain, peakRGB, half(band));
    return half4(lit * a, a);
}

/// Полоса-оверлей по силуэту глифов: снаружи прозрачно, в пике — `peak`.
///
/// Для фрагмента саммари: картинка глифов сверху текста. Без модуляции
/// альфы оверлей накрыл бы фразу целиком; с ней остаётся только едущий блик —
/// как старый `SidebarSweep().mask(glyphs)`.
[[ stitchable ]] half4 textShimmerBand(
    float2 position,
    half4 currentColor,
    float4 bounds,
    float travel,
    float angleDeg,
    float halfWidth,
    float center,
    half4 peak
) {
    half glyph = currentColor.a;
    if (glyph < 0.001h) {
        return half4(0.0h);
    }
    float band = shimmerBand(position, bounds, travel, angleDeg, halfWidth, center);
    half a = glyph * half(band) * peak.a;
    half3 peakRGB = peak.rgb / max(peak.a, 0.001h);
    return half4(peakRGB * a, a);
}
