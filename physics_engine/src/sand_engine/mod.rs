use wasm_bindgen::prelude::*;

mod init;
mod internal;
mod public_api;

#[wasm_bindgen]
pub struct SandEngine {
    // webgpu
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,

    // sim textures A/B
    sim_a: wgpu::Texture,
    sim_b: wgpu::Texture,
    view_a: wgpu::TextureView,
    view_b: wgpu::TextureView,

    // pipelines
    sand_pipeline: wgpu::RenderPipeline,
    brush_pipeline: wgpu::RenderPipeline,
    blit_pipeline: wgpu::RenderPipeline,

    // static bind groups (avoid per-frame creation churn)
    update_bg_a: wgpu::BindGroup,
    update_bg_b: wgpu::BindGroup,
    brush_bg_a: wgpu::BindGroup,
    brush_bg_b: wgpu::BindGroup,
    blit_bg_a: wgpu::BindGroup,
    blit_bg_b: wgpu::BindGroup,

    // uniforms
    params_buf: wgpu::Buffer,
    brush_buf: wgpu::Buffer,

    // state
    front_is_a: bool,
    frame_parity: bool,
    ground_y: f32,
    brush_color: [f32; 3],
}
