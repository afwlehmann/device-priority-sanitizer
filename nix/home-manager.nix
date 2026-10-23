{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  cfg = config.services.device-priority-sanitizer;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  pkg = pkgs.callPackage ./pkgs/device-priority-sanitizer { };

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
          matching devices in the dropdown. Names come from Apple's SF
          Symbols catalog (https://developer.apple.com/sf-symbols); an
          invalid name renders as a missing icon (see the package AGENTS.md).
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
      camera = lib.mkOption {
        type = lib.types.str;
        default = "video";
        description = "SF Symbol for an unmatched current camera.";
      };
    };
  };

  configJson = pkgs.writeText "device-priority-sanitizer-config.json" (
    builtins.toJSON {
      outputs = cfg.outputs;
      inputs = cfg.inputs;
      cameras = cfg.cameras;
      fallbackSymbol = cfg.fallbackSymbol;
      debounceMs = cfg.debounceMs;
      manageSoundEffects = cfg.manageSoundEffects;
    }
  );

  # Shared by the launchd definition and the !autostart activation guard.
  label = "${username}.device-priority-sanitizer";

  # Raycast script command with a static tier dropdown. The tiers are known at
  # build time (unlike the connected devices), so the argument data can be
  # generated here; the CLI resolves the chosen tier to a concrete device at
  # invocation time.
  targetOptions = {
    output = "outputs";
    input = "inputs";
    camera = "cameras";
  };

  targetLabels = {
    output = "Output";
    input = "Input";
    camera = "Camera";
  };

  targetIcons = {
    output = "🔊";
    input = "🎙️";
    camera = "🎥";
  };

  tierSetScript =
    target:
    let
      entries = cfg.${targetOptions.${target}};
      label = targetLabels.${target};
      icon = targetIcons.${target};
      argument = builtins.toJSON {
        type = "dropdown";
        placeholder = "Select ${target} tier";
        data = map (entry: {
          title = entry.title;
          value = entry.title;
        }) entries;
      };
    in
    pkgs.writeShellScript "device-priority-sanitizer-set-${target}" ''
      # @raycast.schemaVersion 1
      # @raycast.title Device Priority: Set ${label}
      # @raycast.mode silent
      # @raycast.icon ${icon}
      # @raycast.description Set the default ${target} device to the best connected device in a configured tier.
      # @raycast.author Alexander Lehmann
      # @raycast.packageName Device Priority Sanitizer
      # @raycast.argument1 ${argument}

      set -euo pipefail

      exec ${pkg}/bin/device-priority-sanitizer set ${target} --tier "$1"
    '';

  allTargets = [
    "output"
    "input"
    "camera"
  ];

  raycastCommands = [
    {
      name = "device-priority-sanitizer-reapply";
      source = "${pkg}/bin/device-priority-sanitizer-reapply";
    }
    {
      name = "device-priority-sanitizer-configure";
      source = "${pkg}/bin/device-priority-sanitizer-configure";
    }
  ]
  ++ (map (target: {
    name = "device-priority-sanitizer-cycle-${target}";
    source = "${pkg}/bin/device-priority-sanitizer-cycle-${target}";
  }) allTargets)
  # The set-<target> tier dropdown is only generated for managed targets —
  # an empty tier list means the target is not auto-managed and has no tiers
  # to offer.
  ++ (map (target: {
    name = "device-priority-sanitizer-set-${target}";
    source = tierSetScript target;
  }) (builtins.filter (target: cfg.${targetOptions.${target}} != [ ]) allTargets));

  # One-time migration from the audio-priority-sanitizer era: stops the old
  # launchd agent, removes its artifacts, and carries a *manual* (regular
  # file) config over to the new path. All steps are idempotent and tolerate
  # Home Manager's own launchd/home.file cleanup having already run (or not).
  migration =
    let
      oldLabel = "${username}.audio-priority-sanitizer";
      oldSupportDir = "${config.home.homeDirectory}/Library/Application Support/audio-priority-sanitizer";
      newConfigPath = "${config.home.homeDirectory}/Library/Application Support/device-priority-sanitizer/config.json";
      oldApplications = "${config.home.homeDirectory}/Applications";
    in
    ''
      if /bin/launchctl print "gui/$(id -u)/${oldLabel}" >/dev/null 2>&1; then
        /bin/launchctl bootout "gui/$(id -u)/${oldLabel}" 2>/dev/null || true
      fi
      ${pkgs.coreutils}/bin/rm -f "${config.home.homeDirectory}/Library/LaunchAgents/${oldLabel}.plist"
      if [ -d "${oldSupportDir}" ]; then
        if [ -f "${oldSupportDir}/config.json" ] && [ ! -e "${newConfigPath}" ]; then
          ${pkgs.coreutils}/bin/mkdir -p "${dirOf newConfigPath}"
          ${pkgs.coreutils}/bin/cp "${oldSupportDir}/config.json" "${newConfigPath}"
        fi
        ${pkgs.coreutils}/bin/rm -f "${oldSupportDir}/config.json"
        ${pkgs.coreutils}/bin/rmdir "${oldSupportDir}" 2>/dev/null || true
      fi
      ${pkgs.coreutils}/bin/rm -f "${oldApplications}"/audio-priority-sanitizer-*
    '';
in
{
  options.services.device-priority-sanitizer = {
    enable = lib.mkEnableOption "the device priority sanitizer (menubar app, CLI, Raycast commands)";

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install and load the launchd agent so the menubar app starts at
        login and is kept alive (RunAtLoad + KeepAlive). When `false`, the
        module still installs the CLI, the Raycast commands, and the config
        symlink, but nothing is launched automatically — start the app on
        demand with `device-priority-sanitizer start` (unsupervised), and
        stop it with `stop` or the Quit menu item.
      '';
    };

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

    cameras = lib.mkOption {
      type = lib.types.listOf entrySubmodule;
      default = [
        {
          title = "Built-in";
          match = "FaceTime";
          symbol = "laptopcomputer";
        }
      ];
      description = ''
        Camera priority tiers, highest first. Writes the system-preferred
        camera (`AVCaptureDevice.userPreferredCamera`); apps that follow the
        system default pick it up, apps with their own pinned camera picker
        (e.g. Zoom with an explicit camera selected) do not. Case-sensitive
        regex matched against camera names; first entry with a matching
        device wins. An empty list leaves the camera unmanaged.

        The only camera ever used on this machine is the built-in
        "FaceTime HD Camera" (verified via the AVFoundation unified log and
        Webex media logs), so the default has a single Built-in tier; add
        tiers for external cameras when they appear (`list camera` shows
        names).
      '';
    };

    fallbackSymbol = lib.mkOption {
      type = fallbackSubmodule;
      default = {
        output = "speaker.wave.3";
        input = "mic";
        camera = "video";
      };
      description = ''
        SF Symbols for a current device that matches no tier (but is not a
        synthetic transport — synthetic currents show the dedicated
        "not managed" glyph instead). Names come from Apple's SF Symbols
        catalog (https://developer.apple.com/sf-symbols); an invalid name
        renders as a missing icon (see the package AGENTS.md).
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
        # An empty list is valid: it means the target is not auto-managed
        # (see AGENTS.md). Titles must be unique and non-empty when present.
        assertion =
          lib.all (entry: entry.title != "") cfg.outputs
          && lib.length (lib.unique (map (entry: entry.title) cfg.outputs)) == lib.length cfg.outputs;
        message = "services.device-priority-sanitizer.outputs must have unique, non-empty `title` values (titles are the Raycast tier dropdown values); it may be empty to leave the output unmanaged.";
      }
      {
        assertion =
          lib.all (entry: entry.title != "") cfg.inputs
          && lib.length (lib.unique (map (entry: entry.title) cfg.inputs)) == lib.length cfg.inputs;
        message = "services.device-priority-sanitizer.inputs must have unique, non-empty `title` values (titles are the Raycast tier dropdown values); it may be empty to leave the input unmanaged.";
      }
      {
        assertion =
          lib.all (entry: entry.title != "") cfg.cameras
          && lib.length (lib.unique (map (entry: entry.title) cfg.cameras)) == lib.length cfg.cameras;
        message = "services.device-priority-sanitizer.cameras must have unique, non-empty `title` values (titles are the Raycast tier dropdown values); it may be empty to leave the camera unmanaged.";
      }
    ];

    home.packages = [ pkg ];

    home.file = {
      "Library/Application Support/device-priority-sanitizer/config.json".source = configJson;
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

    home.activation.devicePrioritySanitizerMigration = lib.hm.dag.entryAfter [
      "writeBoundary"
    ] migration;

    # autostart = false means *no* launchd presence: HM's home.file cleanup
    # removes the plist, but nothing else stops an already running job — do
    # that here, idempotently (same pattern as the migration above). With
    # autostart enabled the entry is an empty no-op: the activation option
    # must always carry a value (lib.mkIf would remove it).
    home.activation.devicePrioritySanitizerAutostart =
      lib.hm.dag.entryAfter
        [
          "writeBoundary"
          "devicePrioritySanitizerMigration"
        ]
        (
          lib.optionalString (!cfg.autostart) ''
            if /bin/launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
              /bin/launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
            fi
            ${pkgs.coreutils}/bin/rm -f "${config.home.homeDirectory}/Library/LaunchAgents/${label}.plist"
          ''
        );

    # The agent owns its log itself (directory creation, rotation to
    # agent.log.1, stream redirection — see Agent.swift), so launchd runs the
    # binary directly; the wrapper existed only for log plumbing. The store
    # config path is passed as `--config`: a bare positional argument would be
    # parsed as a CLI command.
    launchd.agents.device-priority-sanitizer = lib.mkIf cfg.autostart {
      enable = true;
      config = {
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Background";
        Label = label;
        ProgramArguments = [
          "${pkg}/Applications/device-priority-sanitizer.app/Contents/MacOS/device-priority-sanitizer"
          "--config"
          "${configJson}"
        ];
      };
    };
  };
}

# vim:set expandtab sw=2 ts=2 nowrap:
