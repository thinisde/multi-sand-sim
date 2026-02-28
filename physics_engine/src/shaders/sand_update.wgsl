// src/shaders/sand_update.wgsl

struct Params {
  groundY: f32,
  passType: i32,
  diagDx: i32,
  _pad: i32,
};

@group(0) @binding(0) var srcTex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> params: Params;

fn texSize() -> vec2<i32> {
  let d = textureDimensions(srcTex);
  return vec2<i32>(i32(d.x), i32(d.y));
}

fn inBounds(p: vec2<i32>) -> bool {
  let s = texSize();
  return p.x >= 0 && p.y >= 0 && p.x < s.x && p.y < s.y;
}

fn samplePx(p: vec2<i32>) -> vec4<f32> {
  return textureLoad(srcTex, p, 0);
}

fn groundTexY() -> i32 {
  return i32(params.groundY);
}

fn isSand(p: vec2<i32>) -> bool {
  if (!inBounds(p)) { return false; }
  if (p.y >= groundTexY()) { return false; }
  return samplePx(p).a > 0.5;
}

fn isSolid(p: vec2<i32>) -> bool {
  if (!inBounds(p)) { return true; }
  if (p.y >= groundTexY()) { return true; }
  return samplePx(p).a > 0.5;
}

fn canMoveDown(src: vec2<i32>) -> bool {
  return isSand(src) && !isSolid(src + vec2<i32>(0, 1));
}

fn canMoveDiag(src: vec2<i32>, dx: i32) -> bool {
  return isSand(src)
      && isSolid(src + vec2<i32>(0, 1))
      && !isSolid(src + vec2<i32>(dx, 1));
}

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
fn fs_update(@builtin(position) fragPos: vec4<f32>) -> @location(0) vec4<f32> {
  let p = vec2<i32>(i32(fragPos.x), i32(fragPos.y));

  if (!inBounds(p) || p.y >= groundTexY()) {
    return vec4<f32>(0.0, 0.0, 0.0, 0.0);
  }

  let selfPx = samplePx(p);
  let selfOcc = selfPx.a > 0.5;
  let emptyPx = vec4<f32>(0.0, 0.0, 0.0, 0.0);

  if (params.passType == 0) {
    if (selfOcc) {
      if (canMoveDown(p)) {
        return emptyPx;
      }
      return selfPx;
    }

    let src = p + vec2<i32>(0, -1);
    if (canMoveDown(src)) {
      return samplePx(src);
    }
    return emptyPx;
  }

  let dx = params.diagDx;
  if (selfOcc) {
    if (canMoveDiag(p, dx)) {
      return emptyPx;
    }
    return selfPx;
  }

  let src = p + vec2<i32>(-dx, -1);
  if (canMoveDiag(src, dx)) {
    return samplePx(src);
  }

  return emptyPx;
}
