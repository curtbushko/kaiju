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

        # Custom bullet3 package built with static libraries
        bullet-static = final.stdenv.mkDerivation {
          pname = "bullet-static";
          version = "3.25";

          src = final.fetchFromGitHub {
            owner = "bulletphysics";
            repo = "bullet3";
            rev = "3.25";
            sha256 = "sha256-AGP05GoxLjHqlnW63/KkZe+TjO3IKcgBi+Qb/osQuCM=";
          };

          nativeBuildInputs = [ final.cmake ];

          cmakeFlags = [
            "-DCMAKE_BUILD_TYPE=Release"
            "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
            "-DBUILD_SHARED_LIBS=OFF"
            "-DBUILD_CPU_DEMOS=OFF"
            "-DBUILD_OPENGL3_DEMOS=OFF"
            "-DBUILD_BULLET2_DEMOS=OFF"
            "-DBUILD_EXTRAS=OFF"
            "-DBUILD_UNIT_TESTS=OFF"
            "-DUSE_GLUT=OFF"
            "-DINSTALL_LIBS=ON"
          ];

          meta = with final.lib; {
            description = "Professional 3D collision detection and physics library (static)";
            homepage = "https://github.com/bulletphysics/bullet3";
            license = licenses.zlib;
            platforms = platforms.all;
          };
        };

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
                        else if final.stdenv.isDarwin then [ final.apple-sdk_15 ]
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
            bullet-static
            soloud
          ]
          ++ pkgs.lib.optionals (!pkgs.stdenv.hostPlatform.isDarwin) [
            # Vulkan packages (Linux only - macOS uses MoltenVK via Vulkan SDK)
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
            # Apple SDK provides frameworks (Cocoa, CoreAudio, Metal, etc.) via SDKROOT
            pkgs.apple-sdk_15
            pkgs.darwin.libiconv
            # Vulkan SDK via MoltenVK (Vulkan over Metal translation layer)
            pkgs.moltenvk
            pkgs.vulkan-headers
            pkgs.vulkan-loader
            pkgs.vulkan-tools
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows [
            # Windows-specific packages
            # mingw-w64 required (see docs/engine_developers/build_from_source.md)

          ];

          shellHook = ''
            # Set up src/libs with game engine dependencies
            # Note: We copy instead of symlink because Go's embed doesn't follow
            # symlinks that point outside the module directory
            LIBS_DIR="$PWD/src/libs"
            mkdir -p "$LIBS_DIR"

            # Copy Soloud library (only if changed)
            ${if pkgs.stdenv.hostPlatform.isLinux then ''
            if ! cmp -s "${pkgs.soloud}/lib/libsoloud.a" "$LIBS_DIR/libsoloud_nix.a" 2>/dev/null; then
              cp -f "${pkgs.soloud}/lib/libsoloud.a" "$LIBS_DIR/libsoloud_nix.a"
            fi
            '' else if pkgs.stdenv.hostPlatform.isDarwin then ''
            if ! cmp -s "${pkgs.soloud}/lib/libsoloud.a" "$LIBS_DIR/libsoloud_darwin.a" 2>/dev/null; then
              cp -f "${pkgs.soloud}/lib/libsoloud.a" "$LIBS_DIR/libsoloud_darwin.a"
            fi
            '' else ""}

            # Copy Bullet3 libraries (only if changed)
            ${if pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86_64 then ''
            if ! cmp -s "${pkgs.bullet-static}/lib/libBulletDynamics.a" "$LIBS_DIR/libBulletDynamics_nix_amd64.a" 2>/dev/null; then
              cp -f "${pkgs.bullet-static}/lib/libBulletDynamics.a" "$LIBS_DIR/libBulletDynamics_nix_amd64.a"
            fi
            if ! cmp -s "${pkgs.bullet-static}/lib/libBulletCollision.a" "$LIBS_DIR/libBulletCollision_nix_amd64.a" 2>/dev/null; then
              cp -f "${pkgs.bullet-static}/lib/libBulletCollision.a" "$LIBS_DIR/libBulletCollision_nix_amd64.a"
            fi
            if ! cmp -s "${pkgs.bullet-static}/lib/libLinearMath.a" "$LIBS_DIR/libLinearMath_nix_amd64.a" 2>/dev/null; then
              cp -f "${pkgs.bullet-static}/lib/libLinearMath.a" "$LIBS_DIR/libLinearMath_nix_amd64.a"
            fi
            '' else if pkgs.stdenv.hostPlatform.isDarwin && pkgs.stdenv.hostPlatform.isAarch64 then ''
            if ! cmp -s "${pkgs.bullet-static}/lib/libBulletDynamics.a" "$LIBS_DIR/libBulletDynamics_darwin_arm64.a" 2>/dev/null; then
              cp -f "${pkgs.bullet-static}/lib/libBulletDynamics.a" "$LIBS_DIR/libBulletDynamics_darwin_arm64.a"
            fi
            if ! cmp -s "${pkgs.bullet-static}/lib/libBulletCollision.a" "$LIBS_DIR/libBulletCollision_darwin_arm64.a" 2>/dev/null; then
              cp -f "${pkgs.bullet-static}/lib/libBulletCollision.a" "$LIBS_DIR/libBulletCollision_darwin_arm64.a"
            fi
            if ! cmp -s "${pkgs.bullet-static}/lib/libLinearMath.a" "$LIBS_DIR/libLinearMath_darwin_arm64.a" 2>/dev/null; then
              cp -f "${pkgs.bullet-static}/lib/libLinearMath.a" "$LIBS_DIR/libLinearMath_darwin_arm64.a"
            fi
            '' else ""}

            echo "Game engine libraries installed to $LIBS_DIR"
          '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
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
          '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
            # macOS: Set up Vulkan SDK environment via MoltenVK from nixpkgs
            export VULKAN_SDK="${pkgs.moltenvk}"
            echo "Using Vulkan SDK (MoltenVK) from: $VULKAN_SDK"

            # Set up CGO flags for building with MoltenVK
            export CGO_ENABLED=1
            export CGO_CFLAGS="-I${pkgs.vulkan-headers}/include -I${pkgs.moltenvk}/include"
            export CGO_LDFLAGS="-L${pkgs.moltenvk}/lib -lMoltenVK -Wl,-rpath,${pkgs.moltenvk}/lib"

            # Add Vulkan tools to PATH
            export PATH="${pkgs.vulkan-tools}/bin:$PATH"

            # Set Vulkan environment variables for MoltenVK
            export VK_ICD_FILENAMES="${pkgs.moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json"
            export VK_LAYER_PATH="${pkgs.vulkan-loader}/share/vulkan/explicit_layer.d"
            export DYLD_LIBRARY_PATH="${pkgs.moltenvk}/lib:${pkgs.vulkan-loader}/lib''${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

            echo "CGO_CFLAGS=$CGO_CFLAGS"
            echo "CGO_LDFLAGS=$CGO_LDFLAGS"
            echo "VK_ICD_FILENAMES=$VK_ICD_FILENAMES"
          '';
        };
      });
    };
}
