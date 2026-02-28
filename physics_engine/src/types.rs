#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub(crate) struct Params {
    pub(crate) ground_y: f32,
    pub(crate) pass_type: i32,
    pub(crate) diag_dx: i32,
    pub(crate) _pad: i32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub(crate) struct Brush {
    pub(crate) center: [f32; 2],
    pub(crate) radius: f32,
    pub(crate) add: f32,
    pub(crate) color: [f32; 3],
    pub(crate) _pad: f32,
}
