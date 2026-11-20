{
  perSystem = { pkgs, ... }: {
    packages.status = pkgs.writeShellApplication {
      name = "status";
      runtimeInputs = [ pkgs.bash pkgs.coreutils pkgs.jq pkgs.curl pkgs.cardano-cli pkgs.websocat ];
      text = ''exec bash ${../scripts/status.sh} "$@"'';
    };
  };
}
