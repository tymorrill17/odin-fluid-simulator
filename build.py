#!/usr/bin/env python

import argparse
import platform
import shutil
import subprocess
import sys
import json
from pathlib import Path

# Odin Config
EXE_NAME            = "run"         # name of the final executable (no extension)
BIN_DIR             = "bin"         # name of the final executable (no extension)
SRC_DIR             = "src"         # folder passed to `odin build`
THIRDPARTY_DIR      = "thirdparty"  # folder containing git-cloned libraries
SHADER_DIR          = "shaders"     # folder containing all shader files
CACHE_DIR           = ".cache"
CAPTURE_DIR         = "captures"    # folder containing screenshot or video captures
ASSET_DIR           = "assets"      # folder containing model and texture assets
EXTRA_BUILD_ARGS    = []            # any extra flags you always want, e.g. ["-vet"]
EXTRA_LINKER_FLAGS  = "-lstdc++"    # input to odin's "extra-linker-flags" build arg

# Shader Config
SHADER_COMPILER     = "slangc"      # which shader compiler to use
SHADER_BIN_DIR      = "spirv"
SHADER_SRC_EXT      = ".slang"
SHADER_TARGET       = "spirv"
SHADER_PROFILE      = "spirv_1_6"
SHADER_EXTRA_ARGS   = ["-fvk-use-entrypoint-name", "-matrix-layout-column-major"]

# Optional Tools Config
OPTIONAL_TOOLS      = { "ffmpeg": "video recording" }

PROJECT_DIR         = Path(__file__).resolve().parent # Get the project root

shader_path         = PROJECT_DIR / SHADER_DIR
bin_path            = PROJECT_DIR / BIN_DIR
shader_bin_path     = bin_path / SHADER_BIN_DIR
exe_path            = bin_path / (EXE_NAME if platform.system() != "Windows" else EXE_NAME + ".exe")
thirdparty_path     = PROJECT_DIR / THIRDPARTY_DIR
cache_path          = PROJECT_DIR / CACHE_DIR
capture_path        = PROJECT_DIR / CAPTURE_DIR
asset_path          = PROJECT_DIR / ASSET_DIR


def clean():
    # Iterate recursively through all files in bin and delete them
    for file in bin_path.rglob("*"):
        if file.is_file():
            file.unlink()
            print(f"Removed {file}.")


def generate_ols_json(debug):
    match platform.system():
        case "Windows":
            os_name = "windows"
        case "Linux":
            os_name = "linux"
        case _:
            os_name = "darwin"

    ols_json = {
        "$schema": "https://raw.githubusercontent.com/DanielGavin/ols/master/misc/ols.schema.json",
        "enable_semantic_tokens": False,
        "enable_document_symbols": True,
        "enable_hover": True,
        "enable_snippets": True,
        "enable_auto_import": False,
        "profile": "default",
        "profiles": [ { "name": "default", "os": os_name, "checker_path": ["src"], "defines": { "ODIN_DEBUG": ("true" if debug else "false") } } ],
        "collections": [ { "name": "thirdparty", "path": str(thirdparty_path) } ]
    }
    with open(PROJECT_DIR / 'ols.json', 'w', encoding='utf-8') as file:
        json.dump(ols_json, file, indent=4)
    print("Generated ols.json")


def install_dependencies():
    # TODO
    return

def check_optional_tools():
    for tool, feature in OPTIONAL_TOOLS.items():
        if shutil.which(tool) is None:
            print(f"warning: could not find '{tool}' in PATH, {feature} will not work.")


def compile_shaders(debug):
    slangc_path = shutil.which(SHADER_COMPILER)
    if slangc_path is None:
        print(f"error: could not find '{SHADER_COMPILER}' in PATH.")
        sys.exit(-1)

    # sort found shaders so they compile in the same order each time
    for shader_src in sorted(shader_path.rglob(f"*{SHADER_SRC_EXT}")):
        shader_out = shader_bin_path / (shader_src.name + ".spv")

        # Skip recompiling if the output is newer than the source
        if shader_out.exists() and shader_out.stat().st_mtime >= shader_src.stat().st_mtime:
            continue

        cmd = [
            slangc_path,
            str(shader_src),
            "-target", SHADER_TARGET,
            "-profile", SHADER_PROFILE,
        ]
        # Note, make sure to clean between release and debug builds since not all shaders may be compiled
        if debug:
            cmd += ["-g"]
        cmd += SHADER_EXTRA_ARGS
        cmd += ["-o", str(shader_out)]

        print(" ".join(cmd))
        result = subprocess.run(cmd, cwd=PROJECT_DIR)
        if result.returncode != 0:
            sys.exit(result.returncode)
        print(f"Compiled {shader_src.relative_to(PROJECT_DIR)} -> {shader_out.relative_to(PROJECT_DIR)}")
    return


def compile_project(debug):
    odin_path = shutil.which("odin")
    if odin_path is None:
        print("error: could not find 'odin' in PATH.")
        sys.exit(-1)

    cmd = [
        odin_path,
        "build",
        str(PROJECT_DIR / SRC_DIR),
        f"-out:{exe_path}",
    ]
    if not thirdparty_path.is_dir():
        print("error: third-party dependency directory not found!")
        sys.exit(-1)
    cmd += [f"-collection:thirdparty={thirdparty_path}"]
    if debug:
        cmd += ["-debug"]
    else: # release mode
        cmd += ["-o:speed"]

    # Define constants here
    cmd += [
        f"-define:SHADER_DIR={shader_path}",
        f"-define:SHADER_BIN_DIR={shader_bin_path}",
        f"-define:CACHE_DIR={cache_path}",
        f"-define:CAPTURE_DIR={capture_path}",
        f"-define:ASSET_DIR={asset_path}",
    ]

    # Extra linker flags
    cmd += [f"-extra-linker-flags:{EXTRA_LINKER_FLAGS}"]

    cmd += EXTRA_BUILD_ARGS

    print(" ".join(cmd))
    result = subprocess.run(cmd, cwd=PROJECT_DIR)
    if result.returncode != 0:
        sys.exit(result.returncode)
    print(f"Built {exe_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Odin project build script")
    parser.add_argument("-d", "--debug",        action="store_true", help="build in debug mode")
    parser.add_argument("-r", "--run",          action="store_true", help="run the executable after building")
    parser.add_argument("-c", "--cleanbuild",   action="store_true", help="remove the built executable")
    parser.add_argument("--clean",              action="store_true", help="create thirdparty dependency directory and install dependencies")
    parser.add_argument("--install-thirdparty", action="store_true", help="create thirdparty dependency directory and install dependencies")
    parser.add_argument("--generate-ols-json",  action="store_true", help="generate ols.json file using the ")
    parser.add_argument("--shaders-only",       action="store_true", help="only perform shader compilation")
    args = parser.parse_args()

    if not shader_path.exists():
        shader_path.mkdir()
    if not bin_path.exists():
        bin_path.mkdir()
    if not thirdparty_path.exists():
        thirdparty_path.mkdir()
    if not shader_bin_path.exists():
        shader_bin_path.mkdir()
    if not cache_path.exists():
        cache_path.mkdir()
    if not capture_path.exists():
        capture_path.mkdir()

    # clean only, don't build
    if args.clean:
        clean()
        sys.exit(0)

    # clean before building
    if args.cleanbuild:
        clean()

    # Install third-party dependencies
    if args.install_thirdparty:
        install_dependencies()

    # Generate new ols.json
    if args.generate_ols_json:
        generate_ols_json(args.debug)
        sys.exit(0)

    # Warn about missing non-essential tools, but keep building
    check_optional_tools()

    # Compile shaders
    compile_shaders(args.debug)
    if (args.shaders_only):
        sys.exit(0)

    # Build the project
    compile_project(args.debug)

    # Run the code after building
    if args.run:
        print(f"Running {exe_path}...\n")
        subprocess.run([str(exe_path)], cwd=PROJECT_DIR)

    return 0


if __name__ == "__main__":
    sys.exit(main())
