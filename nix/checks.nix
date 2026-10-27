{ inputs, ... }: {
  perSystem = { pkgs, config, lib, recipes, ... }:
    let
      source = lib.fileset.toSource {
        root = ../.;
        fileset = lib.fileset.unions [ ../config ../recipes ../scripts ../tests ];
      };
      python = pkgs.python3.withPackages (p: [ p.pyyaml p.websocket-client ]);
    in
    {
      checks.funding = pkgs.runCommand "funding-tests"
        {
          nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.jq ];
        } ''
        bash ${source}/tests/funding.sh
        touch $out
      '';

      checks.bootstrap = pkgs.runCommand "bootstrap-tests" { } ''
        mkdir config
        cp ${../config/env} config/env
        SKIP_MITHRIL=true ${recipes.mithrilBootstrap "state/cardano-node"}/bin/mithril-bootstrap
        test ! -e state/cardano-node/db
        if SKIP_MITHRIL=invalid ${recipes.mithrilBootstrap "state/cardano-node"}/bin/mithril-bootstrap; then
          echo "invalid SKIP_MITHRIL was accepted" >&2
          exit 1
        fi
        mkdir state/cardano-node/db
        ${recipes.mithrilBootstrap "state/cardano-node"}/bin/mithril-bootstrap
        touch $out
      '';

      packages.test-lifecycle = pkgs.writeShellApplication {
        name = "test-lifecycle";
        runtimeInputs = [
          python
          pkgs.coreutils
          pkgs.cardano-node
          pkgs.cardano-cli
          pkgs.hydra-node
          config.packages.existing-node
          config.packages.distribute
          config.packages.gen-keys
        ];
        text = ''
          exec python ${source}/tests/lifecycle.py \
            --recipe-root ${source} \
            --hydra-config ${inputs.hydra}/hydra-cluster/config "$@"
        '';
      };
    };
}
