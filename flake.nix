{
  description = "firstmate — agent distro for running a crew";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname = "firstmate";
            version = "unstable";
            src = self;
            installPhase = ''
              mkdir -p $out
              cp -r . $out/
            '';
            meta = with pkgs.lib; {
              description = "Talk to one agent. Ship with a crew.";
              license = licenses.mit;
            };
          };
        }
      );
    };
}
