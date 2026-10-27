{
  perSystem = { pkgs, config, ... }: {
    devShells.default = pkgs.mkShellNoCC {
      packages = [
        pkgs.hydra-node
        pkgs.hydra-tui
        pkgs.cardano-node
        pkgs.cardano-cli
        pkgs.mithril-client-cli
        pkgs.process-compose
        pkgs.jq
        pkgs.curl
        pkgs.websocat
        pkgs.just
        config.treefmt.build.wrapper
        config.packages.gen-keys
      ];
    };
  };
}
