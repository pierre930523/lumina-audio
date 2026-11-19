#version 460 core
#include <flutter/runtime_effect.glsl>

// Apple Music-inspired 4-point album palette fluid mesh background.
uniform vec2 uSize;
uniform float uTime;
uniform vec4 uColorA;
uniform vec4 uColorB;
uniform vec4 uColorC;
uniform vec4 uColorD;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / max(uSize, vec2(1.0));
    float t = uTime * 0.22;

    vec2 p1 = vec2(0.25 + 0.18 * sin(t), 0.30 + 0.16 * cos(t * 1.3));
    vec2 p2 = vec2(0.75 + 0.16 * cos(t * 0.9), 0.25 + 0.18 * sin(t * 1.1));
    vec2 p3 = vec2(0.30 + 0.20 * cos(t * 1.2), 0.75 + 0.14 * sin(t * 0.8));
    vec2 p4 = vec2(0.72 + 0.15 * sin(t * 1.4), 0.72 + 0.18 * cos(t));

    float w1 = exp(-3.2 * dot(uv - p1, uv - p1));
    float w2 = exp(-3.2 * dot(uv - p2, uv - p2));
    float w3 = exp(-3.2 * dot(uv - p3, uv - p3));
    float w4 = exp(-3.2 * dot(uv - p4, uv - p4));
    float sum = max(w1 + w2 + w3 + w4, 0.001);

    vec4 col = (uColorA * w1 + uColorB * w2 + uColorC * w3 + uColorD * w4) / sum;
    fragColor = vec4(col.rgb, 1.0);
}
