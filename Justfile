set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

build: build_example_1

build_example_1: copy_slang_dll
  odin build examples/1_triangle -out:out\example_1.exe

build_example_2: copy_slang_dll
  odin build examples/2_textured_cube -out:out\example_2.exe

build_example_3: copy_slang_dll
  odin build examples/3_compute_structured_buffer -out:out\example_3.exe

test: copy_slang_dll
  odin test tests -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1

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

example_3: build_example_3
  .\out\example_3.exe

example_1_agent: build_example_1
  $env:EZ_GFX_MAX_SECONDS = "2"; $env:EZ_GFX_SCREENSHOT = "1"; .\out\example_1.exe

example_2_agent: build_example_2
  $env:EZ_GFX_MAX_SECONDS = "2"; $env:EZ_GFX_SCREENSHOT = "1"; .\out\example_2.exe

example_3_agent: build_example_3
  $env:EZ_GFX_MAX_SECONDS = "2"; $env:EZ_GFX_SCREENSHOT = "1"; .\out\example_3.exe