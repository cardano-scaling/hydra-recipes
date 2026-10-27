{
  description = "Recipes for running a hydra-node";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    flake-parts.url = "github:hercules-ci/flake-parts";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hydra.url = "github:cardano-scaling/hydra/2.4.1";
    cardano-node.url = "github:IntersectMBO/cardano-node/11.1.3";
    mithril.url = "github:input-output-hk/mithril/2630.1-hotfix";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      imports = [
        inputs.process-compose-flake.flakeModule
        inputs.treefmt-nix.flakeModule
        ./nix/checks.nix
        ./nix/devshell.nix
        ./nix/gen-keys.nix
        ./nix/lib.nix
        ./nix/pkgs.nix
        ./nix/treefmt.nix
        ./recipes/single-party
        ./recipes/blockfrost
        ./recipes/cardano-node
        ./recipes/existing-node
      ];
    };

  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
      "https://cardano-scaling.cachix.org"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "cardano-scaling.cachix.org-1:QNK4nFrowZ/aIJMCBsE35m+O70fV6eewsBNdQnCSMKA="
    ];
    allow-import-from-derivation = true;
  };
}
