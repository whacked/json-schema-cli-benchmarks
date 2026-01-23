{ pkgs ? import <nixpkgs> {} }:
let
  # provides "echo-shortcuts"
  nix_shortcuts = import (pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/whacked/setup/ce9fe9be8e42db9ce003772099d08395358efe8c/bash/nix_shortcuts.nix.sh";
    hash = "sha256-uK+Fgwr6iWXbfi/itJGELzkWqGZsQ8HFpfc+ztGSF98=";
  }) { inherit pkgs; };
in pkgs.mkShell {
  buildInputs = [
    pkgs.nodejs
  ];  # join lists with ++

  nativeBuildInputs = [
  ];

  shellHook = nix_shortcuts.shellHook + ''
  '' + ''
    export PATH=$PATH:/opt/npm/bin  # path to my node-based agents
    echo-shortcuts ${__curPos.file}
  '';  # join strings with +
}
