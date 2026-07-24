# WebGPU/WASM Portability Assessment

## Goal

Determine whether the README's core graphics pillars can be carried to browser WebGPU through an Odin `js_wasm32` target without silently promising Vulkan semantics that WebGPU does not provide.

## Decision

**Recommendation: subset port.**

Implement a capability-limited WebGPU backend and browser runtime rather than attempting feature-for-feature parity. A native WebGPU backend can be implemented first to isolate backend semantics, followed by a browser profile with explicit fallbacks. Do not call the subset Vulkan-compatible or preserve the current MDI/bindless guarantees when those capabilities are unavailable.

## Go/No-Go Matrix

| README pillar | Current implementation | Browser WebGPU/WASM assessment | Decision |
| --- | --- | --- | --- |
| **Bindless texture heap** | `texture_manager.odin` builds a large Vulkan descriptor array with partially-bound and update-after-bind behavior. Shaders index the heap by texture ID. | WebGPU's portable baseline does not provide the same dynamically indexed, partially populated descriptor heap. Binding arrays and bindless-like features are implementation-dependent and cannot be the browser floor. | **Rewrite required; degrade** to texture arrays, atlases, material bind groups, or bounded bindings. |
| **Bindless vertex/index heaps** | Vertex and index resources are managed as Vulkan buffers and exposed through shader/resource binding conventions. Allocation, mapping, staging, and descriptor binding are Vulkan-specific. | Storage-buffer indirection can preserve the conceptual heap. Direct use as a Vulkan-style descriptor/device-local heap cannot. Indexed drawing also still requires WebGPU-compatible vertex/index bindings. | **Concept preserved; backend rewrite required** with bounded storage-buffer/resource layouts and explicit capability checks. |
| **MDI-only dispatch** | The render path uses Vulkan indirect-count drawing so compute can generate both commands and the draw count. | WebGPU core supports indirect drawing but not the current GPU-generated indirect-count contract. Browser multi-draw-indirect-count support is experimental and unsuitable as the default. | **Rewrite required; degrade** to CPU-encoded individual indirect draws, a fixed maximum command count, or a new batching model. |
| **Shader-declared render graph** | Slang declarations drive target discovery, pipeline metadata, image views, Vulkan layouts, barriers, descriptor updates, and command recording. | The declaration model is portable, but image layouts, pipeline barriers, queue ownership, attachment views, descriptor sets, and per-node Vulkan submissions are not. | **Preserve the API concept; rewrite execution backend** as ordered WebGPU copy/compute/render passes with usage validation. |
| **Slang reflection and shader pipeline** | Slang is compiled to SPIR-V and reflected into Vulkan pipeline and descriptor metadata; the runtime currently depends on the native Slang library. | Browser WebGPU consumes WGSL. Slang documents a WGSL target, but marks WebGPU support as work in progress. The native Slang DLL and Vulkan annotations cannot ship unchanged in WASM. | **Rewrite required**: offline or WASM Slang-to-WGSL compilation, WGSL metadata generation, and WebGPU pipeline layouts. |

## Required Subset Contract

The browser profile should explicitly expose these limitations:

- No guarantee of a 1024-entry bindless texture heap.
- No guarantee of GPU-generated variable draw counts.
- No Vulkan push constants; use uniform or storage buffers.
- One WebGPU queue rather than transfer queues and timeline semaphores.
- No explicit image-layout or pipeline-barrier API.
- WGSL shader output and WebGPU-compatible reflection metadata.
- Canvas-based presentation with asynchronous adapter/device initialization.
- Fetchable/bundled assets instead of native filesystem paths.
- Browser-compatible input, texture decoding, worker usage, and screenshot readback.

## Implementation Boundary

The first implementation phase should separate backend-neutral declarations from Vulkan execution:

1. Replace public Vulkan resource types with backend-neutral handles and descriptions.
2. Add a capability record covering bindless textures, indirect-count drawing, push constants, storage-texture access, and format support.
3. Keep shader-declared target metadata and render-graph dependency ordering independent of Vulkan image layouts and access masks.
4. Implement a native WebGPU backend using the Odin WebGPU bindings to exercise the new resource and command contracts.
5. Add the browser/WASM profile with WGSL shaders, canvas presentation, async asset loading, and the fallbacks above.

## Non-Goals

- Do not promise unchanged Vulkan performance characteristics.
- Do not make experimental browser extensions mandatory for the default profile.
- Do not mechanically translate `vk.*` types or retain Vulkan descriptor/pipeline semantics behind aliases.
- Do not port native GLFW, VMA, timeline-semaphore, or native Slang-DLL assumptions into the browser target.

## Sources

- [Odin WebGPU bindings](https://pkg.odin-lang.org/vendor/wgpu/)
- [WebGPU specification](https://gpuweb.github.io/gpuweb/)
- [Chrome: What's New in WebGPU 131](https://developer.chrome.com/blog/new-in-webgpu-131)
- [Chrome: What's next for WebGPU](https://developer.chrome.com/blog/next-for-webgpu)
- [Slang supported compilation targets](https://shader-slang.org/slang/user-guide/targets)
