{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  cfg = config.services.audio-priority-sanitizer;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  pkg = pkgs.callPackage ./pkgs/audio-priority-sanitizer { };

  entrySubmodule = lib.types.submodule {
    options = {
      title = lib.mkOption {
        type = lib.types.str;
        description = ''
          Human-readable name of the tier, used by `set --tier` and as the
          value in the generated Raycast dropdown. Must be unique per
          direction.
        '';
      };

      match = lib.mkOption {
        type = lib.types.str;
        description = ''
          Case-sensitive regex matched against device names. Entries are
          evaluated in list order — the first entry with a matching device
          wins, so the list order *is* the priority.
        '';
      };

      symbol = lib.mkOption {
        type = lib.types.str;
        description = ''
          SF Symbol shown for this tier: in the menubar slots and next to the
          matching devices in the dropdown.
        '';
      };
    };
  };

  fallbackSubmodule = lib.types.submodule {
    options = {
      output = lib.mkOption {
        type = lib.types.str;
        description = "SF Symbol for an unmatched current output device.";
      };
      input = lib.mkOption {
        type = lib.types.str;
        description = "SF Symbol for an unmatched current input device.";
      };
    };
  };

  configJson = pkgs.writeText "audio-priority-sanitizer-config.json" (
    builtins.toJSON {
      outputs = cfg.outputs;
      inputs = cfg.inputs;
      fallbackSymbol = cfg.fallbackSymbol;
      debounceMs = cfg.debounceMs;
      manageSoundEffects = cfg.manageSoundEffects;
    }
  );

  logDir = "${config.home.homeDirectory}/Library/Logs/audio-priority-sanitizer";

  # Creates the log directory and rotates the previous run's log to
  # agent.log.1 on every launch (including KeepAlive crash restarts), so a
  # crash loop keeps its evidence while growth stays bounded. The app's stdio
  # is redirected here rather than via launchd's StandardOutPath: launchd opens
  # that file before exec'ing this wrapper, which would keep writing through
  # the descriptor of the renamed inode. Then execs the app with the store-path
  # config. The config is passed as `--config`: a bare positional argument
  # would be parsed as a CLI command.
  agentWrapper = pkgs.writeShellScript "audio-priority-sanitizer-agent" ''
    set -eu
    ${pkgs.coreutils}/bin/mkdir -p "${logDir}"
    if [ -f "${logDir}/agent.log" ]; then
      ${pkgs.coreutils}/bin/mv -f "${logDir}/agent.log" "${logDir}/agent.log.1" || true
    fi
    exec "${pkg}/Applications/audio-priority-sanitizer.app/Contents/MacOS/audio-priority-sanitizer" \
      --config "${configJson}" >>"${logDir}/agent.log" 2>&1
  '';

  # Raycast script command with a static tier dropdown. The tiers are known at
  # build time (unlike the connected devices), so the argument data can be
  # generated here; the CLI resolves the chosen tier to a concrete device at
  # invocation time.
  tierSetScript =
    direction:
    let
      isOutput = direction == "output";
      entries = if isOutput then cfg.outputs else cfg.inputs;
      label = if isOutput then "Output" else "Input";
      icon = if isOutput then "🔊" else "🎙️";
      argument = builtins.toJSON {
        type = "dropdown";
        placeholder = "Select ${direction} tier";
        data = map (entry: {
          title = entry.title;
          value = entry.title;
        }) entries;
      };
    in
    pkgs.writeShellScript "audio-priority-sanitizer-set-${direction}" ''
      # @raycast.schemaVersion 1
      # @raycast.title Audio Priority: Set ${label}
      # @raycast.mode silent
      # @raycast.icon ${icon}
      # @raycast.description Set the default ${direction} device to the best connected device in a configured tier.
      # @raycast.author Alexander Lehmann
      # @raycast.packageName Audio Priority Sanitizer
      # @raycast.argument1 ${argument}

      set -euo pipefail

      exec ${pkg}/bin/audio-priority-sanitizer set ${direction} --tier "$1"
    '';

  raycastCommands = [
    {
      name = "audio-priority-sanitizer-reapply";
      source = "${pkg}/bin/audio-priority-sanitizer-reapply";
    }
    {
      name = "audio-priority-sanitizer-cycle-output";
      source = "${pkg}/bin/audio-priority-sanitizer-cycle-output";
    }
    {
      name = "audio-priority-sanitizer-cycle-input";
      source = "${pkg}/bin/audio-priority-sanitizer-cycle-input";
    }
    {
      name = "audio-priority-sanitizer-set-output";
      source = tierSetScript "output";
    }
    {
      name = "audio-priority-sanitizer-set-input";
      source = tierSetScript "input";
    }
  ];
in
{
  options.services.audio-priority-sanitizer = {
    enable = lib.mkEnableOption "the audio device priority sanitizer (menubar app, CLI, Raycast commands)";

    outputs = lib.mkOption {
      type = lib.types.listOf entrySubmodule;
      default = [
        {
          title = "Headset";
          match = "Evolve|WH-1000|Rienok|EarPods";
          symbol = "headphones";
        }
        {
          title = "Speaker";
          match = "SPEAK 510";
          symbol = "hifispeaker.fill";
        }
        {
          title = "Built-in";
          match = "MacBook Pro Speakers|Built-in";
          symbol = "laptopcomputer";
        }
      ];
      description = ''
        Output priority tiers, highest first. Case-sensitive regex matched
        against device names; first entry with a matching device wins.
      '';
    };

    inputs = lib.mkOption {
      type = lib.types.listOf entrySubmodule;
      default = [
        {
          title = "Headset";
          match = "Evolve|WH-1000|Rienok|EarPods";
          symbol = "headphones";
        }
        {
          title = "Speaker";
          match = "SPEAK 510";
          symbol = "hifispeaker.fill";
        }
        {
          title = "Built-in";
          match = "MacBook Pro Microphone|Built-in";
          symbol = "laptopcomputer";
        }
      ];
      description = ''
        Input priority tiers, highest first. Fully independent of `outputs`:
        different device sets and orders are allowed.
      '';
    };

    fallbackSymbol = lib.mkOption {
      type = fallbackSubmodule;
      default = {
        output = "speaker.wave.3";
        input = "mic";
      };
      description = ''
        SF Symbols for a current device that matches no tier (but is not a
        synthetic transport — synthetic currents show the dedicated
        "not managed" glyph instead).
      '';
    };

    debounceMs = lib.mkOption {
      type = lib.types.int;
      default = 500;
      description = ''
        Debounce window for `kAudioHardwarePropertyDevices` churn — multiple
        rapid device-list notifications coalesce into one priority pass.
      '';
    };

    manageSoundEffects = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Mirror the macOS sound-effects/alert device
        (`kAudioHardwarePropertyDefaultSystemOutputDevice`) whenever this app
        sets the output device, matching what changing the output device in
        System Settings does. Set to `false` to leave the effects device
        untouched, e.g. to pin alerts to a specific device.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && isDarwin) {
    assertions = [
      {
        assertion =
          cfg.outputs != [ ]
          && lib.all (entry: entry.title != "") cfg.outputs
          && lib.length (lib.unique (map (entry: entry.title) cfg.outputs)) == lib.length cfg.outputs;
        message = "services.audio-priority-sanitizer.outputs must be non-empty with unique, non-empty `title` values (titles are the Raycast tier dropdown values).";
      }
      {
        assertion =
          cfg.inputs != [ ]
          && lib.all (entry: entry.title != "") cfg.inputs
          && lib.length (lib.unique (map (entry: entry.title) cfg.inputs)) == lib.length cfg.inputs;
        message = "services.audio-priority-sanitizer.inputs must be non-empty with unique, non-empty `title` values (titles are the Raycast tier dropdown values).";
      }
    ];

    home.packages = [ pkg ];

    home.file = {
      "Library/Application Support/audio-priority-sanitizer/config.json".source = configJson;
    }
    // (builtins.listToAttrs (
      map (command: {
        name = "Applications/${command.name}";
        value = {
          executable = true;
          source = command.source;
        };
      }) raycastCommands
    ));

    launchd.agents.audio-priority-sanitizer = {
      enable = true;
      config = {
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Background";
        Label = "${username}.audio-priority-sanitizer";
        ProgramArguments = [ "${agentWrapper}" ];
      };
    };
  };
}

# vim:set expandtab sw=2 ts=2 nowrap:
