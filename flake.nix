{
  description = "Firstmate — herdr + opencode runtime on Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treehouse.url = "github:kunchenguid/treehouse";
  };

  outputs = { self, nixpkgs, flake-utils, treehouse }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;

        treehousePkg = treehouse.packages.${system}.default;

        # ----------------------------------------------------------------------
        # Dev shell packages
        # ----------------------------------------------------------------------
        shellPkgs = with pkgs; [
          nodejs
          htop
          ripgrep
          jq
          python3
          file
          git
          less
          ncurses
          bashInteractive
          bash-completion
          gh
          curl
          gnutar
          perl
          procps
          shellcheck
          which
		  micro
          opencode
          herdr
          treehousePkg
        ];

      in
      {
        devShells.default = pkgs.mkShell {
          name = "firstmate";
          packages = shellPkgs;

          shellHook = ''
            # Guard: host bash may lack `complete` builtin
              if ! type complete &>/dev/null 2>&1; then
                unset BASH_COMPLETION_VERSINFO 2>/dev/null || true
              fi

              # Strip host-system PATH entries so no non-Nix binaries leak in.
              # Only /nix/store and standard Nix profile dirs survive.
              _nix_path=""
              _IFS_old="$IFS"; IFS=':'
              for _pe in $PATH; do
                case "$_pe" in
                    /nix/store/*|/run/wrappers/*|/run/current-system/sw/*|/etc/profiles/per-user/*|"$HOME"/.nix-profile/*)
                    _nix_path="''${_nix_path}:''${_pe}"
                    ;;
                esac
              done
              IFS="$_IFS_old"; unset _IFS_old _pe
              export PATH="''${_nix_path#:}"
              unset _nix_path

              # Workaround: ensure /usr/bin/env exists for #!/usr/bin/env shebangs.
              # Creates a symlink to the Nix store's env (from coreutils, always
              # present in any Nix dev shell). Tries direct link first (catches
              # bwrap sandboxes where /usr/bin is writable), then sudo (NixOS).
              if ! [ -x /usr/bin/env ] && command -v env &>/dev/null; then
                _env_bin="$(command -v env)"
                ln -sf "$_env_bin" /usr/bin/env 2>/dev/null ||
                (command -v sudo &>/dev/null && sudo ln -sf "$_env_bin" /usr/bin/env) ||
                { echo "  firstmate: WARNING could not create /usr/bin/env; scripts with #!/usr/bin/env shebangs will fail." >&2; }
                unset _env_bin
              fi

              # Ensure ~/.local/bin is on PATH (npm globals land here)
              local_bin="$HOME/.local/bin"
              mkdir -p "$local_bin"
              case ":$PATH:" in
                *:"$local_bin":*) ;;
                *) export PATH="$local_bin:$PATH" ;;
              esac

              # Ensure npm prefix is writable (Nix store default is read-only)
              npm_prefix="$HOME/.npm-global"
              mkdir -p "$npm_prefix/bin"
              npm config set prefix "$npm_prefix" 2>/dev/null || true
              case ":$PATH:" in
                *:"$npm_prefix/bin":*) ;;
                *) export PATH="$npm_prefix/bin:$PATH" ;;
              esac

              # Install npm global tools on first use (lazy, cached by npm)
            npm_globals="\
              no-mistakes \
              tasks-axi \
              quota-axi \
              lavish-axi \
              gh-axi \
              chrome-devtools-axi"

              missing=""
              for pkg in $npm_globals; do
                name="''${pkg#@*/}"
                name="''${name:-$pkg}"
                command -v "$name" >/dev/null 2>&1 || missing="$missing $pkg"
              done

              if [ -n "$missing" ]; then
                echo "  firstmate: installing npm tools:$missing"
                npm install -g $missing 2>&1 | tail -5
              fi

              # Status
              echo ""
              echo "  firstmate dev shell ready ($system)"
              for tool in opencode herdr treehouse gh node python3; do
                if ver=$(command -v "$tool" 2>/dev/null; "$tool" --version 2>/dev/null); then
                  printf "  %-12s %s\n" "$tool:" "$ver"
                else
                  printf "  %-12s NOT FOUND\n" "$tool:"
                fi
              done
              echo ""
              echo "  Launch: opencode"
              echo "  Select backend: echo herdr > config/backend"
            '';
        };
      });
}
