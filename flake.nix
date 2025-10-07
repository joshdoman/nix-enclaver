{
  description = "Enclaver - Rust application for AWS Nitro Enclaves";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url = "github:numtide/flake-utils";
    nitro-util = {
      url = "github:monzo/aws-nitro-util/96f3bb204536dce32882a7e4affd6e8cea828b48";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils, nitro-util }:
    let
      perSystem = (system:
        let
          overlays = [ (import rust-overlay) ];
          pkgs = import nixpkgs {
            inherit system overlays;
          };

          nitro-lib = nitro-util.lib."${system}";

          # Function to create packages for a specific target architecture
          makePackagesForTarget = targetArch:
            let
              arch = if targetArch == "aarch64" then "aarch64" else "x86_64";

              muslTarget = if targetArch == "aarch64"
                then "aarch64-unknown-linux-musl"
                else "x86_64-unknown-linux-musl";

              interpreter = if targetArch == "aarch64"
                then "/lib/ld-musl-aarch64.so.1"
                else "/lib/ld-musl-x86_64.so.1";

              pkgsMusl = import nixpkgs {
                inherit system overlays;
                crossSystem = {
                  config = muslTarget;
                };
              };

              # 1. Build the Enclave Wrapper Binary
              enclaverCrate = pkgsMusl.rustPlatform.buildRustPackage {
                pname = "enclaver-app";
                version = "0.1.0";
                src = pkgs.lib.cleanSourceWith {
                  src = ./.;
                  filter = path: type:
                    let relativePath = pkgs.lib.removePrefix (toString ./. + "/") (toString path);
                    in !(pkgs.lib.hasPrefix "examples/" relativePath) &&
                       !(pkgs.lib.hasPrefix ".github/" relativePath) &&
                       !(relativePath == "README.md");
                };

                # We only need the odyn supervisor now
                buildFeatures = [ "odyn" ];

                cargoLock.lockFile = ./Cargo.lock;
                doCheck = false;

                # Statically link against musl for a minimal environment
                RUSTFLAGS = "-C target-feature=+crt-static";
              };

              # 2. Configure and Build the Linux Kernel
              # Use kernel 6.12 with the required settings for Nitro Enclaves
              customKernel = pkgs.linux_6_12.override {
                structuredExtraConfig = with pkgs.lib.kernel; {
                  VIRTIO_MMIO = yes;
                  VIRTIO_MENU = yes;
                  VIRTIO_MMIO_CMDLINE_DEVICES = yes;
                  NET = yes;
                  VSOCKETS = yes;
                  VIRTIO_VSOCKETS = yes;
                  NSM = yes;  # Enable NSM driver for KMS operations (merged in 6.8+)
                };
                ignoreConfigErrors = false;  # Fail on invalid configs for determinism
              };

              # Choose correct kernel image format based on architecture
              kernelImage = if targetArch == "aarch64"
                then "${customKernel}/Image"     # ARM64 uses Image
                else "${customKernel}/bzImage";  # x86_64 uses bzImage

              # 3. A function to build an EIF around a provided application
              makeAppEif = { appPackage, configFile }:
                let
                  # Parse the config file to extract the name
                  configContent = builtins.readFile configFile;
                  nameMatch = builtins.match ".*name: \"?([^\"]+)\"?.*" configContent;
                  eifName = pkgs.lib.replaceStrings ["-"] ["_"] (if nameMatch != null
                    then builtins.head nameMatch
                    else "application");

                  entrypointScript = pkgs.writeShellScriptBin "start-enclaver" ''
                    #!${pkgs.pkgsStatic.busybox}/bin/sh
                    set -ex
                    exec /bin/odyn --config-dir /etc/enclaver /bin/entrypoint
                  '';

                  # 3(a). Assemble the Root Filesystem
                  enclaveRootFs = pkgs.runCommand "enclave-rootfs" {
                    nativeBuildInputs = [
                      enclaverCrate
                      appPackage
                      pkgs.pkgsStatic.busybox
                      pkgsMusl.stdenv.cc.libc
                      entrypointScript
                      pkgs.patchelf
                    ];
                  } ''
                    mkdir -p $out/bin $out/lib $out/etc/enclaver
                    cp -L ${pkgsMusl.stdenv.cc.libc}/lib/* $out/lib/
                    cp -L ${enclaverCrate}/bin/odyn $out/bin/odyn

                    # Copy all binaries from the app package
                    cp -L ${appPackage}/bin/* $out/bin/

                    # Ensure the entrypoint binary exists
                    if [ ! -f ${appPackage}/bin/entrypoint ]; then
                      echo "Error: appPackage must provide a binary named 'entrypoint'"
                      exit 1
                    fi

                    # Make all binaries writable for patchelf
                    chmod +w $out/bin/*

                    # Patch all binaries with the interpreter
                    for binary in $out/bin/*; do
                      if [ -f "$binary" ] && [ -x "$binary" ]; then
                        patchelf --set-interpreter ${interpreter} "$binary" || true
                      fi
                    done

                    # Copy the static busybox binary to provide shell tools
                    cp -L ${pkgs.pkgsStatic.busybox}/bin/busybox $out/bin/

                    # Get all busybox applets and create symlinks
                    ${pkgs.pkgsStatic.busybox}/bin/busybox --list | while read applet; do
                      ln -s /bin/busybox $out/bin/$applet
                    done

                    # Copy the entrypoint script and make it executable
                    cp -L ${entrypointScript}/bin/start-enclaver $out/bin/start-enclaver
                    chmod +x $out/bin/start-enclaver

                    # Copy the application's configuration file
                    cp -L ${configFile} $out/etc/enclaver/enclaver.yaml
                  '';

                  # 3(b). Create the base EIF (this will output image.eif)
                  baseEif = nitro-lib.buildEif {
                    name = "${eifName}-${arch}";
                    kernel = kernelImage;
                    kernelConfig = "${customKernel.configfile}";
                    nsmKo = null;
                    copyToRoot = enclaveRootFs;
                    entrypoint = "/bin/start-enclaver";
                    env = "";
                  };

                  # 3(c). Copy and rename the EIF file
                  enclaverEif = pkgs.runCommand "${eifName}-${arch}" {} ''
                    mkdir -p $out
                    cp ${baseEif}/* $out/
                    cp ${baseEif}/image.eif $out/${eifName}.eif
                    rm -f $out/image.eif
                  '';

                in {
                  eif = enclaverEif;
                  rootfs = enclaveRootFs;
                };

              # 4. A dummy app to serve as the default for the base EIF
              noApp = pkgsMusl.writeShellApplication {
                name = "entrypoint";
                runtimeInputs = [];
                text = ''
                  echo "Odyn supervisor running. No application specified by child project."
                  # Keep the enclave alive
                  sleep infinity
                '';
              };

              defaultConfig = pkgs.writeText "enclaver.yaml" ''
                version: v1
                name: "default"
                defaults:
                  memory_mb: 4096
                kms_proxy:
                  listen_port: 9999
                egress:
                  allow:
                    - kms.*.amazonaws.com
                    - 169.254.169.254
                ingress:
                  - listen_port: 8000
              '';

              # 5. Build the default package and its rootfs for debugging
              defaultBuild = makeAppEif {
                appPackage = noApp;
                configFile = defaultConfig;
              };

              # Build enclaver for this target
              enclaverRun = pkgsMusl.rustPlatform.buildRustPackage {
                pname = "enclaver";
                version = "0.1.0";
                src = pkgs.lib.cleanSourceWith {
                  src = ./.;
                  filter = path: type:
                    let relativePath = pkgs.lib.removePrefix (toString ./. + "/") (toString path);
                    in !(pkgs.lib.hasPrefix "examples/" relativePath);
                };
                buildFeatures = [ "run_enclave" ];
                cargoLock.lockFile = ./Cargo.lock;
                doCheck = false;
                RUSTFLAGS = "-C target-feature=+crt-static";
              };

            in {
              inherit makeAppEif;
              eif = defaultBuild.eif;
              enclaver = enclaverRun;
              app = enclaverCrate;
              rootfs = defaultBuild.rootfs;
            };

          # Native architecture
          nativeArch = if pkgs.stdenv.isAarch64 then "aarch64" else "x86_64";
          nativePackages = makePackagesForTarget nativeArch;

          # Cross-compilation targets
          x86Packages = makePackagesForTarget "x86_64";
          aarch64Packages = makePackagesForTarget "aarch64";

        in
        {
          lib = {
            # Native architecture
            makeAppEif = nativePackages.makeAppEif;
            
            # Architecture-specific builders
            x86_64.makeAppEif = x86Packages.makeAppEif;
            aarch64.makeAppEif = aarch64Packages.makeAppEif;
          };

          packages = {
            # Default to native for local dev/testing
            default = nativePackages.eif;
            enclaver = nativePackages.enclaver;
            rootfs = nativePackages.rootfs;

            # Explicit targets for production builds
            x86_64-eif = x86Packages.eif;
            aarch64-eif = aarch64Packages.eif;
            x86_64-enclaver = x86Packages.enclaver;
            aarch64-enclaver = aarch64Packages.enclaver;

            # Convenience aliases
            intel-eif = x86Packages.eif;
            graviton-eif = aarch64Packages.eif;
          };

          devShells.default = pkgs.mkShell {
              buildInputs = with pkgs; [
                rust-bin.stable.latest.default
                pkg-config
                openssl
              ];
          };
        });
    in
      flake-utils.lib.eachDefaultSystem perSystem;
}