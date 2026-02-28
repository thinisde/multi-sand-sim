use super::SandEngine;
use crate::types::Params;

impl SandEngine {
    pub(super) fn front_back_views(&self) -> (&wgpu::TextureView, &wgpu::TextureView) {
        if self.front_is_a {
            (&self.view_a, &self.view_b)
        } else {
            (&self.view_b, &self.view_a)
        }
    }

    pub(super) fn update_bg_for_front(&self) -> &wgpu::BindGroup {
        if self.front_is_a {
            &self.update_bg_a
        } else {
            &self.update_bg_b
        }
    }

    pub(super) fn brush_bg_for_front(&self) -> &wgpu::BindGroup {
        if self.front_is_a {
            &self.brush_bg_a
        } else {
            &self.brush_bg_b
        }
    }

    pub(super) fn blit_bg_for_front(&self) -> &wgpu::BindGroup {
        if self.front_is_a {
            &self.blit_bg_a
        } else {
            &self.blit_bg_b
        }
    }

    pub(super) fn swap_front(&mut self) {
        self.front_is_a = !self.front_is_a;
    }

    pub(super) fn run_update_pass(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        pass_type: i32,
        diag_dx: i32,
    ) {
        let params = Params {
            ground_y: self.ground_y,
            pass_type,
            diag_dx,
            _pad: 0,
        };
        self.queue
            .write_buffer(&self.params_buf, 0, bytemuck::bytes_of(&params));

        let bg = self.update_bg_for_front();
        let (_, dst_view) = self.front_back_views();

        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("update_pass"),
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

            pass.set_pipeline(&self.sand_pipeline);
            pass.set_bind_group(0, bg, &[]);
            pass.draw(0..3, 0..1);
        }
    }
}
