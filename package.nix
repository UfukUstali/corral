{
  lib,
  stdenv,
  stdenvNoCC,
  # Named exactly, not `zig`: corral builds against ghostty's main branch, which
  # tracks Zig closely enough that any other minor breaks the build in confusing
  # ways. A nixpkgs without this attribute should fail, not substitute.
  zig_0_16,
  gitMinimal,
  cacert,

  # Hash of the fetched zig dependency tree; see `deps` below for how to refresh
  # it after touching build.zig.zon.
  depsHash ? "sha256-vIIo8Rpq6sSxXv3pX+tFRuhxbq9I3WfKkR/kfvWnr/Q=",
}:

let
  zig = zig_0_16;
  version = "0.2.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./src
      ./README.md
    ];
  };

  # Everything `zig build` would download: ghostty plus its transitive
  # dependencies, ~110MB unpacked. Zig 0.16 keeps the downloaded tarballs in the
  # global cache but unpacks them into `zig-pkg/` next to build.zig, and skips
  # the network entirely when a package is already unpacked there. So this
  # derivation captures `zig-pkg/` rather than the cache: its contents are the
  # hashes zig already verified against build.zig.zon, which makes it a far more
  # stable thing to pin than the upstream tarball bytes.
  #
  # To refresh after changing build.zig.zon: set `depsHash` to `lib.fakeHash`,
  # run `nix build .#corral.deps`, and copy the "got:" hash out of the mismatch
  # error. Editing the hash in place is not enough on its own — nix identifies a
  # fixed-output derivation by its hash, so an unchanged one is served from the
  # store without refetching.
  deps = stdenvNoCC.mkDerivation {
    pname = "corral-zig-deps";
    inherit version src;

    nativeBuildInputs = [
      zig
      gitMinimal # some dependency kinds are fetched over git
      cacert
    ];

    dontConfigure = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild

      export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
      # zig 0.16 assumes this exists instead of creating it.
      mkdir -p "$ZIG_GLOBAL_CACHE_DIR/tmp"

      # `=all` rather than the default: ghostty's build.zig only asks for most of
      # its C dependencies lazily, and a needed-only fetch stops short of them —
      # the build then tries to reach the network from inside the sandbox.
      zig build --fetch=all

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mv zig-pkg $out
      runHook postInstall
    '';

    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = depsHash;
  };
in

stdenv.mkDerivation {
  pname = "corral";
  inherit version src;

  __structuredAttrs = true;
  strictDeps = true;

  nativeBuildInputs = [
    zig.hook
    gitMinimal
  ];

  # Hand zig the dependency tree it would otherwise fetch. It writes lock files
  # and cache metadata in here, so it has to be a writable copy, not a symlink
  # into the store.
  postConfigure = ''
    cp -rL ${deps} zig-pkg
    chmod -R u+w zig-pkg
  '';

  # zig.hook already passes `-Dcpu=baseline --release=safe`, which is the
  # ReleaseSafe build README recommends.

  doCheck = true;

  passthru = {
    inherit deps;
  };

  meta = {
    description = "Runs your dev processes side by side and shows one of them at a time";
    longDescription = ''
      A deliberately small replacement for the parts of mprocs I actually use:
      find the projects in a tree, start the ones I want, watch each, stop and
      restart them individually. Nothing starts on its own.
    '';
    mainProgram = "corral";
    platforms = lib.platforms.unix;
  };
}
