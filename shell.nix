# Dev shell for corral.
#
# Pinned on purpose: corral builds against ghostty's `main` branch, which
# declares `.minimum_zig_version = "0.16.0"` and tracks Zig closely enough
# that a floating channel would break the build on a whim.
#
#   nix-shell            # drops you in fish with zig 0.16 on PATH
#   nix-shell --run 'zig build test'
#
{
  pkgs ?
    import (fetchTarball {
      # nixos-unstable, 2026-08-03
      url = "https://github.com/NixOS/nixpkgs/archive/643809054d65fdd466a63e3155b8c498cb483c04.tar.gz";
      sha256 = "0yb23r5k59xm5miqa2azwl2qgdwk324q1qwwcwgv198z25wchixx";
    }) { },
}:

assert pkgs.lib.assertMsg (pkgs.lib.versions.majorMinor pkgs.zig.version == "0.16")
  "corral needs zig 0.16 (pinned nixpkgs has ${pkgs.zig.version})";

pkgs.mkShell {
  name = "corral";

  packages = with pkgs; [
    zig # 0.16.0
    zls # matching language server
    fish
    git # `zig fetch` shells out to it for some dependency kinds
  ];

  shellHook = ''
    # `zig build` downloads ghostty (and its vendored C deps) into the global
    # cache. Keep it inside the project so a stale ghostty is one `rm -rf`
    # away and never leaks into other checkouts.
    export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"

    # Only hijack the shell when a human is driving. `nix-shell --run ...`
    # and direnv both run this hook in a non-interactive bash, where exec'ing
    # fish would swallow the command.
    case $- in
      *i*)
        echo "corral · zig $(zig version) · fish"
        exec ${pkgs.fish}/bin/fish
        ;;
    esac
  '';
}
