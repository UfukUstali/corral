# Dev shell for corral: zig 0.17, its language server, fish.
#
#   nix-shell            # drops you in fish with zig on PATH
#   nix-shell --run 'zig build test'
#
# `nix develop` uses this same file. Run through `nix-shell`, nixpkgs comes
# from flake.lock, so the two always agree on the zig they hand you.
{
  pkgs ?
    let
      lock = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.nixpkgs.locked;
    in
    import (fetchTarball {
      url = "https://github.com/NixOS/nixpkgs/archive/${lock.rev}.tar.gz";
      sha256 = lock.narHash;
    }) { },
}:

pkgs.mkShell {
  name = "corral";

  packages = [
    # Named exactly: ghostty 1.4 needs zig 0.17, and a nixpkgs without this
    # attribute should fail here rather than hand you some other zig.
    pkgs.zig_0_17
    pkgs.zls
    pkgs.fish
    pkgs.git # `zig fetch` shells out to it for some dependency kinds
  ];

  shellHook = ''
    # `zig build` downloads ghostty (and its vendored C deps) into the global
    # cache. Keep it inside the project so a stale ghostty is one `rm -rf`
    # away and never leaks into other checkouts.
    export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"

    # Only hijack the shell when a human is driving. `nix-shell --run ...`,
    # `nix develop -c ...` and direnv all run this hook non-interactively,
    # where exec'ing fish would swallow the command.
    case $- in
      *i*)
        echo "corral · zig $(zig version) · fish"
        exec ${pkgs.fish}/bin/fish
        ;;
    esac
  '';
}
