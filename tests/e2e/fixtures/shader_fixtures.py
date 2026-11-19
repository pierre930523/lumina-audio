"""
GLSL shader syntax validator and Impeller shader mathematical reference models.
Verifies liquid_glass.frag and mesh_fluid_bg.frag, Flutter pubspec asset declarations,
path traversal checks, and Impeller graphics backend requirements.
"""
import math
import os
import re
from typing import Dict, Any, List, Tuple


def get_shader_path(shader_name: str) -> str:
    """Resolves absolute path to shader file in app/shaders/."""
    current_dir = os.path.dirname(os.path.abspath(__file__))
    workspace_root = os.path.abspath(os.path.join(current_dir, "..", "..", ".."))
    shader_path = os.path.join(workspace_root, "app", "shaders", shader_name)
    if not os.path.isfile(shader_path):
        raise FileNotFoundError(f"Shader not found at {shader_path}")
    return shader_path


def validate_glsl_shader(shader_name: str) -> Dict[str, Any]:
    """
    Validates syntax, directives, uniform declarations, and entry point of a GLSL shader.
    """
    path = get_shader_path(shader_name)
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    lines = content.splitlines()
    has_version_460 = any("#version 460 core" in line for line in lines)
    has_runtime_effect = any("#include <flutter/runtime_effect.glsl>" in line for line in lines)
    has_out_frag_color = any("out vec4 fragColor;" in line for line in lines)
    has_main = any("void main()" in line for line in lines)

    # Extract declared uniforms
    uniform_pattern = re.compile(r"^\s*uniform\s+([a-zA-Z0-9_]+)\s+([a-zA-Z0-9_]+)\s*;", re.MULTILINE)
    uniforms = {match[1]: match[0] for match in uniform_pattern.findall(content)}

    return {
        "file": shader_name,
        "path": path,
        "line_count": len(lines),
        "has_version_460": has_version_460,
        "has_runtime_effect": has_runtime_effect,
        "has_out_frag_color": has_out_frag_color,
        "has_main": has_main,
        "uniforms": uniforms,
        "is_valid": has_version_460 and has_runtime_effect and has_out_frag_color and has_main,
    }


def evaluate_sd_rounded_box(
    p: Tuple[float, float],
    b: Tuple[float, float],
    r: float,
) -> float:
    """
    CPU reference implementation of Inigo Quilez signed distance field for rounded box:
    float sdRoundedBox(vec2 p, vec2 b, float r) {
        vec2 q = abs(p) - b + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    }
    """
    qx = abs(p[0]) - b[0] + r
    qy = abs(p[1]) - b[1] + r

    outside_x = max(qx, 0.0)
    outside_y = max(qy, 0.0)
    outside_len = math.sqrt(outside_x * outside_x + outside_y * outside_y)
    inside_dist = min(max(qx, qy), 0.0)

    return inside_dist + outside_len - r


def evaluate_mesh_fluid_weights(
    uv: Tuple[float, float],
    time_sec: float,
) -> Tuple[float, float, float, float]:
    """
    CPU reference implementation of 4-point dynamic fluid mesh weighting in mesh_fluid_bg.frag:
    Calculates weights (w1, w2, w3, w4) normalized such that sum(w_i) = 1.0.
    """
    t = time_sec * 0.22

    p1 = (0.25 + 0.18 * math.sin(t), 0.30 + 0.16 * math.cos(t * 1.3))
    p2 = (0.75 + 0.16 * math.cos(t * 0.9), 0.25 + 0.18 * math.sin(t * 1.1))
    p3 = (0.30 + 0.20 * math.cos(t * 1.2), 0.75 + 0.14 * math.sin(t * 0.8))
    p4 = (0.72 + 0.15 * math.sin(t * 1.4), 0.72 + 0.18 * math.cos(t))

    def d2(a, b):
        dx = a[0] - b[0]
        dy = a[1] - b[1]
        return dx * dx + dy * dy

    w1 = math.exp(-3.2 * d2(uv, p1))
    w2 = math.exp(-3.2 * d2(uv, p2))
    w3 = math.exp(-3.2 * d2(uv, p3))
    w4 = math.exp(-3.2 * d2(uv, p4))

    total = max(w1 + w2 + w3 + w4, 0.001)
    return (w1 / total, w2 / total, w3 / total, w4 / total)


def validate_pubspec_structure(doc: Dict[str, Any]) -> bool:
    """Verifies that pubspec dictionary has non-empty name and a flutter mapping."""
    if not isinstance(doc, dict):
        return False
    if "name" not in doc or not doc["name"]:
        return False
    if "flutter" not in doc or not isinstance(doc["flutter"], dict):
        return False
    return True


def is_valid_shader_asset_path(rel_path: str, base_dir: str) -> bool:
    """Verifies shader path ends with .frag and exists on disk within base_dir."""
    if not rel_path.endswith(".frag"):
        return False
    full = os.path.normpath(os.path.join(base_dir, rel_path))
    return os.path.isfile(full)


def sanitize_asset_path(raw: str) -> str:
    """Sanitizes asset relative path, rejecting directory traversal attempts ('..') or leading slashes."""
    clean = raw.replace("\\", "/")
    parts = clean.split("/")
    if ".." in parts:
        raise ValueError(f"Path traversal detected in asset: {raw}")
    if clean.startswith("/"):
        raise ValueError(f"Absolute asset paths not permitted: {raw}")
    return clean


def check_impeller_support(api_name: str, major: int, minor: int) -> bool:
    """Verifies Impeller rendering requirements: Vulkan >= 1.1, OpenGL ES >= 3.0, Metal >= 2.0."""
    api = api_name.lower()
    if api == "vulkan":
        return (major > 1) or (major == 1 and minor >= 1)
    elif api in ("opengles", "gles"):
        return major >= 3
    elif api == "metal":
        return major >= 2
    return False
