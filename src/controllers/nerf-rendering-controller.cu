#include <chrono>
#include <memory>
#include <vector>

#include "nerf-rendering-controller.h"
#include "../rendering/render-task-factories/render-task-factory.cuh"
#include "../services/device-manager.cuh"

using namespace std;
using namespace tcnn;

NRC_NAMESPACE_BEGIN

void render_thread_fn(NeRFRenderingController* controller, RenderRequest& request);

NeRFRenderingController::NeRFRenderingController(
    const RenderPattern& pattern,
    const uint32_t& batch_size
) : pattern(pattern) {
    if (batch_size == 0) {
        // TODO: determine batch size from GPU specs
        this->batch_size = 1<<20;
    } else {
        this->batch_size = batch_size;
    }

    for (int i = 0; i < DeviceManager::get_device_count(); ++i) {
        contexts.emplace_back(
            DeviceManager::get_stream(i),
            RenderingWorkspace(i),
            this->batch_size
        );
    }
}

void NeRFRenderingController::cancel() {
    if (request != nullptr)
        request->cancel();

    if (tasks.size() > 0)
        for (auto& task : tasks)
            task.cancel();
}

void NeRFRenderingController::submit(
    std::shared_ptr<RenderRequest> request
) {
    // TODO: batching/chunking/distributing requests across multiple GPUs
    auto& ctx = contexts[0];
    
    this->request = request;

    // split this request into batches
    uint32_t n_rays_per_batch = batch_size / 8;

    unique_ptr<RenderTaskFactory> factory(
        create_render_task_factory(
            pattern,
            n_rays_per_batch,
            batch_size
        )
    );

    this->tasks = factory->create_tasks(request.get());

    // prepare for rendering and dispatch tasks
    renderer.prepare_for_rendering(ctx, request->camera, request->proxies[0]->nerfs[0], n_rays_per_batch);
    
    int i = 0;
    for (auto& task : tasks) {
        renderer.perform_task(ctx, task);
        renderer.write_to_target(ctx, task, request->output);
        request->on_progress((float)i / (float)tasks.size());
        ++i;
    }

    request->on_complete();
}

NRC_NAMESPACE_END
