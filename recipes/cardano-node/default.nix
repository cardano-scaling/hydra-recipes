{
  perSystem = { recipes, ... }:
    let
      stateDir = "state/cardano-node";
      socket = "${stateDir}/node.socket";
    in
    {
      process-compose.cardano-node = recipes.mkRecipe {
        name = "cardano-node";
        inherit socket;
        waitFor = "wait-for-sync";
        processes = {
          mithril-bootstrap = {
            command = recipes.mithrilBootstrap stateDir;
            log_location = "${stateDir}/logs/mithril-bootstrap.log";
          };
          cardano-node = {
            command = recipes.cardanoNode stateDir;
            depends_on.mithril-bootstrap.condition = "process_completed_successfully";
            availability.restart = "on_failure";
            log_location = "${stateDir}/logs/cardano-node.log";
          };
          wait-for-sync = {
            command = recipes.waitForSyncSocket socket;
            depends_on.cardano-node.condition = "process_started";
          };
        };
      };
    };
}
