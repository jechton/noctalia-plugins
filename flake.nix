{
  description = "jechton's Noctalia plugins";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    noctalia.url = "github:noctalia-dev/noctalia-shell";
    noctalia-official-plugins = {
      url = "github:noctalia-dev/official-plugins";
      flake = false;
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.pre-commit-hooks.flakeModule
      ];

      perSystem =
        {
          pkgs,
          config,
          system,
          lib,
          ...
        }:
        let
          noctalia = inputs.noctalia.packages.${system}.default;

          # Every immediate subdirectory that holds a plugin.toml.
          pluginNames = lib.attrNames (
            lib.filterAttrs (
              name: type: type == "directory" && builtins.pathExists (./. + "/${name}/plugin.toml")
            ) (builtins.readDir ./.)
          );
        in
        {
          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              keep-sorted.enable = true;
              nixfmt.enable = true;
              stylua.enable = true;
              taplo.enable = true;
            };
            settings.global.excludes = [
              "LICENSE"
              "*.md"
              "*.json"
              "noctalia.d.luau"
            ];
          };

          pre-commit.settings.hooks = {
            treefmt.enable = true;
            noctalia-lint = {
              enable = true;
              name = "noctalia plugins lint";
              entry = "${lib.getExe' noctalia "noctalia"} plugins lint";
              files = "^[^/]+/(plugin\\.toml|.*\\.luau)$";
              pass_filenames = false;
              args = pluginNames;
            };
          };

          # `nix flake check` validates every plugin the same way CI does.
          checks.lint = pkgs.runCommandLocal "noctalia-plugins-lint" { nativeBuildInputs = [ noctalia ]; } ''
            export HOME="$TMPDIR"
            cd ${./.}
            status=0
            for dir in ${lib.concatStringsSep " " pluginNames}; do
              echo "== $dir =="
              noctalia plugins lint "$dir" || status=1
            done
            [ "$status" -eq 0 ] || exit 1
            touch "$out"
          '';

          devShells.default = pkgs.mkShell {
            packages = [
              noctalia
              pkgs.luau-lsp
              pkgs.stylua
              pkgs.taplo
            ]
            ++ config.pre-commit.settings.enabledPackages;

            shellHook = ''
              ${config.pre-commit.installationScript}
              # Drop luau-lsp type definitions into each plugin dir (gitignored).
              for dir in ${lib.concatStringsSep " " pluginNames}; do
                cp -f ${inputs.noctalia-official-plugins}/noctalia.d.luau "$dir/noctalia.d.luau"
              done
            '';
          };

          formatter = config.treefmt.build.wrapper;
        };
    };
}
