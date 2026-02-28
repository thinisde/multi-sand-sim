use super::SandEngine;
use crate::constants::{H, W};
use crate::errors::js_err;
use crate::gpu_resources::{clear_texture, make_sim_texture};
use crate::shaders::BLIT_WGSL;
use crate::types::{Brush, Params};
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use wgpu::util::DeviceExt;

#[wasm_bindgen]
impl SandEngine {
    /// Async factory for WASM (do NOT block; avoids condvar/no_threads panics).
    #[wasm_bindgen]
    pub async fn new_async(canvas_id: String) -> Result<SandEngine, JsValue> {
        console_error_panic_hook::set_once();

        let window = web_sys::window().ok_or_else(|| js_err("no window"))?;
        let document = window.document().ok_or_else(|| js_err("no document"))?;
        let canvas = document
            .get_element_by_id(&canvas_id)
            .ok_or_else(|| js_err(format!("canvas #{canvas_id} not found")))?
            .dyn_into::<web_sys::HtmlCanvasElement>()
            .map_err(|_| js_err("element is not a canvas"))?;

        canvas.set_width(W);
        canvas.set_height(H);

        // Instance + surface
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor::default());
        // Use raw web handles so this compiles consistently with wgpu 28 API across targets.
        let value: &wasm_bindgen::JsValue = canvas.as_ref();
        let obj = core::ptr::NonNull::from(value).cast();
        let raw_window_handle = wgpu::rwh::WebCanvasWindowHandle::new(obj).into();
        let raw_display_handle = wgpu::rwh::WebDisplayHandle::new().into();
        let surface = unsafe {
            instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
                raw_display_handle,
                raw_window_handle,
            })
        }
        .map_err(|e| js_err(format!("create_surface failed: {e:?}")))?;

        // Adapter
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
            })
            .await
            .map_err(|e| js_err(format!("request_adapter failed: {e:?}")))?;

        // Device
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("device"),
                required_features: wgpu::Features::empty(),
                // IMPORTANT: do not request weird downlevel limits; browsers may reject unknown names.
                required_limits: wgpu::Limits::default(),
                memory_hints: wgpu::MemoryHints::Performance,
                trace: wgpu::Trace::Off,
                experimental_features: wgpu::ExperimentalFeatures::disabled(),
            })
            .await
            .map_err(|e| js_err(format!("request_device failed: {e:?}")))?;

        // Surface config
        let surface_caps = surface.get_capabilities(&adapter);
        let surface_format = surface_caps
            .formats
            .first()
            .copied()
            .ok_or_else(|| js_err("surface has no supported formats"))?;

        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: surface_format,
            width: W,
            height: H,
            present_mode: wgpu::PresentMode::Fifo,
            alpha_mode: surface_caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &config);

        // Simulation textures
        let (sim_a, view_a) = make_sim_texture(&device);
        let (sim_b, view_b) = make_sim_texture(&device);
        clear_texture(&queue, &sim_a);
        clear_texture(&queue, &sim_b);

        let ground_y = (H as f32) - 80.0;

        // Uniform buffers
        let params = Params {
            ground_y,
            pass_type: 0,
            diag_dx: 0,
            _pad: 0,
        };
        let params_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("params_buf"),
            contents: bytemuck::bytes_of(&params),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let brush = Brush {
            center: [0.0, 0.0],
            radius: 7.0,
            add: 1.0,
            color: [0.84, 0.71, 0.38],
            _pad: 0.0,
        };
        let brush_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("brush_buf"),
            contents: bytemuck::bytes_of(&brush),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        // Bind group layouts
        let update_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("update_bgl"),
            entries: &[
                // srcTex
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        multisampled: false,
                        view_dimension: wgpu::TextureViewDimension::D2,
                        sample_type: wgpu::TextureSampleType::Float { filterable: false },
                    },
                    count: None,
                },
                // params uniform
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
            ],
        });

        let brush_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("brush_bgl"),
            entries: &[
                // srcTex
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        multisampled: false,
                        view_dimension: wgpu::TextureViewDimension::D2,
                        sample_type: wgpu::TextureSampleType::Float { filterable: false },
                    },
                    count: None,
                },
                // brush uniform
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
            ],
        });

        let blit_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("blit_bgl"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    multisampled: false,
                    view_dimension: wgpu::TextureViewDimension::D2,
                    sample_type: wgpu::TextureSampleType::Float { filterable: false },
                },
                count: None,
            }],
        });

        // Shaders
        let sand_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("sand_update"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../shaders/sand_update.wgsl").into()),
        });

        let brush_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("brush"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../shaders/brush.wgsl").into()),
        });

        let blit_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("blit"),
            source: wgpu::ShaderSource::Wgsl(BLIT_WGSL.into()),
        });

        // Pipeline layouts
        let sand_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("sand_pl"),
            bind_group_layouts: &[&update_bgl],
            immediate_size: 0,
        });

        let brush_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("brush_pl"),
            bind_group_layouts: &[&brush_bgl],
            immediate_size: 0,
        });

        let blit_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("blit_pl"),
            bind_group_layouts: &[&blit_bgl],
            immediate_size: 0,
        });

        // Pipelines
        let sand_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("sand_pipeline"),
            layout: Some(&sand_pl),
            vertex: wgpu::VertexState {
                module: &sand_shader,
                entry_point: Some("vs_fullscreen"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                buffers: &[],
            },
            fragment: Some(wgpu::FragmentState {
                module: &sand_shader,
                entry_point: Some("fs_update"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });

        let brush_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("brush_pipeline"),
            layout: Some(&brush_pl),
            vertex: wgpu::VertexState {
                module: &brush_shader,
                entry_point: Some("vs_fullscreen"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                buffers: &[],
            },
            fragment: Some(wgpu::FragmentState {
                module: &brush_shader,
                entry_point: Some("fs_brush"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });

        let blit_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("blit_pipeline"),
            layout: Some(&blit_pl),
            vertex: wgpu::VertexState {
                module: &blit_shader,
                entry_point: Some("vs"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                buffers: &[],
            },
            fragment: Some(wgpu::FragmentState {
                module: &blit_shader,
                entry_point: Some("fs"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: config.format,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });

        let update_bg_a = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("update_bg_a"),
            layout: &update_bgl,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view_a),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: params_buf.as_entire_binding(),
                },
            ],
        });

        let update_bg_b = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("update_bg_b"),
            layout: &update_bgl,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view_b),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: params_buf.as_entire_binding(),
                },
            ],
        });

        let brush_bg_a = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("brush_bg_a"),
            layout: &brush_bgl,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view_a),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: brush_buf.as_entire_binding(),
                },
            ],
        });

        let brush_bg_b = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("brush_bg_b"),
            layout: &brush_bgl,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view_b),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: brush_buf.as_entire_binding(),
                },
            ],
        });

        let blit_bg_a = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("blit_bg_a"),
            layout: &blit_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(&view_a),
            }],
        });

        let blit_bg_b = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("blit_bg_b"),
            layout: &blit_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(&view_b),
            }],
        });

        Ok(SandEngine {
            surface,
            device,
            queue,
            config,

            sim_a,
            sim_b,
            view_a,
            view_b,

            sand_pipeline,
            brush_pipeline,
            blit_pipeline,

            update_bg_a,
            update_bg_b,
            brush_bg_a,
            brush_bg_b,
            blit_bg_a,
            blit_bg_b,

            params_buf,
            brush_buf,

            front_is_a: true,
            frame_parity: false,
            ground_y,
            brush_color: [0.84, 0.71, 0.38],
        })
    }
}
