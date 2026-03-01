{
  description = "Declarative nix-darwin module for kanata keyboard remapper, backed by Homebrew";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = {
    self,
    nixpkgs,
    ...
  }: {
    darwinModules.default = import ./module.nix;
  };
}
