#include "../../models/camera.cuh"
#include "../../models/ray.h"
#include "../../models/ray-batch.cuh"
#include "../../utils/device-math.cuh"
#include "../../common.h"
#include "rectangular-grid-ray-batch-coordinator.cuh"

using namespace tcnn;

NRC_NAMESPACE_BEGIN

__global__ void generate_rectangular_grid_of_rays_kernel(
    const int n_rays,
    const int stride,
    const int2 grid_offset, // offset in camera-space pixels of the grid's origin
    const int2 grid_size, // size in camera-space pixels of the grid's extent
    const int2 grid_resolution, // resolution (number of samples) across the grid
    const Camera* __restrict__ camera,
    const BoundingBox* __restrict__ bbox,
    float* __restrict__ pos,
    float* __restrict__ dir,
    float* __restrict__ idir,
    float* __restrict__ t,
    int* __restrict__ index,
    bool* __restrict__ alive
) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;

    if (i >= n_rays) {
        return;
    }

    int iy = divide(i, grid_resolution.x);  // (i / grid_resolution.x)
    int ix = i - iy * grid_resolution.x;    // (i % grid_resolution.x) 

    // calculate x and y in grid space
    float x = (float)grid_size.x * (float)ix / (float)grid_resolution.x;
    float y = (float)grid_size.y * (float)iy / (float)grid_resolution.y;

    // normalize to camera space
    const Camera cam = *camera;
    
    x = ((float)grid_offset.x + x) / (float)cam.resolution.x;
    y = ((float)grid_offset.y + y) / (float)cam.resolution.y;

    Ray local_ray = cam.local_ray_at_pixel_xy_normalized(x, y);
    Ray global_ray = cam.global_ray_from_local_ray(local_ray);

    fill_ray_buffers(i, stride, global_ray, bbox, pos, dir, idir, t, index, alive);
}

void RectangularGridRayBatchCoordinator::generate_rays(
    const Camera* camera,
    const BoundingBox* bbox,
    RayBatch& ray_batch,
    const cudaStream_t& stream
) {
    generate_rectangular_grid_of_rays_kernel<<<n_blocks_linear(ray_batch.size), n_threads_linear, 0, stream>>>(
        ray_batch.size,
        ray_batch.stride,
        grid_offset,
        grid_size,
        grid_resolution,
        camera,
        bbox,
        ray_batch.pos,
        ray_batch.dir,
        ray_batch.idir,
        ray_batch.t,
        ray_batch.index,
        ray_batch.alive
    );
}

__global__ void copy_packed_rgba_rectangular_grid_kernel(
    const int n_grid_pixels,
    const int stride,
    const int output_width,
    const int2 grid_offset,
    const int2 grid_size,
    const int2 grid_resolution,
    const float* __restrict__ rgba_in,
    float* __restrict__ rgba_out
) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;

    if (i >= n_grid_pixels) {
        return;
    }

    // calculate x and y in local grid space (output pixel)
    int ox = i % grid_size.x;
    int oy = divide(i, grid_size.x);

    // get the corresponding buffer index (input pixel)
    const int ix = divide(ox * grid_resolution.x, grid_size.x);
    const int iy = divide(oy * grid_resolution.y, grid_size.y);

    int i_in = ix + iy * grid_resolution.x;

    // calculate index in output buffer
    ox += grid_offset.x;
    oy += grid_offset.y;

    int i_out = 4 * (ox + oy * output_width);

    // copy packed pixels to output
    #pragma unroll
    for (int j = 0; j < 4; ++j) {
        rgba_out[i_out] = rgba_in[i_in];
        i_out += 1;
        i_in += stride;
    }
}

void RectangularGridRayBatchCoordinator::copy_packed(
    const int& n_rays,
    const int2& output_size,
    const int& output_stride,
    float* rgba_in,
    float* rgba_out,
    const cudaStream_t& stream
) {
    const int n_output_pixels = output_size.x * output_size.y;
    copy_packed_rgba_rectangular_grid_kernel<<<n_blocks_linear(n_output_pixels), n_threads_linear, 0, stream>>>(
        n_output_pixels,
        output_stride,
        output_size.x,
        grid_offset,
        grid_size,
        grid_resolution,
        rgba_in,
        rgba_out
    );
}

NRC_NAMESPACE_END
