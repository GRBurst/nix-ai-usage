{
  description = "Declarative AI provider usage query layer (Home Manager module + CLI)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    lib = nixpkgs.lib;
    systems = ["x86_64-linux" "aarch64-linux"];
    forAll = lib.genAttrs systems;
    pkgsFor = system: nixpkgs.legacyPackages.${system};
  in {
    homeModules = {
      default = self.homeModules.ai-usage;
      ai-usage = ./module;
    };

    checks = forAll (system: let
      pkgs = pkgsFor system;
    in {
      core = pkgs.callPackage ./checks/core {};
      config = pkgs.callPackage ./checks/config {};
      # runtime = pkgs.callPackage ./checks/runtime {};
      # module = pkgs.callPackage ./checks/module {};
    });

    formatter = forAll (system: (pkgsFor system).alejandra);
  };
}
