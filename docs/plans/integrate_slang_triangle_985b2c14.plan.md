---
name: Integrate Slang Triangle
overview: Add odin-slang as a vendored submodule dependency, compile a two-stage Slang shader at startup, create a Vulkan graphics pipeline for dynamic rendering, and render an indexed red triangle through the existing frame loop.
todos:
  - id: add-odin-slang
    content: Add odin-slang as a submodule under vendor/odin-slang and update Justfile for collection and DLL setup.
    status: completed
  - id: add-slang-shader
    content: Create shaders/triangle.slang with hardcoded vertex positions and a red fragment output.
    status: completed
  - id: add-compiler-wrapper
    content: Create src/shader.odin to compile the Slang module to SPIR-V and create Vulkan shader modules.
    status: completed
  - id: add-buffer-pipeline
    content: Create src/buffer.odin and src/pipeline.odin for index buffer allocation/upload and dynamic-rendering pipeline creation.
    status: completed
  - id: wire-render-loop
    content: Extend context lifecycle and record indexed triangle draw commands in main.odin.
    status: completed
  - id: verify-run
    content: Run just run and fix any compile/runtime issues until the triangle renders.
    status: completed
isProject: false
---

# Integrate Slang Triangle

## Scope

- Add `https://github.com/DragosPopse/odin-slang` as `vendor/odin-slang` and update `Justfile` so `just run` passes the Slang package collection and makes `slang.dll` available on Windows.
- Add `shaders/triangle.slang` with two entry points:
  - `vertexmain`: uses `SV_VertexID` from the index buffer to select one of three hardcoded positions.
  - `fragmentmain`: writes a constant red `float4` to `vk_location(0)`.
- Add `src/shader.odin` as the Slang compiler wrapper. It will mirror the upstream example: `createGlobalSession`, `TargetDesc{format = .SPIRV, flags = {.GENERATE_SPIRV_DIRECTLY}}`, `VulkanUseEntryPointName`, `loadModule`, `findEntryPointByName`, `createCompositeComponentType`, and `getTargetCode`.
- Add focused Vulkan helpers:
  - `src/buffer.odin` for an `Ez_Gfx_Buffer`, memory-type lookup, host-visible upload, and destroy helpers.
  - `src/pipeline.odin` for shader module creation, empty pipeline layout, dynamic-rendering graphics pipeline creation, and destruction.
- Extend `Ez_Gfx_Ctx` in `src/ctx.odin` to own the Slang global session, triangle index buffer, pipeline layout, and pipeline. Cleanup will destroy GPU resources before the device and release the Slang session.
- Replace the empty dynamic-rendering block in `src/main.odin` with viewport/scissor setup, `CmdBindPipeline`, `CmdBindIndexBuffer`, and `CmdDrawIndexed(3, 1, 0, 0, 0)`, while preserving the existing swapchain acquire/present and image layout transitions.

## Key Design Choices

- Use a dynamic viewport and scissor so the graphics pipeline does not need to be recreated just because the swapchain extent changes.
- Use a `u32` index buffer containing `{0, 1, 2}` because the shader owns the three vertex positions; no vertex buffer is needed for this specific request.
- Keep Slang compilation startup-only for the first pass. Hot reload is supported by the upstream example, but it would add more lifecycle complexity than the requested triangle render needs.
- Keep the module boundaries narrow: Slang compilation in `shader.odin`, Vulkan buffer mechanics in `buffer.odin`, and pipeline creation in `pipeline.odin`.

## Verification

- Run `just run` from the repository root and confirm a red triangle appears in the existing window.
- If the first run fails to load `slang.dll`, adjust the `Justfile` to copy `vendor/odin-slang/slang/bin/slang.dll` to the executable/runtime location or prepend that folder to `PATH` for the recipe.
- Fix any Odin compile errors and Vulkan setup errors rather than disabling tests or skipping verification.
