set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

build:
  $env:PATH = "{{justfile_directory()}}\vendor\odin-slang\slang\bin;" + $env:PATH
  odin build examples/one_triangle -out:ez_gfx_api.exe

test:
  $env:PATH = "{{justfile_directory()}}\vendor\odin-slang\slang\bin;" + $env:PATH
  odin test tests/shader_reflection -define:ODIN_TEST_TRACK_MEMORY=false

run: build
  $env:EZ_GFX_MAX_SECONDS = "2"; $env:EZ_GFX_SCREENSHOT = "1"; $env:PATH = "{{justfile_directory()}}\vendor\odin-slang\slang\bin;" + $env:PATH; .\ez_gfx_api.exe
