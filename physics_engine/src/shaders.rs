pub(crate) const BLIT_WGSL: &str = r#"
@group(0) @binding(0) var t: texture_2d<f32>;

struct VSOut {
  @builtin(position) pos: vec4<f32>,
};

@vertex
fn vs(@builtin(vertex_index) vi: u32) -> VSOut {
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
fn fs(@builtin(position) fragPos: vec4<f32>) -> @location(0) vec4<f32> {
  let dims = textureDimensions(t);
  let p = vec2<i32>(i32(fragPos.x), i32(fragPos.y));
  if (p.x < 0 || p.y < 0 || p.x >= i32(dims.x) || p.y >= i32(dims.y)) {
    return vec4<f32>(0.0, 0.0, 0.0, 1.0);
  }
  let px = textureLoad(t, p, 0);
  return vec4<f32>(px.rgb, px.a);
}
"#;
