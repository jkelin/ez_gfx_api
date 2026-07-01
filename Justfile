set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

build: copy_slang_dll
  odin build examples/one_triangle -out:out\ez_gfx_api.exe

test:
  odin test tests -out:out\ez_gfx_tests_$PID.exe -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1

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
  if (!(Test-Path "out\slang.dll")) { copy vendor\odin-slang\slang\bin\slang.dll out\slang.dll | Out-Null }

run: build 
  .\out\ez_gfx_api.exe

run_agent: build 
  $env:EZ_GFX_MAX_SECONDS = "2"; $env:EZ_GFX_SCREENSHOT = "1"; .\out\ez_gfx_api.exe