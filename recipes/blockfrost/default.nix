{
  perSystem = { recipes, ... }: {
    process-compose.blockfrost = recipes.mkRecipe {
      name = "blockfrost";
    };
  };
}
