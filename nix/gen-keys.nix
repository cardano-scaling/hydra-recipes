{
  perSystem = { pkgs, ... }: {
    packages.gen-keys = pkgs.writeShellApplication {
      name = "gen-keys";
      runtimeInputs = [ pkgs.bash pkgs.coreutils pkgs.hydra-node pkgs.cardano-cli ];
      text = "exec bash ${../scripts/gen-keys.sh}";
    };
  };
}
