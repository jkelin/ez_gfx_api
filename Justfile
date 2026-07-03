set unstable

build: build_example_1

setup:
  git submodule update --init --recursive
  just premake "vendor\odin-vma" "--vk-version=3"

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

example folder_name name: copy_slang_dll
  odin run examples/{{ folder_name }} -keep-executable -out:out/{{ name }}.exe

example_1: (example "1_triangle" "example_1")

example_2: (example "2_textured_cube" "example_2")

example_3: (example "3_compute_structured_buffer" "example_3")

[env("EZ_GFX_MAX_SECONDS", "2")]
[env("EZ_GFX_SCREENSHOT", "1")]
example_agent folder_name name: copy_slang_dll
  odin run examples/{{ folder_name }} -keep-executable -out:out/{{ name }}.exe

example_1_agent: (example_agent "1_triangle" "example_1")

example_2_agent: (example_agent "2_textured_cube" "example_2")

example_3_agent: (example_agent "3_compute_structured_buffer" "example_3")