{
  description = "hspak.dev site generator and production server";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      package = options: pkgs.callPackage ./nix/package.nix ({ zig = pkgs.zig_0_16; } // options);
      generator = package { component = "generator"; };
      server = package { };
      site = pkgs.callPackage ./nix/site.nix {
        inherit generator;
        sourceDateEpoch = self.lastModified;
      };
    in
    {
      packages.${system} = {
        inherit generator server site;
        default = server;
      };
      devShells.${system}.default = pkgs.mkShell {
        inputsFrom = [ generator ];
      };
      formatter.${system} = pkgs.nixfmt;
      checks.${system} = {
        tests = package { component = "tests"; };
        configured-server =
          let
            forkSource =
              name:
              pkgs.runCommand "hspak-${name}-fork" { } ''
                mkdir "$out"
                tar -xzf ${generator.zigDeps}/${name}-*.tar.gz --strip-components=1 -C "$out"
              '';
          in
          package {
            component = "tests";
            testFilter = "production";
            documentRoot = "current";
            acmeRoot = "acme-challenge";
            fileThreads = 2;
            fileQueue = 32;
            zhtpsSrc = forkSource "zhtps";
            zeitSrc = forkSource "zeit";
            # An empty cache ensures neither fork can fall back to its fetched package.
            zigDeps = pkgs.runCommand "hspak-empty-zig-deps" { } ''mkdir "$out"'';
          };
        inherit generator server site;
        site-timestamp = pkgs.runCommand "hspak-site-timestamp" { } ''
          grep -Fxq '<updated>January 1, 2000</updated>' ${
            site.overrideAttrs (_: {
              SOURCE_DATE_EPOCH = "946684800";
            })
          }/feed.xml
          touch "$out"
        '';
      };
    };
}
