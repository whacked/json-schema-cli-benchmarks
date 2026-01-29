{ pkgs ? import <nixpkgs> {} }:
let
  # provides "echo-shortcuts"
  nix_shortcuts = import (pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/whacked/setup/ce9fe9be8e42db9ce003772099d08395358efe8c/bash/nix_shortcuts.nix.sh";
    hash = "sha256-uK+Fgwr6iWXbfi/itJGELzkWqGZsQ8HFpfc+ztGSF98=";
  }) { inherit pkgs; };

  # remote:
  dirschema = (builtins.getFlake "github:whacked/dirschema/256f23e").packages.${pkgs.system}.default;
  # local:
  # dirschema = (builtins.getFlake "/path/to/dirschema").packages.${pkgs.system}.default;

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
    pkgs.babashka
    pkgs.check-jsonschema
    pkgs.hyperfine
    pkgs.jsonnet
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
