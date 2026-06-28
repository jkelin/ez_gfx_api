set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

build:
  $env:PATH = "{{justfile_directory()}}\vendor\odin-slang\slang\bin;" + $env:PATH
  odin build src -out:ez_gfx_api.exe

run: build
  $env:EZ_GFX_MAX_SECONDS = "2"
  $env:EZ_GFX_SCREENSHOT = "1"
  $env:PATH = "{{justfile_directory()}}\vendor\odin-slang\slang\bin;" + $env:PATH
  .\ez_gfx_api.exe
