# Context

## Glossary

- `Render graph`: A frame-local ordering of rendering work and the render targets that connect that work.
- `Pipeline node`: One user-added vertex pipeline in a render graph.
- `Resource edge`: A shared render target relationship between pipeline nodes.
- `Present node`: The final render graph step that hands the completed swapchain image to presentation.
- `Managed render target`: A shader-declared render target owned by the graphics API rather than by application code.
