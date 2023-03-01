{
  lib,
  runCommand,
  callOpam2Nix,
  opam0install2nix,
  src,
}: let
  repositoryIndex = import ./repository-index.nix {inherit lib src;};

  packagePath = name: version:
    builtins.path {
      name = "opam-${name}-${version}";
      path = "${src}/packages/${name}/${name}.${version}";
    };

  callOpam = {
    name,
    version,
    src ? null,
    patches ? [],
  }:
    callOpam2Nix {
      inherit name version src patches;
      opam = "${packagePath name version}/opam";
      extraFiles = "${packagePath name version}/files";
    };

  fixPackageName = name: let
    fixedName = lib.replaceStrings ["+"] ["p"] name;
  in
    # Check if the name starts with a bad letter.
    if lib.strings.match "^[^a-zA-Z_].*" fixedName != null
    then "_${fixedName}"
    else fixedName;

  solvePackageVersions = {
    packageConstraints ? [],
    testablePackages ? [],
  }: let
    testTargetArgs = lib.strings.escapeShellArgs (
      lib.lists.map (name: "--with-test-for=${name}") testablePackages
    );

    packageConstraintArgs = lib.strings.escapeShellArgs packageConstraints;

    versions = import (
      runCommand
      "opam0install2nix-solver"
      {
        buildInputs = [opam0install2nix];
      }
      ''
        opam0install2nix \
          --packages-dir="${src}/packages" \
          ${testTargetArgs} \
          ${packageConstraintArgs} \
          > $out
      ''
    );
  in
    versions;
in {
  inherit callOpam;

  packages =
    lib.mapAttrs'
    (name: collection: {
      name = fixPackageName name;
      value =
        lib.listToAttrs
        (
          lib.lists.map
          (version: {
            name = version;
            value = callOpam {inherit name version;} {};
          })
          collection.versions
        )
        // {
          latest =
            callOpam
            {
              inherit name;
              version = collection.latest;
            }
            {};
        };
    })
    repositoryIndex;

  select = {testablePackages ? [], ...} @ args:
    lib.mapAttrs'
    (name: version: {
      name = fixPackageName name;
      value = let
        pkg = callOpam {inherit name version;} {};
      in
        pkg.override {with-test = lib.elem name testablePackages;};
    })
    (solvePackageVersions args);
}
