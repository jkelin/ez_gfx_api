set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

build: build_example_1

build_example_1: copy_slang_dll
  odin build examples/1_triangle -out:out\example_1.exe

build_example_2: copy_slang_dll
  odin build examples/2_textured_cube -out:out\example_2.exe

test: copy_slang_dll
  $env:VK_INSTANCE_LAYERS = ""; $env:VK_LOADER_LAYERS_DISABLE = "*"; odin test tests -out:out\ez_gfx_tests_cpu_$PID.exe -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=valid_targets_reflects_metadata,multiple_color_targets_reflects_metadata,color_history_read_reflects_metadata,managed_rwtexture_reflects_as_target_declaration,load_target_reflects_metadata,invalid_load_target_fails_reflection,missing_declaration_fails_reflection,duplicate_target_declarations_are_rejected,invalid_access_fails_reflection,invalid_scale_fails_reflection,missing_scale_fails_reflection,swapchain_read_fails_reflection,color_feedback_loop_fails_reflection,color_depth_mismatch_fails_reflection,unsupported_set_fails_reflection,shader_path_resolves_from_parent_directory,vertex_allocator_reuses_first_fitting_chunk_and_splits_remainder,vertex_allocator_merges_adjacent_free_chunks,vertex_allocator_recovers_capacity_after_free,texture_full_mip_count_halves_to_one_pixel,texture_decode_raw_rgb_expands_alpha,texture_decode_raw_rgba_preserves_alpha,texture_decode_raw_rejects_wrong_byte_count,texture_manager_allocates_and_finds_id_slots,timeline_values_are_monotonic,present_mode_selector_uses_requested_mode_when_supported,present_mode_selector_falls_back_to_fifo_when_unsupported
  $env:VK_INSTANCE_LAYERS = ""; $env:VK_LOADER_LAYERS_DISABLE = "*"; odin test tests -out:out\ez_gfx_tests_snapshots_$PID.exe -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=triangle_renders_without_validation_errors,cube_renders_without_validation_errors,load_target_preserves_previous_frame_without_validation_errors,managed_rwtexture_store_load_matches_snapshot
  $env:VK_INSTANCE_LAYERS = ""; $env:VK_LOADER_LAYERS_DISABLE = "*"; odin test tests -out:out\ez_gfx_tests_gpu_$PID.exe -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=cube_shader_reflects_push_constant_size,cube_push_constant_size_mismatch_fails_cleanly,present_modes_can_be_queried_and_changed,resize_after_screenshot_recreates_without_validation_errors,render_target_fork_join_synchronizes_without_validation_errors

setup:
  just premake "vendor\odin-vma" "--vk-version=3"

[windows]
premake dir args mode='':
    #!cmd.exe /c
    call "%PROGRAMFILES%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    cd {{ dir }}
    premake5 {{ args }} vs2022
    cd build
    ./build.bat {{ mode }}

copy_slang_dll:
  New-Item -ItemType Directory -Force out | Out-Null
  if ((Test-Path "vendor\odin-slang\slang\bin\slang.dll") -and !(Test-Path "out\slang.dll")) { copy vendor\odin-slang\slang\bin\slang.dll out\slang.dll | Out-Null }

example_1: build_example_1
  .\out\example_1.exe

example_2: build_example_2
  .\out\example_2.exe

example_1_agent: build_example_1
  $env:EZ_GFX_MAX_SECONDS = "2"; $env:EZ_GFX_SCREENSHOT = "1"; .\out\example_1.exe

example_2_agent: build_example_2
  $env:EZ_GFX_MAX_SECONDS = "2"; $env:EZ_GFX_SCREENSHOT = "1"; .\out\example_2.exe