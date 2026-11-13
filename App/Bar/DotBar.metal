#include <SwiftUI/SwiftUI_Metal.h>
#include <metal_stdlib>
using namespace metal;

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float boxDistance(float2 p, float2 lower, float2 upper) {
    float2 center = (lower + upper) * 0.5;
    float2 q = abs(p - center) - (upper - lower) * 0.5;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

static float roundedBoxDistance(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

// Each segment is 5 floats: start, end (fractions of the bar width), red, green, blue.
// The view is larger than the bar by `pad` on each side, so the glow has room.
[[ stitchable ]] half4 dotBar(
    float2 position,
    half4 current,
    float2 size,
    float pad,
    float pitch,
    float time,
    float hovered,
    float scan,
    float front,
    float light,
    const device float *segments,
    int count
) {
    float2 bar = size - 2.0 * pad;
    float2 p = position - pad;
    float columns = bar.x / pitch;
    float outside = roundedBoxDistance(p - bar * 0.5, bar * 0.5, 5.0);

    float column = floor(clamp(p.x, 0.5, bar.x - 0.5) / pitch);
    int total = min(count / 5, 12);
    int index = -1;
    int last = -1;
    float segmentStart = 0.0;
    float segmentEnd = 0.0;
    float usedEnd = 0.0;
    float3 color = float3(0.0);
    for (int i = 0; i < total; i++) {
        float start = floor(segments[i * 5] * columns + 0.5);
        float end = floor(segments[i * 5 + 1] * columns + 0.5);
        if (end <= start) { continue; }
        usedEnd = max(usedEnd, end * pitch);
        // The glow of the free area comes from the last segment, so that segment stays selected past its end.
        if (index < 0 || column >= start) {
            index = i;
            segmentStart = start * pitch;
            segmentEnd = end * pitch;
            color = float3(segments[i * 5 + 2], segments[i * 5 + 3], segments[i * 5 + 4]);
        }
        last = i;
    }

    bool isInsideSegment = index >= 0 && p.x >= segmentStart && p.x < segmentEnd;
    float dim = (hovered >= 0.0 && float(index) != hovered) ? 0.26 : 1.0;
    float focus = (hovered >= 0.0 && float(index) == hovered) ? 1.0 : 0.0;
    float3 hot = mix(float3(1.0, 0.95, 0.88), float3(1.0, 0.5, 0.15), light);
    float headDistance = abs(p.x - usedEnd);

    if (outside > 0.0) {
        float3 rgb = float3(0.0);
        float alpha = 0.0;
        if (index >= 0) {
            float d = boxDistance(p, float2(segmentStart, 0.0), float2(segmentEnd, bar.y));
            float glow = exp(-d / 4.0) * 0.42 * dim * (1.0 + focus * 0.5);
            rgb += color * glow;
            alpha += glow * 0.8;
        }
        if (scan > 0.0 && usedEnd > 0.0) {
            float d = length(float2(max(headDistance - pitch * 2.0, 0.0), outside));
            float glow = exp(-d / 5.0) * 0.5 * scan;
            rgb += hot * glow;
            alpha += glow * 0.8;
        }
        if (front >= 0.0) {
            float d = length(float2(p.x - front * bar.x, outside));
            float glow = exp(-d / 3.0) * 0.7;
            rgb += hot * glow;
            alpha += glow * 0.8;
        }
        return half4(half3(rgb), half(min(alpha, 1.0)));
    }

    float2 cell = floor(p / pitch);
    float2 local = fract(p / pitch) - 0.5;
    float extent = max(abs(local.x), abs(local.y));
    float3 rgb;
    float alpha;

    if (!isInsideSegment) {
        float dot = step(extent, 0.17);
        float edge = step(outside, 0.0) * step(-1.0, outside);
        alpha = dot * mix(0.10, 0.20, light) + edge * mix(0.07, 0.12, light);
        rgb = float3(1.0 - light);
    } else {
        float seed = float(index) * 17.0;
        float h = hash21(cell + seed);
        float phase = h > 0.82 ? floor(time * 0.9 + h * 40.0) : 0.0;
        float density = mix(0.86, 0.2, cell.y * pitch / bar.y);
        density = mix(density, 0.94, focus);
        float lit = step(hash21(cell * 1.7 + seed + phase), density);
        float sparkle = step(0.965, hash21(cell * 3.1 + seed + phase));
        float dot = step(extent, 0.33);

        float3 base = mix(mix(float3(0.06), color, 0.17), mix(float3(1.0), color, 0.16), light);
        float3 litColor = mix(mix(mix(color, float3(1.0), 0.1), float3(1.0), sparkle * 0.75), mix(color, color * 0.5, sparkle), light);
        float3 dotColor = mix(mix(color * 0.36, mix(float3(1.0), color, 0.42), light), litColor, lit);
        rgb = mix(base, dotColor, dot);

        float head = scan * saturate(1.0 - headDistance / (pitch * 8.0));
        rgb = mix(rgb, hot, head * dot * mix(0.45, 0.95, lit));

        float line = 1.25;
        float3 rim = mix(color, float3(1.0), 0.22 * (1.0 - light));
        float horizontal = step(p.y, line) + step(bar.y - line, p.y);
        float outerLeft = (index == 0 || segmentStart <= 0.0) ? step(p.x, line) : 0.0;
        float outerRight = (index == last) ? step(segmentEnd - line, p.x) : 0.0;
        rgb = mix(rgb, rim, saturate(horizontal + outerLeft + outerRight));
        float divider = (segmentStart > 0.0) ? step(p.x - segmentStart, 1.0) : 0.0;
        rgb = mix(rgb, float3(mix(0.86, 1.0, light)), divider * 0.85);

        rgb = mix(float3(light * 0.92), rgb, dim);
        alpha = mix(0.92, 1.0, dot);
    }

    if (front >= 0.0) {
        float d = abs(p.x - front * bar.x);
        rgb += hot * exp(-d / 1.6);
        alpha = max(alpha, exp(-d / 1.6));
    }

    float mask = smoothstep(0.5, -0.5, outside);
    alpha = min(alpha, 1.0) * mask;
    return half4(half3(min(rgb, float3(1.0)) * alpha), half(alpha));
}
