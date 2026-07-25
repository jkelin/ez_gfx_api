set unstable

build: build_example_1

setup:
  git submodule update --init --recursive
  just apply_vendor_patches
  just premake "vendor\odin-vma" "--vk-version=3"
  just premake "vendor\odin-imgui" "--backends=glfw"

# Applies git-format patches from vendor/patches/<submodule>/*.patch into vendor/<submodule>.
[script]
apply_vendor_patches:
  #!/usr/bin/env bash
  set -euo pipefail
  patches_root="vendor/patches"
  if [[ ! -d "$patches_root" ]]; then
    exit 0
  fi
  for patch_dir in "$patches_root"/*/; do
    [[ -d "$patch_dir" ]] || continue
    submodule="$(basename "$patch_dir")"
    vendor_dir="vendor/$submodule"
    if [[ ! -d "$vendor_dir" ]]; then
      echo "vendor patch target does not exist: vendor/$submodule" >&2
      exit 1
    fi
    while IFS= read -r -d '' patch; do
      patch_name="$(basename "$patch")"
      if git apply --directory="$vendor_dir" --check "$patch" 2>/dev/null; then
        git apply --directory="$vendor_dir" "$patch"
        echo "applied $submodule/$patch_name"
      elif git apply --directory="$vendor_dir" --reverse --check "$patch" 2>/dev/null; then
        echo "already applied $submodule/$patch_name"
      else
        echo "failed to apply vendor patch: $submodule/$patch_name" >&2
        exit 1
      fi
    done < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' -print0 | sort -z)
  done

# Keep system-installed implicit Vulkan overlays out of automated runs.
[env("VK_LOADER_LAYERS_DISABLE", "GalaxyOverlayVkLayer*")]
[env("VK_IMPLICIT_LAYER_PATH", "out")]
[env("EZ_GFX_HIDDEN_WINDOW", "1")]
[env("EZ_GFX_SCREENSHOT", "1")]
test: copy_slang_dll
  odin test tests -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1

[windows]
premake dir args mode='':
    #!cmd.exe /c
    call "%PROGRAMFILES%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    cd {{ dir }}
    premake5 {{ args }} vs2022
    cd build
    ./build.bat {{ mode }}

[script]
[cache(inputs = "vendor/odin-slang/slang/bin/slang.dll", outputs = "out/slang.dll")]
copy_slang_dll:
  cp vendor/odin-slang/slang/bin/slang.dll out/slang.dll

build_example folder_name name: copy_slang_dll
  odin build examples/{{ folder_name }} -out:out/{{ name }}.exe

build_example_1: (build_example "1_triangle" "example_1")

build_example_2: (build_example "2_textured_cube" "example_2")

build_example_3: (build_example "3_compute_structured_buffer" "example_3")

build_example_4: (build_example "4_imgui" "example_4")
build_example_5: (build_example "5_helmet_cgltf" "example_5")

build_example_6: (build_example "6_sponza_ktx2" "example_6")

[env("VK_LOADER_LAYERS_DISABLE", "GalaxyOverlayVkLayer*")]
[env("VK_IMPLICIT_LAYER_PATH", "out")]
example folder_name name: copy_slang_dll
  odin run examples/{{ folder_name }} -keep-executable -out:out/{{ name }}.exe

example_1: (example "1_triangle" "example_1")

example_2: (example "2_textured_cube" "example_2")

example_3: (example "3_compute_structured_buffer" "example_3")

example_4: (example "4_imgui" "example_4")
example_5: (example "5_helmet_cgltf" "example_5")

example_6: (example "6_sponza_ktx2" "example_6")

[env("VK_LOADER_LAYERS_DISABLE", "GalaxyOverlayVkLayer*")]
[env("VK_IMPLICIT_LAYER_PATH", "out")]
[env("EZ_GFX_MAX_SECONDS", "2")]
[env("EZ_GFX_SCREENSHOT", "1")]
example_agent folder_name name: copy_slang_dll
  odin run examples/{{ folder_name }} -keep-executable -out:out/{{ name }}.exe

example_1_agent: (example_agent "1_triangle" "example_1")

example_2_agent: (example_agent "2_textured_cube" "example_2")

example_3_agent: (example_agent "3_compute_structured_buffer" "example_3")

example_4_agent: (example_agent "4_imgui" "example_4")
example_5_agent: (example_agent "5_helmet_cgltf" "example_5")

example_6_agent: (example_agent "6_sponza_ktx2" "example_6")

build-native-dll: copy_slang_dll
  mkdir -p out
  odin build src -build-mode:dll -out:out/ez_gfx_native.dll

verify-native-exports: build-native-dll
  python tools/verify_exports.py --dll out/ez_gfx_native.dll

check-bindings:
  dotnet build csharp/EzGfx.Native/EzGfx.Native.csproj --configuration Release -p:CheckGeneratedBindingArtifact=true

build-csharp:
  dotnet build csharp/EzGfx.sln --configuration Release

native-smoke: verify-native-exports build-csharp
  dotnet run --project csharp/EzGfx.Native.Smoke/EzGfx.Native.Smoke.csproj --configuration Release --no-build

run-odin-examples: copy_slang_dll
  mkdir -p artifacts/odin
  EZ_GFX_MAX_FRAMES=1 EZ_GFX_HIDDEN_WINDOW=1 EZ_GFX_SCREENSHOT=1 odin run examples/1_triangle -keep-executable -out:out/example_1.exe
  cp screenshot.png artifacts/odin/Example01.png
  EZ_GFX_MAX_FRAMES=1 EZ_GFX_HIDDEN_WINDOW=1 EZ_GFX_SCREENSHOT=1 odin run examples/2_textured_cube -keep-executable -out:out/example_2.exe
  cp screenshot.png artifacts/odin/Example02.png
  EZ_GFX_MAX_FRAMES=1 EZ_GFX_HIDDEN_WINDOW=1 EZ_GFX_SCREENSHOT=1 odin run examples/3_compute_structured_buffer -keep-executable -out:out/example_3.exe
  cp screenshot.png artifacts/odin/Example03.png
  EZ_GFX_MAX_FRAMES=1 EZ_GFX_HIDDEN_WINDOW=1 EZ_GFX_SCREENSHOT=1 odin run examples/4_imgui -keep-executable -out:out/example_4.exe
  cp screenshot.png artifacts/odin/Example04.png
  EZ_GFX_MAX_FRAMES=1 EZ_GFX_HIDDEN_WINDOW=1 EZ_GFX_SCREENSHOT=1 odin run examples/5_helmet_cgltf -keep-executable -out:out/example_5.exe
  cp screenshot.png artifacts/odin/Example05.png
  EZ_GFX_MAX_FRAMES=1 EZ_GFX_HIDDEN_WINDOW=1 EZ_GFX_SCREENSHOT=1 odin run examples/6_sponza_ktx2 -keep-executable -out:out/example_6.exe
  cp screenshot.png artifacts/odin/Example06.png

run-csharp-examples: verify-native-exports build-csharp
  mkdir -p artifacts/csharp
  dotnet run --project csharp/EzGfx.Examples/EzGfx.Examples.csproj --configuration Release --no-build -- --example 1 --frames 1 --screenshot artifacts/csharp/Example01.png
  dotnet run --project csharp/EzGfx.Examples/EzGfx.Examples.csproj --configuration Release --no-build -- --example 2 --frames 1 --screenshot artifacts/csharp/Example02.png
  dotnet run --project csharp/EzGfx.Examples/EzGfx.Examples.csproj --configuration Release --no-build -- --example 3 --frames 1 --screenshot artifacts/csharp/Example03.png
  dotnet run --project csharp/EzGfx.Examples/EzGfx.Examples.csproj --configuration Release --no-build -- --example 4 --frames 1 --screenshot artifacts/csharp/Example04.png
  dotnet run --project csharp/EzGfx.Examples/EzGfx.Examples.csproj --configuration Release --no-build -- --example 5 --frames 1 --screenshot artifacts/csharp/Example05.png
  dotnet run --project csharp/EzGfx.Examples/EzGfx.Examples.csproj --configuration Release --no-build -- --example 6 --frames 1 --screenshot artifacts/csharp/Example06.png

compare-csharp-examples: run-odin-examples run-csharp-examples
  python tools/compare_images.py --reference artifacts/odin/Example01.png --candidate artifacts/csharp/Example01.png --max-diff 0 --max-changed-pixels 0
  python tools/compare_images.py --reference artifacts/odin/Example02.png --candidate artifacts/csharp/Example02.png --max-diff 0 --max-changed-pixels 0
  python tools/compare_images.py --reference artifacts/odin/Example03.png --candidate artifacts/csharp/Example03.png --max-diff 0 --max-changed-pixels 0
  python tools/compare_images.py --reference artifacts/odin/Example04.png --candidate artifacts/csharp/Example04.png --max-diff 0 --max-changed-pixels 0
  python tools/compare_images.py --reference artifacts/odin/Example05.png --candidate artifacts/csharp/Example05.png --max-diff 0 --max-changed-pixels 0
  python tools/compare_images.py --reference artifacts/odin/Example06.png --candidate artifacts/csharp/Example06.png --max-diff 0 --max-changed-pixels 0
