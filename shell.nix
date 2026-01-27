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

in pkgs.mkShell {
  buildInputs = [
    pkgs.babashka
    pkgs.check-jsonschema
    pkgs.hyperfine
    pkgs.jsonnet
    pkgs.nodejs
    pkgs.yq-go
    pkgs.python3Packages.datamodel-code-generator
    pkgs.python3Packages.loguru
    pkgs.python3Packages.orjson
    pkgs.python3Packages.pyaml
    pkgs.python3Packages.pydantic
    pkgs.python3Packages.pyyaml
    pkgs.python3Packages.rich
    pkgs.python3Packages.typer
    dirschema
  ];  # join lists with ++

  nativeBuildInputs = [
  ];

  shellHook = nix_shortcuts.shellHook + ''
  '' + ''
    echo-shortcuts ${__curPos.file}
  '';  # join strings with +
}
