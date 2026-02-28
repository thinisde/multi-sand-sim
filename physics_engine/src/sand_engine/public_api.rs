use super::SandEngine;
use crate::constants::{H, W};
use crate::gpu_resources::clear_texture;
use crate::types::Brush;
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
impl SandEngine {
    pub fn set_color(&mut self, r: f32, g: f32, b: f32) {
        self.brush_color = [r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0)];
    }

    pub fn reset(&mut self) {
        clear_texture(&self.queue, &self.sim_a);
        clear_texture(&self.queue, &self.sim_b);
        self.front_is_a = true;
        self.frame_parity = false;
    }

    /// Paint into the current front buffer with the local/default color.
    pub fn paint(&mut self, x: f32, y: f32, add: bool) {
        self.paint_internal(x, y, add, self.brush_color);
    }

    /// Paint into the current front buffer with an explicit color.
    pub fn paint_colored(&mut self, x: f32, y: f32, add: bool, r: f32, g: f32, b: f32) {
        self.paint_internal(
            x,
            y,
            add,
            [r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0)],
        );
    }

    /// Run one simulation step (3 passes).
    pub fn step(&mut self) {
        // vertical
        self.submit_update_pass(0, 0);
        self.swap_front();

        // diag passes alternate direction each frame
        let first_dx = if self.frame_parity { 1 } else { -1 };

        self.submit_update_pass(1, first_dx);
        self.swap_front();

        self.submit_update_pass(1, -first_dx);
        self.swap_front();

        self.frame_parity = !self.frame_parity;
    }

    /// Render current sim texture to the canvas.
    pub fn render(&mut self) {
        let frame = match self.surface.get_current_texture() {
            Ok(f) => f,
            Err(_) => {
                self.surface.configure(&self.device, &self.config);
                match self.surface.get_current_texture() {
                    Ok(f) => f,
                    Err(_) => return,
                }
            }
        };

        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let bg = self.blit_bg_for_front();

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("render_encoder"),
            });

        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("render_pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 18.0 / 255.0,
                            g: 18.0 / 255.0,
                            b: 26.0 / 255.0,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                    depth_slice: None,
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });

            pass.set_pipeline(&self.blit_pipeline);
            pass.set_bind_group(0, bg, &[]);
            pass.draw(0..3, 0..1);
        }

        self.queue.submit(Some(encoder.finish()));
        frame.present();
    }

    /// Replace both simulation buffers with server-authoritative bytes.
    /// Accepts RGBA8 (`W*H*4`) and backward-compatible occupancy (`W*H`).
    pub fn import_state(&mut self, bytes: &[u8]) {
        let expected_rgba = (W * H * 4) as usize;
        let expected_occ = (W * H) as usize;

        let rgba_storage: Vec<u8>;
        let rgba_bytes = if bytes.len() == expected_rgba {
            bytes
        } else if bytes.len() == expected_occ {
            let [r, g, b] = self.brush_color;
            let rr = (r * 255.0).round().clamp(0.0, 255.0) as u8;
            let gg = (g * 255.0).round().clamp(0.0, 255.0) as u8;
            let bb = (b * 255.0).round().clamp(0.0, 255.0) as u8;

            rgba_storage = bytes
                .iter()
                .flat_map(|a| [rr, gg, bb, *a])
                .collect::<Vec<u8>>();
            rgba_storage.as_slice()
        } else {
            return;
        };

        let layout = wgpu::TexelCopyBufferLayout {
            offset: 0,
            bytes_per_row: Some(W * 4),
            rows_per_image: Some(H),
        };

        let extent = wgpu::Extent3d {
            width: W,
            height: H,
            depth_or_array_layers: 1,
        };

        self.queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &self.sim_a,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            rgba_bytes,
            layout,
            extent,
        );

        self.queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &self.sim_b,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            rgba_bytes,
            layout,
            extent,
        );

        self.front_is_a = true;
    }

    fn submit_update_pass(&mut self, pass_type: i32, diag_dx: i32) {
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("step_encoder"),
            });

        self.run_update_pass(&mut encoder, pass_type, diag_dx);
        self.queue.submit(Some(encoder.finish()));
    }

    fn paint_internal(&mut self, x: f32, y: f32, add: bool, color: [f32; 3]) {
        if !x.is_finite() || !y.is_finite() {
            return;
        }

        let max_x = (W.saturating_sub(1)) as f32;
        let max_y = (self.ground_y - 2.0).max(0.0);
        let xx = x.clamp(0.0, max_x);
        let yy = y.clamp(0.0, max_y);

        let brush = Brush {
            center: [xx, yy],
            radius: 7.0,
            add: if add { 1.0 } else { 0.0 },
            color,
            _pad: 0.0,
        };
        self.queue
            .write_buffer(&self.brush_buf, 0, bytemuck::bytes_of(&brush));

        let (_, dst_view) = self.front_back_views();
        let bg = self.brush_bg_for_front();

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("brush_encoder"),
            });

        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("brush_pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: dst_view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                    depth_slice: None,
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });

            pass.set_pipeline(&self.brush_pipeline);
            pass.set_bind_group(0, bg, &[]);
            pass.draw(0..3, 0..1);
        }

        self.queue.submit(Some(encoder.finish()));
        self.swap_front();
    }
}
