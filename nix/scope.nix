{ callPackage
, runCommand
, lib
, newScope
, ocaml
, findlib
, opamRepository ? callPackage ./repository.nix { }
}:

lib.makeScope newScope (self: {
  inherit ocaml findlib;
  ocamlfind = self.findlib;

  mkOpam2NixPackage = callPackage ./make-package.nix {
    inherit (self) ocaml findlib;
  };

  opam2nix = (import ../default.nix).default;

  generateOpam2Nix = { name, version, src, patches ? [ ] }:
    import (
      runCommand
        "opam2nix-${name}-${version}"
        {
          buildInputs = [ self.opam2nix ];
          inherit src patches;
        }
        ''
          cp $src opam
          chmod +w opam
          for patch in $patches; do
            patch opam $patch
          done
          opam2nix --name ${name} --version ${version} --file opam > $out
        ''
    );

  callOpam2Nix = args: self.callPackage (self.generateOpam2Nix args);

  callOpam = { name, version, patches ? [ ] }:
    let
      src = "${opamRepository}/packages/${name}/${name}.${version}/opam";
    in
    args: self.callOpam2Nix { inherit name version src patches; } ({
      resolveExtraFile = { path, ... }@args: {
        inherit path;
        source = "${opamRepository}/packages/${name}/${name}.${version}/files/${path}";
      };
    } // args);
})
