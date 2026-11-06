#!/usr/bin/env python3
"""Build the wash lab's browser playground from the shader iterations.

    python3 tools/wash-lab/playground.py <out.html>

Each `iterations/NN-slug.metal` is a full snapshot of `Choreganize/ChoreWash.metal` at that
step. This script converts each one to a WebGL2 (GLSL ES 3.00) fragment shader, so the
playground runs the same code the app ships, and fills `playground.html` with them plus the
titles and notes from `iterations/notes.json`.

The converter handles only the Metal subset the wash uses: scalar/vector/matrix types,
`powr`, `saturate`, a `wash::` namespace, `inline`, `[[ stitchable ]]` and `h` literals.
Anything else fails at shader compile time, and the page shows the error.
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

PRELUDE = """#version 300 es
precision highp float;
precision highp int;
float saturate(float x) { return clamp(x, 0.0, 1.0); }
vec2 saturate(vec2 x) { return clamp(x, 0.0, 1.0); }
vec3 saturate(vec3 x) { return clamp(x, 0.0, 1.0); }
"""

MAIN = """
uniform vec2 uCanvasPx;
uniform float uScale;
uniform vec2 uSize;
uniform float uTime, uDuration, uSeed, uDark, uLook, uMotion, uStrength;
uniform vec4 uBase, uA, uB, uGlow;
out vec4 outColor;
void main() {
    vec2 px = vec2(gl_FragCoord.x, uCanvasPx.y - gl_FragCoord.y);
    outColor = choreWash(px / uScale, uBase, uSize, uTime, uDuration, uSeed,
                         uA, uB, uGlow, uDark, uLook, __TAIL__);
}
"""

TYPES = [("float2x2", "mat2"), ("float2", "vec2"), ("float3", "vec3"), ("float4", "vec4"),
         ("half4", "vec4"), ("half3", "vec3"), ("half2", "vec2"), ("uint2", "uvec2"),
         ("int2", "ivec2")]


# Identifiers that are legal in Metal but reserved in GLSL ES 3.00. A hit here is a build error,
# not a silent compile failure in the page.
GLSL_RESERVED = {"out", "in", "inout", "uniform", "varying", "attribute", "input", "output",
                 "sampler", "filter", "precision", "lowp", "mediump", "highp", "discard",
                 "layout", "centroid", "flat", "smooth", "invariant", "patch", "sample"}


def check_reserved(metal: str, name: str) -> None:
    code = re.sub(r"//.*$", "", metal, flags=re.M)
    hits = sorted({m.group(1) for m in re.finditer(r"\b(?:float\d?|half\d?|int|uint|bool)\s+(\w+)\b", code)
                   if m.group(1) in GLSL_RESERVED})
    if hits:
        raise SystemExit(f"{name}: variable name(s) reserved in GLSL: {', '.join(hits)} (rename in the .metal file)")


def to_glsl(metal: str) -> str:
    s = re.sub(r"^\s*#include.*$", "", metal, flags=re.M)
    s = re.sub(r"^\s*using namespace metal;\s*$", "", s, flags=re.M)
    s = re.sub(r"^\s*namespace wash \{\s*$", "", s, flags=re.M)
    s = re.sub(r"^\s*\}\s*// namespace wash\s*$", "", s, flags=re.M)
    s = s.replace("wash::", "").replace("[[ stitchable ]] ", "")
    s = re.sub(r"\binline\s+", "", s)
    for metal_type, glsl_type in TYPES:
        s = re.sub(r"\b" + metal_type + r"\b", glsl_type, s)
    s = re.sub(r"\bhalf\b", "float", s)
    s = re.sub(r"\bpowr\(", "pow(", s)
    s = re.sub(r"(\d)h\b", r"\1", s)
    # WebGL rejects non-ASCII source even inside comments.
    s = s.encode("ascii", "replace").decode()
    # Older snapshots predate the motion parameter.
    tail = "uMotion, uStrength" if re.search(r"\bfloat motion\b", metal) else "uStrength"
    return PRELUDE + s + MAIN.replace("__TAIL__", tail)


def main() -> None:
    out = Path(sys.argv[1])
    notes = json.loads((HERE / "iterations" / "notes.json").read_text())
    items = []
    for path in sorted((HERE / "iterations").glob("*.metal")):
        meta = notes.get(path.stem, {})
        check_reserved(path.read_text(), path.name)
        items.append({
            "id": path.stem,
            "title": meta.get("title", path.stem),
            "date": meta.get("date", ""),
            "note": meta.get("note", ""),
            "looks": meta.get("looks", ["Default", "Calm", "Diagonal"]),
            "duration": meta.get("duration", 2.6),
            "defaults": meta.get("defaults", {}),
            "file": f"tools/wash-lab/iterations/{path.name}",
            "glsl": to_glsl(path.read_text()),
        })
    template = (HERE / "playground.html").read_text()
    payload = json.dumps(items).replace("</", "<\\/")
    out.write_text(template.replace("__ITERATIONS__", payload))
    print(f"{len(items)} iteration(s) → {out}")


if __name__ == "__main__":
    main()
