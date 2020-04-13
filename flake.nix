{
  edition = 201909;

  description = "deploy tool for nixos systems";

  outputs = { self, nixpkgs }:
  let
  in {
    overlay = import ./pkgs/overlay {};
  };
}
