#version 460 core
#include <flutter/runtime_effect.glsl>

// Liquid Glass edge lens refraction and specular rim shader for Impeller.
uniform vec2 uSize;
uniform float uRadius;
uniform float uRefractionStrength;
uniform vec4 uTint;
uniform sampler2D uBackdrop;

out vec4 fragColor;

float sdRoundedBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    vec2 frag = FlutterFragCoord().xy;
    vec2 halfSize = max(uSize * 0.5, vec2(1.0));
    vec2 centered = frag - halfSize;
    float dist = sdRoundedBox(centered, halfSize, uRadius);

    if (dist > 0.5) {
        fragColor = vec4(0.0);
        return;
    }

    vec2 uv = frag / max(uSize, vec2(1.0));
    vec2 dir = normalize(centered + vec2(0.0001));
    float edgeBand = smoothstep(-18.0, 0.0, dist);
    vec2 refractedUv = clamp(uv - dir * edgeBand * uRefractionStrength, vec2(0.0), vec2(1.0));

    vec4 bg = texture(uBackdrop, refractedUv);
    vec3 glass = mix(bg.rgb, uTint.rgb, uTint.a);

    // Subtle top-left brighter specular rim for physical glass feel.
    float rim = smoothstep(-1.5, 0.0, dist);
    float lightDir = clamp(dot(-dir, normalize(vec2(-0.7, -0.7))) * 0.5 + 0.5, 0.0, 1.0);
    glass += vec3(0.28) * rim * lightDir;

    float alpha = 1.0 - smoothstep(-1.0, 0.5, dist);
    fragColor = vec4(glass, alpha);
}
