{ pkgs
, runCommand
, writeText
, lib
, stdenv
, ocamlPackages
, gnumake
, opamvars2nix
, opamsubst2nix
, opam-installer
, git
}:

let
  opam = import ./opam.nix;

in
{ name
, version
, src ? null
, buildScript ? [ ]
, installScript ? [ ]
, depends ? (_: [ ])
, optionalDepends ? (_: [ ])
, nativeDepends ? [ ]
, extraFiles ? [ ]
, substFiles ? [ ]
, ...
}@args:

let
  defaultVariables = import (
    runCommand
      "opamvars2nix"
      {
        buildInputs = [ opamvars2nix ];
      }
      "opamvars2nix > $out"
  );

  env = {
    local = defaultVariables // {
      inherit name version;
      jobs = 1;

      dev = false;
      with-test = false;
      with-doc = false;
      build = true;
      post = false;
      pinned = false;

      os-distribution = "nixos";

      opam-version = "2.1.2";

      make = "${gnumake}/bin/make";

      prefix = "$out";
      lib = "$OCAMLFIND_DESTDIR";
      bin = "$out/bin";
      share = "$out/share";
      doc = "$out/share/doc";
      man = "$out/share/man";
    };

    packages = package: rec {
      installed = builtins.elem package [
        "ocaml"
        "dune"
        "ocamlfind"
      ] || (builtins.hasAttr package ocamlPackages);

      enable = if installed then "enable" else "disable";

      prefix = "${ocamlPackages.${package}}";
      lib = "${prefix}/lib/ocaml/${ocamlPackages.ocaml.version}/site-lib";
      bin = "${prefix}/bin";
      share = "${prefix}/share";
      doc = "${prefix}/share/doc";
      man = "${prefix}/share/man";

      version = if (ocamlPackages ? package) then ocamlPackages.${package}.version else null;

      # For 'ocaml' package
      native = true;
      native-dynlink = true;
      preinstalled = true;
    };
  };

  defaultInstallScript = ''
    if test -r "${name}.install"; then
      ${opam-installer}/bin/opam-installer \
        --prefix="${env.local.prefix}" \
        --libdir="${env.local.lib}" \
        --docdir="${env.local.doc}" \
        --mandir="${env.local.man}" \
        --name="${name}" \
        --install "${name}.install"
    fi
  '';

  fixTopkgCommand = args:
    # XXX: A hack to deal with missing 'topfind' dependency for 'topkg'-based packages.
    if lib.lists.take 2 args == [ "\"ocaml\"" "\"pkg/pkg.ml\"" ] then
      let
        ocamlfindEnv = (env.packages "ocamlfind");
      in
      [ "ocaml" "-I" ocamlfindEnv.lib ] ++ lib.lists.drop 1 args
    else
      args;

  renderCommands = cmds: builtins.concatStringsSep "\n" (
    builtins.map (builtins.concatStringsSep " ") cmds
  );

  renderedBuildScript = renderCommands (
    builtins.map fixTopkgCommand (opam.evalCommands env buildScript)
  );

  renderedInstallScript = renderCommands (opam.evalCommands env installScript);

  copyExtraFiles = builtins.concatStringsSep "\n" (
    builtins.map ({ source, path }: "cp ${source} ${path}") extraFiles
  );

  overlayedSource = stdenv.mkDerivation {
    name = "opam2nix-extra-files-${name}-${opam.cleanVersion version}";

    inherit src;
    dontUnpack = src == null;

    phases = [ "unpackPhase" "installPhase" ];

    installPhase = ''
      mkdir -p $out
      ${copyExtraFiles}
      cp -r . $out
    '';
  };

  substs = builtins.map
    (file:
      {
        path = file;
        source = writeText "opam2nix-subst-file" (opam.evalArg env (import (
          runCommand
            "opam2nix-subst-expr"
            {
              buildInputs = [ opamsubst2nix ];
            }
            "opamsubst2nix < ${overlayedSource}/${file}.in > $out"
        )));
      }
    )
    substFiles;

  writeSubsts = builtins.concatStringsSep "\n" (
    builtins.map
      ({ path, source }: "cp -v ${source} ${path}")
      substs
  );

in
stdenv.mkDerivation ({
  pname = name;
  version = opam.cleanVersion version;

  src = overlayedSource;

  buildInputs = with ocamlPackages; [ ocaml ocamlfind git ];

  propagatedBuildInputs =
    opam.evalDependenciesFormula name env ocamlPackages depends
      ++ opam.evalDependenciesFormula name env ocamlPackages optionalDepends;

  propagatedNativeBuildInputs = opam.evalNativeDependencies env pkgs nativeDepends;

  dontConfigure = true;

  patchPhase = ''
    ${writeSubsts}
  '';

  buildPhase = ''
    # Build Opam package
    ${renderedBuildScript}
  '';

  installPhase = ''
    # Install Opam package
    mkdir -p ${env.local.bin} ${env.local.lib}
    ${defaultInstallScript}
    ${renderedInstallScript}
  '';
} // builtins.removeAttrs args [
  "name"
  "version"
  "src"
  "buildScript"
  "installScript"
  "depends"
  "optionalDepends"
  "nativeDepends"
  "extraFiles"
  "substFiles"
])
