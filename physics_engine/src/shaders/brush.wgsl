// src/shaders/brush.wgsl

struct Brush {
  center: vec2<f32>,
  radius: f32,
  add: f32,
  color: vec3<f32>,
  _pad: f32,
};

@group(0) @binding(0) var srcTex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> brush: Brush;

struct VSOut {
  @builtin(position) pos: vec4<f32>,
};

@vertex
fn vs_fullscreen(@builtin(vertex_index) vi: u32) -> VSOut {
  var positions = array<vec2<f32>, 3>(
    vec2<f32>(-1.0, -1.0),
    vec2<f32>( 3.0, -1.0),
    vec2<f32>(-1.0,  3.0)
  );
  let p = positions[vi];
  var o: VSOut;
  o.pos = vec4<f32>(p, 0.0, 1.0);
  return o;
}

@fragment
fn fs_brush(@builtin(position) fragPos: vec4<f32>) -> @location(0) vec4<f32> {
  let dims = textureDimensions(srcTex);
  let p = vec2<i32>(i32(fragPos.x), i32(fragPos.y));
  if (p.x < 0 || p.y < 0 || p.x >= i32(dims.x) || p.y >= i32(dims.y)) {
    return vec4<f32>(0.0, 0.0, 0.0, 0.0);
  }

  let d = distance(fragPos.xy, brush.center);
  let cur = textureLoad(srcTex, p, 0);

  let painted = select(vec4<f32>(0.0, 0.0, 0.0, 0.0), vec4<f32>(brush.color, 1.0), brush.add > 0.5);
  let outv = select(cur, painted, d <= brush.radius);
  return outv;
}
