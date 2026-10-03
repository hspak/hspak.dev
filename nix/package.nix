{
  lib,
  stdenv,
  zig,
  pkg-config,
  autoPatchelfHook,
  openssl,
  nghttp2,
  zstd,
  imagemagick,
  zhtpsSrc ? null,
  zeitSrc ? null,
  zigDeps ? null,
  component ? "server",
  documentRoot ? "docs",
  acmeRoot ? null,
  fileThreads ? 1,
  fileQueue ? 64,
  testFilter ? null,
}:
assert builtins.elem component [
  "server"
  "generator"
  "tests"
];
assert documentRoot != "" && (acmeRoot == null || acmeRoot != "");
assert fileThreads > 0 && fileQueue > 0;
let
  build_files = lib.fileset.unions [
    ../build.zig
    ../build.zig.zon
  ];
  flags = [
    "-Doptimize=ReleaseSafe"
    "-Dcpu=${if component == "generator" then "baseline" else "x86_64_v4"}"
    "-Dsystem-openssl=true"
    "-Dsystem-nghttp2=true"
    "-Dsystem-zstd=true"
    "-Ddocument-root=${documentRoot}"
    "-Dfile-threads=${toString fileThreads}"
    "-Dfile-queue=${toString fileQueue}"
  ]
  ++ lib.optional (zhtpsSrc != null) "--fork=${zhtpsSrc}"
  ++ lib.optional (zeitSrc != null) "--fork=${zeitSrc}"
  ++ lib.optional (acmeRoot != null) "-Dacme-root=${acmeRoot}"
  ++ lib.optional (testFilter != null) "-Dtest-filter=${testFilter}";
  step =
    {
      server = "install-server";
      generator = "install";
      tests = "test";
    }
    .${component};
in
stdenv.mkDerivation (finalAttrs: {
  pname = "hspak-${component}";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      build_files
      ../src
    ];
  };
  zigDeps =
    if zigDeps != null then
      zigDeps
    else
      zig.fetchDeps {
        pname = "hspak";
        inherit (finalAttrs) version;
        src = lib.fileset.toSource {
          root = ../.;
          fileset = build_files;
        };
        hash = "sha256-XX2Pc1ArRne4YykGbURQNha2rtkKKkIlN7Uz4jSzo2o=";
      };
  nativeBuildInputs = [
    zig
    pkg-config
    autoPatchelfHook
  ];
  buildInputs = [
    openssl
    nghttp2
    zstd
  ]
  ++ lib.optional (component != "server") imagemagick;
  strictDeps = true;
  # Only tests execute v4 binaries on the builder; server builds merely compile them.
  requiredSystemFeatures = lib.optional (component == "tests") "gccarch-x86-64-v4";
  dontConfigure = true;
  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
    zig build ${step} --summary all -j$NIX_BUILD_CORES ${lib.escapeShellArgs flags} \
      --cache-dir "$TMPDIR/zig-local" --prefix "$out"
    mkdir -p "$out"
    runHook postBuild
  '';
  dontInstall = true;
  meta = {
    platforms = [ "x86_64-linux" ];
    mainProgram = if component == "generator" then "zmd" else "zserve";
  };
})
