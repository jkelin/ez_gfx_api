set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

build: copy_slang_dll
  odin build examples/one_triangle -out:out\ez_gfx_api.exe

test:
  odin test tests -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1

copy_slang_dll:
  copy vendor\odin-slang\slang\bin\slang.dll out\slang.dll

run: build 
  $env:EZ_GFX_MAX_SECONDS = "2"; $env:EZ_GFX_SCREENSHOT = "1"; .\out\ez_gfx_api.exe
