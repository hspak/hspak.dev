{
  lib,
  runCommand,
  generator,
  sourceDateEpoch,
}:
let
  inputs = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../posts
      ../docs/index.css
      ../docs/fonts
      ../docs/favicon.svg
      ../docs/favicon.ico
      ../docs/apple-touch-icon.png
      ../docs/robots.txt
      ../docs/CNAME
    ];
  };
in
runCommand "hspak-site"
  {
    nativeBuildInputs = [ generator ];
    SOURCE_DATE_EPOCH = toString sourceDateEpoch;
  }
  ''
    cp -r ${inputs}/. .
    chmod -R u+w .
    # The feed's update date comes from post mtimes, which copying would set to build time.
    find posts -type f -exec touch -m -d "@$SOURCE_DATE_EPOCH" {} +
    zmd --build-only
    mv docs "$out"
  ''
