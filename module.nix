{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.kanata;

  # Determine Homebrew prefix based on Apple Silicon vs Intel
  brewBasePath =
    if pkgs.stdenv.hostPlatform.isAarch64
    then "/opt/homebrew"
    else "/usr/local";

  brewPrefix = "${brewBasePath}/bin";

  kanataExecutable =
    if cfg.enableCmd
    then "${pkgs.kanata-with-cmd}/bin/kanata"
    else "${brewPrefix}/kanata";
  kanataTrayExecutable = "${brewPrefix}/kanata-tray";

  tomlFormat = pkgs.formats.toml {};

  # Safe fallback for user home directory
  userHome = config.users.users.${cfg.user}.home or "/Users/${cfg.user}";

  # Remove the prefix mapping logic entirely

  iconsPkg =
    if (cfg.mode == "tray" && (cfg.tray.icons.labels != {} || cfg.tray.icons.status != {}))
    then
      pkgs.runCommand "kanata-generated-icons"
      {nativeBuildInputs = [pkgs.imagemagick];}
      ''
        # Create separate output directories to avoid collisions
        mkdir -p $out/icons $out/status_icons
        FONT="${cfg.tray.icons.font}"

        if [ ! -f "$FONT" ]; then
          echo "error: TTF/OTF font not found at $FONT" >&2
          exit 1
        fi

        gen_icon() {
          local name="$1" label="$2" outdir="$3"
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
            $outdir/$name.png
        }

        # Generate into respective directories
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
            name: label: "gen_icon ${lib.escapeShellArg name} ${lib.escapeShellArg label} $out/icons"
          )
          cfg.tray.icons.labels)}

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
            name: label: "gen_icon ${lib.escapeShellArg name} ${lib.escapeShellArg label} $out/status_icons"
          )
          cfg.tray.icons.status)}
      ''
    else null;
  # Map the generated derivations back to their expected variables
  generatedLayerIcons = lib.optionalAttrs (iconsPkg != null) (lib.mapAttrs (name: _: "${iconsPkg}/icons/${name}.png") cfg.tray.icons.labels);
  generatedStatusIcons = lib.optionalAttrs (iconsPkg != null) (lib.mapAttrs (name: _: "${iconsPkg}/status_icons/${name}.png") cfg.tray.icons.status);

  layerFilesToLink = generatedLayerIcons // cfg.tray.icons.files;
  statusFilesToLink = generatedStatusIcons;

  # Create the TOML configuration blocks pointing to the correct folders
  layerIconsConfig = lib.optionalAttrs (layerFilesToLink != {}) {
    defaults.layer_icons = lib.mapAttrs (name: path: "${userHome}/Library/Application Support/kanata-tray/icons/${builtins.baseNameOf path}") layerFilesToLink;
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

  trayConfig = tomlFormat.generate "kanata-tray.toml" (
    lib.foldl lib.recursiveUpdate {} [
      {
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
      layerIconsConfig
      cfg.tray.settings
    ]
  );
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

    tray.icons.status = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Map of kanata-tray status states to custom text labels or `U+XXXX` codepoints. Keys MUST be one of: 'default', 'crash', 'pause', or 'live-reload'.";
    };

    tray.icons.labels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Map of kanata layer names to text labels or `U+XXXX` codepoints.";
    };

    tray.icons.font = lib.mkOption {
      type = lib.types.either lib.types.path lib.types.str;
      default = "${pkgs.liberation_ttf}/share/fonts/truetype/LiberationSans-Regular.ttf";
      description = "Direct path to the .ttf or .otf font file used for generated layer icons.";
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
      # Enforce strict naming for kanata-tray status icons
      assertions = [
        {
          assertion = builtins.all (name: builtins.elem name ["default" "crash" "pause" "live-reload"]) (builtins.attrNames cfg.tray.icons.status);
          message = "services.kanata.tray.icons.status keys must only be one of: 'default', 'crash', 'pause', or 'live-reload'.";
        }
      ];
      system.activationScripts.preActivation.text = lib.mkAfter ''
        # Kill running processes
        /usr/bin/pkill -x kanata 2>/dev/null || true
        /usr/bin/pkill -x kanata-tray 2>/dev/null || true
      '';
    } # 2. Add explicit cleanup when the module is DISABLED
    (lib.mkIf (!cfg.enable) {
      system.activationScripts.preActivation.text = lib.mkBefore ''
        # Unload and remove user tray agent (Tray Mode)
        if [ -e "${userHome}/Library/LaunchAgents/org.kanata.tray.plist" ]; then
          sudo --user=${cfg.user} -- /bin/launchctl unload "${userHome}/Library/LaunchAgents/org.kanata.tray.plist" 2>/dev/null || true
          rm -f "${userHome}/Library/LaunchAgents/org.kanata.tray.plist"
        fi

        # Unload and remove system daemon (Daemon Mode)
        if [ -e "/Library/LaunchDaemons/org.kanata.daemon.plist" ]; then
          /bin/launchctl unload "/Library/LaunchDaemons/org.kanata.daemon.plist" 2>/dev/null || true
          rm -f "/Library/LaunchDaemons/org.kanata.daemon.plist"
        fi
      '';
    })

    (lib.mkIf cfg.enable {
      warnings =
        lib.optional (!config.homebrew.enable)
        "services.kanata: homebrew is not enabled in your nix-darwin config, but kanata requires it to install properly.";

      # Add the Nixpkgs version to the system path if Homebrew isn't managing it
      environment.systemPackages = lib.optional cfg.enableCmd pkgs.kanata-with-cmd;

      # Everything is managed natively by Homebrew!
      homebrew.casks = ["karabiner-elements"];

      homebrew.brews =
        # Only install standard kanata from Homebrew if we aren't using the Nixpkgs cmd version
        (lib.optional (!cfg.enableCmd) "kanata")
        ++ lib.optional (cfg.mode == "tray") "kanata-tray";

      system.activationScripts.postActivation.text = lib.mkAfter ''
        ${lib.optionalString (cfg.mode == "tray") ''
                    # Clean up old stateful wrapper script if it exists
                    rm -f "${userHome}/.local/bin/sudo-kanata"

                    # Create both icon directories
                    sudo --user=${cfg.user} -- mkdir -p "${userHome}/Library/Application Support/kanata-tray/icons"
                    sudo --user=${cfg.user} -- mkdir -p "${userHome}/Library/Application Support/kanata-tray/status_icons"

                    # Symlink kanata-tray TOML config (instead of copying)
                    sudo --user=${cfg.user} -- rm -f "${userHome}/Library/Application Support/kanata-tray/kanata-tray.toml"
                    sudo --user=${cfg.user} -- ln -s ${trayConfig} "${userHome}/Library/Application Support/kanata-tray/kanata-tray.toml"

          ${lib.optionalString (layerFilesToLink != {}) ''
            # Symlink layer icons
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
                name: path: ''
                  sudo --user=${cfg.user} -- rm -f "${userHome}/Library/Application Support/kanata-tray/icons/${builtins.baseNameOf path}"
                  sudo --user=${cfg.user} -- ln -s ${path} "${userHome}/Library/Application Support/kanata-tray/icons/${builtins.baseNameOf path}"
                ''
              )
              layerFilesToLink)}
          ''}

          ${lib.optionalString (statusFilesToLink != {}) ''
            # Symlink status icons
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
                name: path: ''
                  sudo --user=${cfg.user} -- rm -f "${userHome}/Library/Application Support/kanata-tray/status_icons/${builtins.baseNameOf path}"
                  sudo --user=${cfg.user} -- ln -s ${path} "${userHome}/Library/Application Support/kanata-tray/status_icons/${builtins.baseNameOf path}"
                ''
              )
              statusFilesToLink)}
          ''}
        ''}

        ${lib.optionalString (cfg.configSource != null) ''
            # ... (rest of the file remains unchanged)        ''}

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
