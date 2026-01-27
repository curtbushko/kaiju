{
  description = "Timber-git Go flake";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      goVersion = 25; # Change this to update the whole stack

      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forEachSupportedSystem = f: nixpkgs.lib.genAttrs supportedSystems (system: f {
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
      });
    in
    {
      overlays.default = final: prev: {
        go = final."go_1_${toString goVersion}";

        # Custom soloud package built from source
        soloud = final.stdenv.mkDerivation {
          pname = "soloud";
          version = "unstable-2024-12-31";

          src = final.fetchFromGitHub {
            owner = "jarikomppa";
            repo = "soloud";
            rev = "e82fd32c1f62183922f08c14c814a02b58db1873";
            sha256 = "sha256-HZE/fNUGMFC/pzHhcj4k5ygzuCznbZTOCUeInUczvMU=";
          };

          nativeBuildInputs = [ final.cmake ];

          buildInputs = if final.stdenv.isLinux then [ final.alsa-lib ]
                        else if final.stdenv.isDarwin then [ final.darwin.apple_sdk.frameworks.CoreAudio ]
                        else [];

          sourceRoot = "source/contrib";

          cmakeFlags = [
            "-DSOLOUD_BACKEND_SDL2=OFF"
            "-DSOLOUD_C_API=ON"
            "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
          ] ++ (if final.stdenv.isLinux then [
            "-DSOLOUD_BACKEND_ALSA=ON"
          ] else if final.stdenv.isDarwin then [
            "-DSOLOUD_BACKEND_COREAUDIO=ON"
          ] else [
            "-DSOLOUD_BACKEND_WASAPI=ON"
          ]);

          postInstall = ''
            mkdir -p $out/lib/pkgconfig
            cat > $out/lib/pkgconfig/soloud.pc << EOF
prefix=$out
exec_prefix=\''${prefix}
libdir=\''${exec_prefix}/lib
includedir=\''${prefix}/include

Name: SoLoud
Description: Easy to use, free, portable audio library
Version: ${final.soloud.version}
Libs: -L\''${libdir} -lsoloud -lstdc++${if final.stdenv.isLinux then " -lasound" else if final.stdenv.isDarwin then " -framework AudioToolbox -framework CoreAudio" else " -lwinmm -lole32 -luuid"}
Cflags: -I\''${includedir}
EOF
          '';

          meta = with final.lib; {
            description = "Easy to use, free, portable audio library";
            homepage = "https://github.com/jarikomppa/soloud";
            license = licenses.zlib;
            platforms = platforms.all;
          };
        };
      };

      devShells = forEachSupportedSystem ({ pkgs }: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            # Common packages for all platforms
            cobra-cli
            go # version is specified by overlay
            gotools
            golangci-lint
            cmake
            git
            pkg-config

            # Game engine dependencies
            bullet
            soloud
            vulkan-loader
            vulkan-headers
            vulkan-validation-layers
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            # Linux-specific packages
            pkgs.gcc
            pkgs.gnumake
            # X11 libraries required for windowing
            pkgs.xorg.libX11
            pkgs.xorg.libXrandr
            pkgs.xorg.libXcursor
            pkgs.xorg.libXi
            pkgs.xorg.libXinerama
            # Mesa for Vulkan drivers
            pkgs.mesa
            pkgs.mesa.drivers
            # Vulkan tools for debugging
            pkgs.vulkan-tools
            # Linux-specific audio (ALSA for soloud)
            pkgs.alsa-lib
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
            # macOS-specific packages
            # Xcode Command Line Tools (xcode-select --install) required

          ]
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows [
            # Windows-specific packages
            # mingw-w64 required (see docs/engine_developers/build_from_source.md)

          ];

          shellHook = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
            # Set up Vulkan library paths for runtime
            export LD_LIBRARY_PATH="${pkgs.vulkan-loader}/lib:${pkgs.vulkan-validation-layers}/lib:${pkgs.mesa.drivers}/lib:${pkgs.lib.makeLibraryPath [ pkgs.xorg.libX11 pkgs.xorg.libXrandr pkgs.xorg.libXcursor pkgs.xorg.libXi pkgs.xorg.libXinerama pkgs.mesa ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

            # Point to Vulkan validation layers for debugging
            export VK_LAYER_PATH="${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d"

            # Set up Vulkan ICD files (find all Mesa drivers)
            mesa_icds=$(find "${pkgs.mesa.drivers}/share/vulkan/icd.d" -name "*_icd.x86_64.json" 2>/dev/null | tr '\n' ':')
            export VK_ICD_FILENAMES="''${mesa_icds%:}"

            # Also check for system drivers (NVIDIA, etc)
            if [ -d /usr/share/vulkan/icd.d ]; then
              system_icds=$(find /usr/share/vulkan/icd.d -name "*_icd*.json" 2>/dev/null | tr '\n' ':')
              if [ -n "$system_icds" ]; then
                export VK_ICD_FILENAMES="$VK_ICD_FILENAMES:''${system_icds%:}"
              fi
            fi

            # Check for NixOS-style opengl driver paths
            if [ -d /run/opengl-driver/share/vulkan/icd.d ]; then
              nixos_icds=$(find /run/opengl-driver/share/vulkan/icd.d -name "*_icd*.json" 2>/dev/null | tr '\n' ':')
              if [ -n "$nixos_icds" ]; then
                export VK_ICD_FILENAMES="$VK_ICD_FILENAMES:''${nixos_icds%:}"
              fi
            fi

            echo "Vulkan ICD files: $VK_ICD_FILENAMES"
          '';
        };
      });
    };
}
