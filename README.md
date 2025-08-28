# nix-enclaver

This repo contains a Nix flake to reproducibly build and run AWS Nitro enclave image files, with proxies inside and outside of the enclave for HTTP and KMS requests. It is a fork of [enclaver](https://github.com/enclaver-io/enclaver) by EdgeBit.io, modified to support reproducible builds. The underlying architecture is the same, except dockerization has been replaced with Nix.

## Architecture

This repo uses the same underyling architecture as [enclaver](https://github.com/enclaver-io/enclaver), without modifications except to the build process. Read the [architecture doc](https://github.com/enclaver-io/enclaver/docs/architecture.md) for the full details.

## Usage

### Building the EIF
```
eifBuild = makeAppEif {
  appPackage = myApp;
  configFile = ./enclaver.yaml;
};
```

To use this utility, add it as an input in your flake file and use the `makeAppEif` function in the library. When building `myApp`, make sure to target either `aarch64-unknown-linux-musl` or `x86_64-unknown-linux-musl`.

The library supports cross-compilation, so you can build for either architecture on your machine. For example, to target aarch64, use:

```
eifBuild = aarch64.makeAppEif {
  appPackage = myApp;
  configFile = ./enclaver.yaml;
};
```

### Running the EIF

To run the EIF, use `enclaver-run`. This will deploy both the Enclave image file and the outer proxy, which is needed to communicate with the enclave.

You can build the binary using:

```
nix build .#enclaver-run
```

## Examples

You can find examples in [`examples/`](./examples/sealing-rs/README.md).

Note that you need to install [Nix](https://nixos.org/) and [enable flakes](https://nixos.wiki/wiki/Flakes) to use this repo. If you are on MacOS, you will need to first use a Linux VM, like [LimaVM](https://lima-vm.io).