{
  perSystem = { recipes, ... }: {
    process-compose.single-party = recipes.mkRecipe {
      name = "single-party";
      configFile = "recipes/single-party/hydra-node.yaml";
    };
  };
}
