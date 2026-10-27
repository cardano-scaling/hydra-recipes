{
  perSystem = { recipes, ... }:
    let
      socket = ''"''${CARDANO_NODE_SOCKET_PATH:?set CARDANO_NODE_SOCKET_PATH to your existing node socket}"'';
    in
    {
      process-compose.existing-node = recipes.mkRecipe {
        name = "existing-node";
        inherit socket;
        waitFor = "wait-for-sync";
        processes.wait-for-sync.command = recipes.waitForSyncSocket socket;
      };
    };
}
