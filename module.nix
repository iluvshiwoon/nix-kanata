{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.kanata;

  # Determine Homebrew prefix based on Apple Silicon vs Intel
  brewPrefix =
    if pkgs.stdenv.hostPlatform.isAarch64
    then "/opt/homebrew/bin"
    else "/usr/local/bin";
  kanataExecutable = "${brewPrefix}/kanata";
  kanataTrayExecutable = "${brewPrefix}/kanata-tray";

  tomlFormat = pkgs.formats.toml {};

  # Safe fallback for user home directory
  userHome = config.users.users.${cfg.user}.home or "/Users/${cfg.user}";

  # Generate icons from labels using imagemagick (tray mode only)
  generatedIcons = lib.optionalAttrs (cfg.mode == "tray" && cfg.tray.icons.labels != {}) (
    let
      iconsPkg =
        pkgs.runCommand "kanata-layer-icons"
        {nativeBuildInputs = [pkgs.imagemagick cfg.tray.icons.font];}
        ''
          mkdir -p $out
          FONT=$(find ${cfg.tray.icons.font} -name '*.ttf' -o -name '*.otf' | head -1)
          if [ -z "$FONT" ]; then
            echo "error: no TTF/OTF font found in ${cfg.tray.icons.font}" >&2
            exit 1
          fi

          gen_icon() {
            local name="$1" label="$2"
            local target=88  # 128 - 2*20 padding

            if [[ "$label" =~ ^U\+([0-9A-Fa-f]+)$ ]]; then
              label=$(printf "\\U''${BASH_REMATCH[1]}")
            fi

            magick -background none -fill white -font "$FONT" -pointsize 200 \
              label:"$label" -trim +repage \
              -resize "''${target}x''${target}" \
              -gravity center -extent 128x128 \
              $TMPDIR/glyph.png

            magick -size 128x128 xc:none \
              -fill white -draw "roundrectangle 4,4 123,123 20,20" \
              $TMPDIR/glyph.png \
              -compose Dst_Out -composite \
              $out/$name.png
          }

          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
              name: label: "gen_icon ${lib.escapeShellArg name} ${lib.escapeShellArg label}"
            )
            cfg.tray.icons.labels)}
        '';
    in
      lib.mapAttrs (name: _: "${iconsPkg}/${name}.png") cfg.tray.icons.labels
  );

  allIcons = generatedIcons // cfg.tray.icons.files;

  # FIX: Use absolute paths in the TOML so kanata-tray never loses them
  layerIconsConfig = lib.optionalAttrs (allIcons != {}) {
    defaults.layer_icons = lib.mapAttrs (name: path: "${userHome}/Library/Application Support/kanata-tray/icons/${builtins.baseNameOf path}") allIcons;
  };

  # The wrapper ensures kanata is launched via sudo but maintains process control so the tray can cleanly kill it
  sudoKanataWrapper = pkgs.writeScript "sudo-kanata" ''
    #!/bin/bash
    /usr/bin/sudo /usr/bin/pkill -x kanata 2>/dev/null
    /usr/bin/sudo ${kanataExecutable} "$@" &
    KANATA_PID=$!
    # Monitor: when this wrapper is killed (SIGKILL from kanata-tray), clean up kanata
    (while kill -0 $$ 2>/dev/null; do sleep 0.5; done
     /usr/bin/sudo /usr/bin/pkill -x kanata 2>/dev/null) &
    wait $KANATA_PID
  '';

  trayConfig = tomlFormat.generate "kanata-tray.toml" (lib.recursiveUpdate (lib.recursiveUpdate {
      defaults = {
        kanata_executable = "${sudoKanataWrapper}";
        tcp_port = 5829;
        autorestart_on_crash = true;
      };
      presets.default = {
        kanata_config = cfg.configFile;
        autorun = true;
        extra_args = ["--nodelay"];
      };
    }
    layerIconsConfig)
  cfg.tray.settings);
in {
  options.services.kanata = {
    enable = lib.mkEnableOption "kanata keyboard remapper (via Homebrew)";

    enableCmd = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use the kanata-with-cmd package to allow executing shell commands from your layout.";
    };

    mode = lib.mkOption {
      type = lib.types.enum ["daemon" "tray"];
      default = "tray";
      description = ''
        How kanata is launched:
        - `tray` (default) — kanata-tray GUI launches kanata via sudo. Shows menu bar layer icons.
        - `daemon` — headless root launchd daemon.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = config.system.primaryUser;
      description = "Username for sudoers, user agent, and file paths. Defaults to system.primaryUser.";
    };

    configFile = lib.mkOption {
      type = lib.types.str;
      default = "${userHome}/.config/kanata/kanata.kbd";
      description = "Path to kanata configuration file.";
    };

    configSource = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
      default = null;
      description = "If set, configFile will be symlinked to this path.";
    };

    tray.autostart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create a launchd user agent that starts kanata-tray automatically at login.";
    };

    tray.icons.labels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Map of kanata layer names to text labels or `U+XXXX` codepoints.";
    };

    tray.icons.font = lib.mkOption {
      type = lib.types.package;
      default = pkgs.liberation_ttf;
      description = "Font package (must contain .ttf or .otf files) used for generated layer icons.";
    };

    tray.icons.files = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      description = "Map of kanata layer names to custom icon files (PNG recommended).";
    };

    tray.settings = lib.mkOption {
      type = tomlFormat.type;
      default = {};
      description = "Extra settings merged into kanata-tray.toml.";
    };
  };

  config = lib.mkMerge [
    {
      system.activationScripts.preActivation.text = lib.mkAfter ''
        /usr/bin/pkill -x kanata 2>/dev/null || true
        /usr/bin/pkill -x kanata-tray 2>/dev/null || true
      '';
    }

    (lib.mkIf cfg.enable {
      warnings =
        lib.optional (!config.homebrew.enable)
        "services.kanata: homebrew is not enabled in your nix-darwin config, but kanata requires it to install properly.";

      # Everything is managed natively by Homebrew!
      homebrew.casks = ["karabiner-elements"];

      homebrew.taps = lib.optional cfg.enableCmd "jtroo/tap";
      homebrew.brews =
        [
          (
            if cfg.enableCmd
            then "jtroo/tap/kanata-with-cmd"
            else "kanata"
          )
        ]
        ++ lib.optional (cfg.mode == "tray") "kanata-tray";

      system.activationScripts.postActivation.text = lib.mkAfter ''
        ${lib.optionalString (cfg.mode == "tray") ''
          # Clean up old stateful wrapper script if it exists
          rm -f "${userHome}/.local/bin/sudo-kanata"

          # Symlink kanata-tray TOML config (instead of copying)
          sudo --user=${cfg.user} -- mkdir -p "${userHome}/Library/Application Support/kanata-tray/icons"
          sudo --user=${cfg.user} -- rm -f "${userHome}/Library/Application Support/kanata-tray/kanata-tray.toml"
          sudo --user=${cfg.user} -- ln -s ${trayConfig} "${userHome}/Library/Application Support/kanata-tray/kanata-tray.toml"

          ${lib.optionalString (allIcons != {}) ''
            # Symlink layer icons
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
                name: path: ''
                  sudo --user=${cfg.user} -- rm -f "${userHome}/Library/Application Support/kanata-tray/icons/${builtins.baseNameOf path}"
                  sudo --user=${cfg.user} -- ln -s ${path} "${userHome}/Library/Application Support/kanata-tray/icons/${builtins.baseNameOf path}"
                ''
              )
              allIcons)}
          ''}
        ''}

        ${lib.optionalString (cfg.configSource != null) ''
          # Symlink kanata config
          sudo --user=${cfg.user} -- mkdir -p "$(dirname "${cfg.configFile}")"
          sudo --user=${cfg.user} -- rm -f "${cfg.configFile}"
          sudo --user=${cfg.user} -- ln -s ${cfg.configSource} "${cfg.configFile}"
        ''}
      '';

      # daemon mode: root launchd daemon
      launchd.daemons.kanata = lib.mkIf (cfg.mode == "daemon") {
        serviceConfig = {
          Label = "org.kanata.daemon";
          ProgramArguments = [
            kanataExecutable
            "--cfg"
            cfg.configFile
            "--nodelay"
          ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "/tmp/kanata.log";
          StandardErrorPath = "/tmp/kanata.err";
          ThrottleInterval = 3;
        };
      };

      # tray mode: kanata-tray user agent
      launchd.user.agents.kanata-tray = lib.mkIf (cfg.mode == "tray" && cfg.tray.autostart) {
        serviceConfig = {
          Label = "org.kanata.tray";
          ProgramArguments = [kanataTrayExecutable];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "/tmp/kanata-tray.log";
          StandardErrorPath = "/tmp/kanata-tray.err";
        };
      };

      # sudoers NOPASSWD entry so the wrapper can cleanly start/stop the homebrew binary
      security.sudo.extraConfig = ''
        ${cfg.user} ALL=(ALL) NOPASSWD: ${kanataExecutable}, /usr/bin/pkill -x kanata
      '';
    })
  ];
}
