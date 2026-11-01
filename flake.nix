{
  description = "Runs your dev processes side by side and shows one of them at a time";

  # Only used when this flake is built on its own (`nix build`, `nix develop`).
  # An installing config should point it at its own nixpkgs:
  #   inputs.corral.inputs.nixpkgs.follows = "nixpkgs";
  # or take the overlay, which builds against whatever pkgs applies it.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Ghostty 1.4 needs zig 0.17 exactly. Rather than pinning a nixpkgs that
      # has it, take zig from the nixpkgs doing the installing — and fail
      # loudly rather than fall back to some other zig if that attribute ever
      # goes away.
      corralFor =
        pkgs:
        if pkgs ? zig_0_17 then
          pkgs.callPackage ./package.nix { }
        else
          throw "corral needs pkgs.zig_0_17, which this nixpkgs (${pkgs.lib.version}) does not have.";
    in
    {
      packages = forAllSystems (pkgs: rec {
        corral = corralFor pkgs;
        default = corral;
      });

      # For `nixpkgs.overlays = [ inputs.corral.overlays.default ];`, after which
      # `pkgs.corral` is built from your own nixpkgs.
      overlays.default = final: _prev: {
        corral = corralFor final;
      };

      apps = forAllSystems (pkgs: rec {
        corral = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.corral;
        };
        default = corral;
      });

      # `nix develop`. The same shell `nix-shell` gives you.
      devShells = forAllSystems (pkgs: {
        default = import ./shell.nix { inherit pkgs; };
      });

      checks = forAllSystems (pkgs: {
        corral = self.packages.${pkgs.stdenv.hostPlatform.system}.corral;
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
