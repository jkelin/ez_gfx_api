set unstable

build: build_example_1

setup:
  git submodule update --init --recursive
  just apply_vendor_patches
  just premake "vendor\odin-vma" "--vk-version=3"

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

build_example_5: (build_example "5_helmet_cgltf" "example_5")

example folder_name name: copy_slang_dll
  odin run examples/{{ folder_name }} -keep-executable -out:out/{{ name }}.exe

example_1: (example "1_triangle" "example_1")

example_2: (example "2_textured_cube" "example_2")

example_3: (example "3_compute_structured_buffer" "example_3")

example_5: (example "5_helmet_cgltf" "example_5")

[env("EZ_GFX_MAX_SECONDS", "2")]
[env("EZ_GFX_SCREENSHOT", "1")]
example_agent folder_name name: copy_slang_dll
  odin run examples/{{ folder_name }} -keep-executable -out:out/{{ name }}.exe

example_1_agent: (example_agent "1_triangle" "example_1")

example_2_agent: (example_agent "2_textured_cube" "example_2")

example_3_agent: (example_agent "3_compute_structured_buffer" "example_3")

example_5_agent: (example_agent "5_helmet_cgltf" "example_5")