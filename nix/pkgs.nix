{ inputs, ... }: {
  perSystem = { system, ... }: {
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      overlays = [
        (_final: _prev: {
          inherit (inputs.hydra.packages.${system}) hydra-node hydra-tui;
          inherit (inputs.cardano-node.packages.${system}) cardano-node cardano-cli;
          inherit (inputs.mithril.packages.${system}) mithril-client-cli;
        })
      ];
    };
  };
}
