let
  resolveVariable = { local, packages }: pkgs: var: defaults:
    if pkgs == [ ] || pkgs == [ "_" ] then
      if builtins.hasAttr var local then
        local.${var}
      else
        abort ("Unknown local variable: ${var}")
    else
      abort
        ("ident: ${builtins.toJSON [pkgs var defaults]}");

  argScope = env: {
    ident = resolveVariable env;
  };

  evalArg = env: f: f (argScope env);

  evalCommands = env: commands:
    let
      keptCommands = builtins.filter ({ filter, ... }: evalFilter env filter) commands;

      prunedCommands = builtins.map
        ({ args, ... }:
          let
            keptArgs = builtins.filter ({ filter, ... }: evalFilter env filter) args;

            prunedArgs = builtins.map ({ arg, ... }: builtins.toJSON (evalArg env arg)) keptArgs;
          in
          builtins.concatStringsSep " " prunedArgs
        )
        keptCommands;
    in
    builtins.concatStringsSep "\n" prunedCommands;

  # Filter DSL.
  filterScope = env: {
    bool = value: value;

    string = value: value;

    ident = resolveVariable env;

    equal = lhs: rhs: lhs == rhs;

    notEqual = lhs: rhs: lhs != rhs;

    greaterEqual = lhs: rhs: lhs >= rhs;

    greaterThan = lhs: rhs: lhs > rhs;

    lowerEqual = lhs: rhs: lhs <= rhs;

    lowerThan = lhs: rhs: lhs < rhs;

    and = lhs: rhs: lhs && rhs;

    or = lhs: rhs: lhs || rhs;

    def = _: abort "filterScope.def";

    undef = _: abort "filterScope.undef";
  };

  evalFilter = env: f: f (filterScope env);

  filterStringScope = {
    bool = builtins.toJSON;

    string = builtins.toJSON;

    ident = pkgs: var: _defaults:
      if pkgs == [ ] then
        "${var}"
      else
        builtins.concatStringsSep ":" (pkgs ++ [ var ]);

    equal = lhs: rhs: "${lhs} == ${rhs}";

    notEqual = lhs: rhs: "${lhs} != ${rhs}";

    greaterEqual = lhs: rhs: "${lhs} >= ${rhs}";

    greaterThan = lhs: rhs: "${lhs} > ${rhs}";

    lowerEqual = lhs: rhs: "${lhs} <= ${rhs}";

    lowerThan = lhs: rhs: "${lhs} < ${rhs}";

    and = lhs: rhs: "${lhs} && ${rhs}";

    or = lhs: rhs: "${lhs} || ${rhs}";

    def = _: abort "filterScope.def";

    undef = _: abort "filterScope.undef";
  };

  showFilter = f: f filterStringScope;

  # Expressions of this DSL call exactly one of these functions.
  filterOrConstraintScope = env: {
    always = filter: _: evalFilter env filter;

    equal = versionFilter: packageVersion:
      builtins.compareVersions packageVersion (evalFilter env versionFilter) == 0;

    notEqual = versionFilter: packageVersion:
      builtins.compareVersions packageVersion (evalFilter env versionFilter) != 0;

    greaterEqual = versionFilter: packageVersion:
      builtins.compareVersions packageVersion (evalFilter env versionFilter) >= 0;

    greaterThan = versionFilter: packageVersion:
      builtins.compareVersions packageVersion (evalFilter env versionFilter) > 0;

    lowerEqual = versionFilter: packageVersion:
      builtins.compareVersions packageVersion (evalFilter env versionFilter) <= 0;

    lowerThan = versionFilter: packageVersion:
      builtins.compareVersions packageVersion (evalFilter env versionFilter) < 0;
  };

  evalFilterOrConstraint = env: f: f (filterOrConstraintScope env);

  filterOrConstraintStringScope = {
    always = filter: _: showFilter filter;

    equal = versionFilter: packageName:
      "${packageName} == ${showFilter versionFilter}";

    notEqual = versionFilter: packageName:
      "${packageName} != ${showFilter versionFilter}";

    greaterEqual = versionFilter: packageName:
      "${packageName} >= ${showFilter versionFilter}";

    greaterThan = versionFilter: packageName:
      "${packageName} > ${showFilter versionFilter}";

    lowerEqual = versionFilter: packageName:
      "${packageName} <= ${showFilter versionFilter}";

    lowerThan = versionFilter: packageName:
      "${packageName} < ${showFilter versionFilter}";
  };

  showFilterOrConstraint = f: f filterOrConstraintStringScope;

  # Predicate DSL where values are functions from an unknown input to boolean.
  # Atoms are of type "filterOrConstraint".
  filterOrConstraintFormulaScope = env: {
    empty = _: true;

    atom = filterOrConstraint: evalFilterOrConstraint env filterOrConstraint;
  };

  evalFilterOrConstraintFormula = env: f:
    let
      cnf = f (filterOrConstraintFormulaScope env);

      evalOrs =
        builtins.foldl'
          (lhs: rhs: version: lhs version || rhs version)
          (_: false);

      evalAnds =
        builtins.foldl'
          (lhs: rhs: version: lhs version && rhs version)
          (_: true);

    in
    evalAnds (builtins.map evalOrs cnf);

  filterOrConstraintFormulaStringScope = {
    empty = packageName: "${packageName}";

    atom = showFilterOrConstraint;
  };

  showFilterOrConstraintFormula = f:
    let
      cnf = f filterOrConstraintFormulaStringScope;

      evalOrs = ors:
        if builtins.length ors > 0 then
          builtins.foldl'
            (lhs: rhs: packageName: "${lhs packageName} || ${rhs packageName}")
            (builtins.head ors)
            (builtins.tail ors)
        else
          _: "false";

      evalAnds = ands:
        if builtins.length ands > 0 then
          builtins.foldl'
            (lhs: rhs: packageName: "${lhs packageName} && ${rhs packageName}")
            (builtins.head ands)
            (builtins.tail ands)
        else
          _: "true";

    in
    evalAnds (builtins.map (ors: p: "(${evalOrs ors p})") cnf);

  # Single indirection DSL - basically an expression of this will immediate call the "package"
  # attribute.
  dependencyScope = env: packages: {
    package = packageName: formula:
      let package =
        if builtins.hasAttr packageName packages then
          packages.${packageName}
        else
          abort "Unknown package ${packageName}";
      in
      if evalFilterOrConstraintFormula env formula package.version then
        [ package ]
      else
        null;
  };

  evalDependency = env: packages: f: f (dependencyScope env packages);

  dependencyStringScope = {
    package = packageName: formula:
      "${packageName} when ${showFilterOrConstraintFormula formula packageName}";
  };

  showDependency = f: f dependencyStringScope;

  dependenciesFormulaStringScope = {
    empty = "empty";

    atom = showDependency;
  };

  showDependenciesFormula = f:
    let
      cnf = f dependenciesFormulaStringScope;

      evalOrs = ors:
        if builtins.length ors > 0 then
          builtins.foldl' (lhs: rhs: "${lhs} || ${rhs}") (builtins.head ors) (builtins.tail ors)
        else
          "false";

      evalAnds = ands:
        if builtins.length ands > 0 then
          builtins.foldl' (lhs: rhs: "${lhs} && ${rhs}") (builtins.head ands) (builtins.tail ands)
        else
          "true";
    in
    evalAnds (builtins.map (ors: "(${evalOrs ors})") cnf);

  # List concatenation/alternation DSL where a null value indicates failure, list value indicates
  # success.
  # Atoms are of type "dependency".
  dependenciesFormulaScope = env: packages: {
    empty = [ ];

    atom = evalDependency env packages;
  };

  evalDependenciesFormula = env: packages: f:
    let
      cnf = f (dependenciesFormulaScope env packages);

      evalOrs =
        builtins.foldl'
          (lhs: rhs: if lhs != null then lhs else rhs)
          null;

      evalAnds =
        builtins.foldl'
          (lhs: rhs: if lhs != null && rhs != null then lhs ++ rhs else null)
          [ ];

      deps = evalAnds (builtins.map evalOrs cnf);

    in
    if builtins.isList deps then
      deps
    else
      abort ''
        Dependency formula could not be satisfied:
        ${showDependenciesFormula f}
      '';

  evalNativeDependencies = env: nativePackages: nativeDepends:
    let
      findDep = packageName:
        if builtins.hasAttr packageName nativePackages then
          nativePackages.${packageName}
        else
          abort "Unknown native package ${packageName}";
    in
    builtins.concatMap
      ({ packages, ... }: builtins.map findDep packages)
      (builtins.filter ({ filter, ... }: evalFilter env filter) nativeDepends);

in

{
  inherit evalDependenciesFormula evalCommands evalNativeDependencies;
}
