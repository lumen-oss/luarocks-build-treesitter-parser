{
  description = "devShell for Lua projects";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    gen-luarc.url = "github:mrcjkb/nix-gen-luarc-json";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    flake-parts,
    gen-luarc,
    pre-commit-hooks,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem = {
        config,
        self',
        inputs',
        pkgs,
        system,
        ...
      }: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            gen-luarc.overlays.default
            (import ./nix/overlay.nix {inherit self;})
          ];
        };
        luarc = pkgs.mk-luarc {
          plugins = with pkgs.lua51Packages; [
            luarocks
          ];
        };

        type-check = pre-commit-hooks.lib.${system}.run {
          src = self;
          hooks = {
            lua-ls = {
              enable = true;
              settings.configuration = luarc;
            };
          };
        };

        pre-commit-check = pre-commit-hooks.lib.${system}.run {
          src = self;
          hooks = {
            alejandra.enable = true;
            stylua.enable = true;
            luacheck.enable = true;
            editorconfig-checker.enable = true;
          };
        };
      in {
        devShells.default = pkgs.mkShell {
          name = "lua devShell";
          shellHook = ''
            ${pre-commit-check.shellHook}
            ln -fs ${pkgs.luarc-to-json luarc} .luarc.json
          '';
          buildInputs = with pre-commit-hooks.packages.${system};
            [
              alejandra
              lua-language-server
              stylua
              luacheck
            ]
            ++ (with pkgs; [
              (lua5_1.withPackages (ps: with ps; [luarocks luarocks-build-treesitter-parser]))
              tree-sitter
            ]);
        };

        legacyPackages.fixtures = {
          inherit
            (pkgs.lua51Packages)
            tree-sitter-haskell
            tree-sitter-rust
            tree-sitter-ocamllex
            tree-sitter-xml
            tree-sitter-toml
            tree-sitter-latex
            tree-sitter-html_tags
            tree-sitter-tmux
            ;
        };

        checks = {
          inherit
            pre-commit-check
            type-check
            ;
          inherit
            (pkgs.lua51Packages)
            tree-sitter-haskell
            tree-sitter-rust
            tree-sitter-ocamllex
            tree-sitter-xml
            tree-sitter-toml
            tree-sitter-latex
            tree-sitter-html_tags
            tree-sitter-tmux
            ;
        };
      };
    };
}
