{
  description = "snippet-searcher-infra: entorno de desarrollo";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Contenedores (el daemon de Docker se habilita en la config de NixOS)
            docker-compose

            # Clientes para inspeccionar el estado
            postgresql
            redis

            # Utilidades
            curl
            jq
          ];
        };
      }
    );
}
