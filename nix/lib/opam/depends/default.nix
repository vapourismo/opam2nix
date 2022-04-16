{ lib, pkgs, envLib, filterLib, constraintLib, formulaLib }:

let
  evalCondition = formulaLib.evalBoolean { atom = filterLib.eval; };

  showConstraint = subject: formulaLib.show { atom = constraintLib.show subject; };

  evalConstraint = formulaLib.evalPredicate { atom = constraintLib.eval; };
in

{ ocamlPackages }:

let
  evalDependency = { optional ? false }: dep: dep {
    package = packageName: enabled: constraint:
      let want = evalCondition enabled; in
      if builtins.hasAttr packageName ocamlPackages && want then
        let package = ocamlPackages.${packageName}; in
        (
          if evalConstraint constraint package.version then
            [ package ]
          else
            null
        )
      else if optional || !want then
        [ ]
      else
        null;
  };

  showDependency = dep: dep {
    package = packageName: enabled: constraint:
      if builtins.hasAttr packageName ocamlPackages then
        let package = ocamlPackages.${packageName}.name; in
        (
          if evalCondition enabled then
            "${showConstraint package constraint}"
          else
            "${packageName} disabled"
        )
      else
        "${packageName} is unknown";
  };

  eval = { name, ... }@config: depFormula:
    let
      downstreamConfig = builtins.removeAttrs config [ "name" ];
      deps = formulaLib.evalList { atom = evalDependency downstreamConfig; } depFormula;
    in
    if builtins.isList deps then
      deps
    else
      let debugged =
        formulaLib.debug
          {
            evalAtom = dep: evalDependency downstreamConfig dep != null;
            showAtom = showDependency;
          }
          depFormula;
      in
      abort ''
        Dependency formula could not be satisfied for ${name}:
        ${debugged}
      '';

  evalNative = nativeDepends:
    let
      findDep = packageName:
        if builtins.hasAttr packageName pkgs then
          pkgs.${packageName}
        else
          abort "Unknown native package ${packageName}";
    in
    builtins.concatMap
      ({ nativePackage, ... }: builtins.map findDep nativePackage)
      (builtins.filter ({ filter, ... }: filterLib.eval filter) nativeDepends);
in

{
  inherit eval evalNative;
}