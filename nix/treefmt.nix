{
  perSystem = {
    treefmt = {
      projectRootFile = "flake.nix";
      programs.nixpkgs-fmt.enable = true;
      programs.shfmt.enable = true;
      programs.shellcheck.enable = true;
      programs.shellcheck.excludes = [ ".envrc" ];
    };
  };
}
