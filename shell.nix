{ pkgs ? import <nixpkgs> {} }:
let
  # provides "echo-shortcuts"
  nix_shortcuts = import (pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/whacked/setup/ce9fe9be8e42db9ce003772099d08395358efe8c/bash/nix_shortcuts.nix.sh";
    hash = "sha256-uK+Fgwr6iWXbfi/itJGELzkWqGZsQ8HFpfc+ztGSF98=";
  }) { inherit pkgs; };

  # remote:
  dirschema = (builtins.getFlake "github:whacked/dirschema/9666123a2d3bce958e71b5716145659124764ad6").packages.${pkgs.system}.default;
  # local:
  # dirschema = (builtins.getFlake "/path/to/dirschema").packages.${pkgs.system}.default;

  source-meta-json-schema = pkgs.source-meta-json-schema.overrideAttrs (oldAttrs: {
    # Enable portable build to avoid -march=native -mtune=native which causes
    # "Illegal instruction" crashes when the binary is run on a different CPU
    # than it was compiled on (common in Nix binary cache scenarios)
    cmakeFlags = (oldAttrs.cmakeFlags or []) ++ [
      "-DJSONSCHEMA_PORTABLE=ON"
    ];
    postPatch = (oldAttrs.postPatch or "") + ''
      # Disable clang-tidy if the pattern exists (varies by nixpkgs/source version)
      if grep -q 'sourcemeta_clang_tidy_attempt_enable' vendor/core/cmake/common/targets/library.cmake 2>/dev/null; then
        substituteInPlace vendor/core/cmake/common/targets/library.cmake \
          --replace-fail 'sourcemeta_clang_tidy_attempt_enable' '# sourcemeta_clang_tidy_attempt_enable'
      fi
    '';
    # Rename the binary because pkgs.jsonschema also exposes `jsonschema`
    postInstall = (oldAttrs.postInstall or "") + ''
      mv $out/bin/jsonschema $out/bin/jsonschema-sourcemeta
    '';
  });

  python = pkgs.python3;

  jsf = python.pkgs.buildPythonPackage rec {
    pname = "jsf";
    version = "0.11.2";
    build-system = [ python.pkgs.setuptools ];
    pyproject = true;

    src = python.pkgs.fetchPypi {
      inherit pname version;
      sha256 = "07055b363281d38ce871a9256a00587d8472802c5108721a7fe5884465104b5d";
    };

    nativeBuildInputs = with python.pkgs; [
      setuptools
      wheel
    ];

    propagatedBuildInputs = with python.pkgs; [
      faker
      jsonschema
      pydantic
      rstr
      smart-open
      requests
    ];

    doCheck = false;

    pythonImportsCheck = [ "jsf" ];
  };

in pkgs.mkShell {
  buildInputs = [
    dirschema
    source-meta-json-schema
    pkgs.babashka
    pkgs.check-jsonschema
    pkgs.hyperfine
    pkgs.jsonnet
    pkgs.jsonschema
    pkgs.jsonschema-cli
    pkgs.nodejs
    pkgs.yq-go
    (python.withPackages (ps: [
      jsf
      ps.datamodel-code-generator
      ps.loguru
      ps.orjson
      ps.pyaml
      ps.pydantic
      ps.pyyaml
      ps.rich
      ps.tqdm
      ps.typer
    ]))
  ];  # join lists with ++

  nativeBuildInputs = [
  ];

  shellHook = nix_shortcuts.shellHook + ''
  '' + ''
    echo-shortcuts ${__curPos.file}
  '';  # join strings with +
}
