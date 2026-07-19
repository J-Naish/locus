#include <metal_stdlib>
using namespace metal;

struct TerminalSolidInstance {
  float4 rectPx;
  float4 color;
};

struct TerminalGlyphInstance {
  float4 rectPx;
  float4 uv;
  float4 color;
  uint flags;
  uint _pad0;
  uint _pad1;
  uint _pad2;
};

static_assert(sizeof(TerminalSolidInstance) == 32,
              "must match MemoryLayout<TerminalSolidInstance>.stride");
static_assert(sizeof(TerminalGlyphInstance) == 64,
              "must match MemoryLayout<TerminalGlyphInstance>.stride");

struct TerminalUniforms {
  float2 drawableSizePx;
};

struct TerminalVertexOut {
  float4 position [[position]];
  float2 uv;
  float4 color;
  uint flags [[flat]];
};

static float2 terminal_quad_position(uint vertexID) {
  switch (vertexID) {
    case 0: return float2(0.0, 0.0);
    case 1: return float2(0.0, 1.0);
    case 2: return float2(1.0, 0.0);
    default: return float2(1.0, 1.0);
  }
}

static float4 terminal_clip_position(float2 px, float2 drawableSizePx) {
  return float4(
    px.x / drawableSizePx.x * 2.0 - 1.0,
    1.0 - px.y / drawableSizePx.y * 2.0,
    0.0,
    1.0);
}

vertex TerminalVertexOut terminal_solid_vertex(
  uint vertexID [[vertex_id]],
  uint instanceID [[instance_id]],
  constant TerminalSolidInstance *instances [[buffer(0)]],
  constant TerminalUniforms &uniforms [[buffer(1)]]) {
  TerminalSolidInstance instance = instances[instanceID];
  float2 unit = terminal_quad_position(vertexID);
  float2 px = instance.rectPx.xy + unit * instance.rectPx.zw;
  TerminalVertexOut result;
  result.position = terminal_clip_position(px, uniforms.drawableSizePx);
  result.uv = float2(0.0);
  result.color = instance.color;
  result.flags = 0;
  return result;
}

fragment float4 terminal_solid_fragment(TerminalVertexOut input [[stage_in]]) {
  return input.color;
}

vertex TerminalVertexOut terminal_glyph_vertex(
  uint vertexID [[vertex_id]],
  uint instanceID [[instance_id]],
  constant TerminalGlyphInstance *instances [[buffer(0)]],
  constant TerminalUniforms &uniforms [[buffer(1)]]) {
  TerminalGlyphInstance instance = instances[instanceID];
  float2 unit = terminal_quad_position(vertexID);
  float2 px = instance.rectPx.xy + unit * instance.rectPx.zw;
  TerminalVertexOut result;
  result.position = terminal_clip_position(px, uniforms.drawableSizePx);
  result.uv = mix(instance.uv.xy, instance.uv.zw, unit);
  result.color = instance.color;
  result.flags = instance.flags;
  return result;
}

fragment float4 terminal_glyph_fragment(
  TerminalVertexOut input [[stage_in]],
  texture2d<float> grayscaleAtlas [[texture(0)]],
  texture2d<float> colorAtlas [[texture(1)]]) {
  constexpr sampler glyphSampler(
    coord::normalized,
    address::clamp_to_zero,
    filter::linear);
  if ((input.flags & 1u) != 0u) {
    return colorAtlas.sample(glyphSampler, input.uv);
  }
  float alpha = grayscaleAtlas.sample(glyphSampler, input.uv).r;
  return input.color * alpha;
}
