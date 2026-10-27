{ inputs, ... }: {
  perSystem = { pkgs, system, lib, ... }:
    let
      cardanoLib = inputs.cardano-node.legacyPackages.${system}.cardanoLib;

      # Node config, topology and mithril settings for one network, taken
      # from the cardano-node flake so nothing is fetched at runtime.
      networkDir = name:
        let env = inputs.cardano-node.environments.${system}.${name}; in
        pkgs.runCommand "cardano-network-${name}" { } (''
          mkdir -p $out
          cp ${pkgs.writeText "config.json" (builtins.toJSON env.nodeConfig)} $out/config.json
          cp ${cardanoLib.mkTopology env} $out/topology.json
          cat > $out/mithril.env <<EOF
          AGGREGATOR_ENDPOINT=${env.mithrilAggregatorEndpointUrl}
          GENESIS_VERIFICATION_KEY=${env.mithrilGenesisVerificationKey}
          ANCILLARY_VERIFICATION_KEY=${env.mithrilAncillaryVerificationKey}
          EOF
        '' + lib.optionalString (env ? peerSnapshot) ''
          cp ${pkgs.writeText "peer-snapshot.json" (builtins.toJSON env.peerSnapshot)} $out/${name}-peer-snapshot.json
        '');

      cardanoNetworks = pkgs.linkFarm "cardano-networks"
        (map (name: { inherit name; path = networkDir name; }) [ "preview" "preprod" "mainnet" ]);

      loadEnv = ''
        [ -f config/env ] || { echo "run from the repository root" >&2; exit 1; }
        # shellcheck disable=SC1091
        . config/env
      '';

      mkScript = name: text: pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.hydra-node
          pkgs.hydra-tui
          pkgs.cardano-node
          pkgs.cardano-cli
          pkgs.mithril-client-cli
          pkgs.jq
          pkgs.curl
        ];
        text = loadEnv + text;
      };

      funding = ../scripts/funding.sh;
    in
    {
      packages.cardano-networks = cardanoNetworks;
      packages.distribute = mkScript "distribute" ''exec bash ${funding} distribute "$@"'';

      _module.args.recipes = {
        # The recipes differ only in their configuration and chain connection.
        # Managed chain processes can be added alongside this shared startup graph.
        mkRecipe = { name, configFile ? "config/hydra-node.yaml", socket ? null, waitFor ? null, processes ? { } }:
          let
            stateDir = "state/${name}";
            connectionArgs =
              if socket == null
              then "--blockfrost credentials/blockfrost-project.txt"
              else "--node-socket ${socket}";
          in
          {
            cli.preHook = ''
              [ -f config/env ] || { echo "run from the repository root" >&2; exit 1; }
              ${pkgs.coreutils}/bin/mkdir -p ${stateDir}/logs
            '';
            settings = {
              log_location = "${stateDir}/logs/process-compose.log";
              processes = processes // {
                wait-for-fuel = {
                  command = mkScript "wait-for-fuel" ''
                    funding_args=(${connectionArgs})
                    printf -v quoted_args ' %q' "''${funding_args[@]}"
                    export DISTRIBUTE="start the distribute process (select it, press F7) or run: nix run .#distribute --$quoted_args"
                    exec bash ${funding} wait-for-fuel "''${funding_args[@]}"
                  '';
                  depends_on = lib.optionalAttrs (waitFor != null) {
                    ${waitFor}.condition = "process_completed_successfully";
                  };
                };
                # Started by hand (F7) once credentials/funds.addr is funded.
                distribute = {
                  command = mkScript "distribute" ''exec bash ${funding} distribute ${connectionArgs}'';
                  disabled = true;
                };
                hydra-node = {
                  command = mkScript "hydra-node-${name}" ''
                    scripts_args=(--network "$NETWORK")
                    if [ -n "''${HYDRA_SCRIPTS_TX_ID:-}" ]; then
                      scripts_args=(--hydra-scripts-tx-id "$HYDRA_SCRIPTS_TX_ID")
                    fi
                    exec hydra-node \
                      --config ${configFile} \
                      --persistence-dir ${stateDir}/persistence \
                      "''${scripts_args[@]}" \
                      ${connectionArgs} ${lib.optionalString (socket != null) ''--testnet-magic "$NETWORK_MAGIC"''}
                  '';
                  depends_on.wait-for-fuel.condition = "process_completed_successfully";
                  availability.restart = "on_failure";
                  ready_log_line = "NodeSynced";
                  log_location = "${stateDir}/logs/hydra-node.log";
                };
                hydra-tui = {
                  command = mkScript "hydra-tui-${name}" ''
                    exec hydra-tui \
                      ${connectionArgs} \
                      --testnet-magic "$NETWORK_MAGIC" \
                      --funds-signing-key credentials/funds.sk \
                      --fuel-key credentials/cardano.vk
                  '';
                  is_foreground = true;
                  depends_on.hydra-node.condition = "process_log_ready";
                };
              };
            };
          };

        cardanoNode = stateDir:
          mkScript "cardano-node" ''
            exec cardano-node run \
              --config ${cardanoNetworks}/"$NETWORK"/config.json \
              --topology ${cardanoNetworks}/"$NETWORK"/topology.json \
              --database-path ${stateDir}/db \
              --socket-path ${stateDir}/node.socket
          '';

        mithrilBootstrap = stateDir:
          mkScript "mithril-bootstrap" ''
            mkdir -p ${stateDir}
            [ -d ${stateDir}/db ] && exit 0
            case "''${SKIP_MITHRIL:-false}" in
              true) echo "Skipping Mithril; cardano-node will sync from genesis."; exit 0 ;;
              false) ;;
              *) echo "SKIP_MITHRIL must be true or false" >&2; exit 1 ;;
            esac
            # shellcheck disable=SC1090
            . ${cardanoNetworks}/"$NETWORK"/mithril.env
            export AGGREGATOR_ENDPOINT GENESIS_VERIFICATION_KEY ANCILLARY_VERIFICATION_KEY
            rm -rf ${stateDir}/download
            mithril-client --origin-tag HYDRA cardano-db download latest --backend v2 --include-ancillary --download-dir ${stateDir}/download
            mv ${stateDir}/download/db ${stateDir}/db
            rmdir ${stateDir}/download
          '';

        waitForSyncSocket = socket:
          mkScript "wait-for-sync" ''
            until progress=$(cardano-cli query tip --socket-path ${socket} --testnet-magic "$NETWORK_MAGIC" 2>/dev/null | jq -r .syncProgress) \
              && [ "$progress" = "100.00" ]; do
              echo "sync progress: ''${progress:-waiting for socket}"
              sleep 10
            done
          '';

      };
    };
}
