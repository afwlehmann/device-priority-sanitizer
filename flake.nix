{
  description = "macOS menubar app and CLI that keeps the default speaker, microphone, and camera on the highest-priority device";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      git-hooks,
    }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      eachSystem = nixpkgs.lib.genAttrs systems;
      pkgsFor = eachSystem (system: nixpkgs.legacyPackages.${system});
    in
    {
      packages = eachSystem (system: {
        default = pkgsFor.${system}.callPackage ./default.nix { };
      });

      checks = eachSystem (
        system:
        let
          pkgs = pkgsFor.${system};
          pkg = self.packages.${system}.default;
        in
        {
          pre-commit-check = git-hooks.lib.${system}.run {
            src = self;
            hooks = {
              nixfmt.enable = true;
              convco.enable = true;
              shellcheck = {
                enable = true;
                # types = [] disables pre-commit's shebang-based "shell" type
                # filter, which cannot recognise the @bash@ placeholder shebang
                # used by substituteInPlace. Combined with files/excludes below,
                # this catches the shell scripts under raycast/ and test/.
                # --shell=bash forces bash dialect for @bash@-placeholder scripts
                # SC2239: shebang not an absolute path (placeholder, substituted
                # at build time)
                types = [ ];
                files = "^(raycast/|test/|scripts/)";
                excludes = [
                  "\\.(json|plist|md)$"
                ];
                args = [
                  "--shell=bash"
                  "--severity=warning"
                  "--exclude=SC2239"
                ];
              };
              shfmt = {
                enable = true;
                # types = [] (see shellcheck comment above).
                # settings.language-dialect = null and settings.simplify = false
                # remove the default -ln auto and -s from the entry. Any
                # parser/printer flag disables EditorConfig (see shfmt(1)), so
                # we must clear both. Dialect, indent, and simplify come from
                # .editorconfig's [[bash]]/[[bats]] sections.
                types = [ ];
                files = "^(raycast/|test/|scripts/)";
                excludes = [
                  "\\.(json|plist|md)$"
                ];
                settings.language-dialect = null;
                settings.simplify = false;
              };
            };
          };

          package = pkg;

          # Unit tests over the pure logic (tier matching, regex semantics,
          # cycle order, symbol mapping, plan/perform semantics, deterministic
          # menu text). Compiled and run with plain swiftc — SwiftPM cannot
          # run under the nix sandbox (see AGENTS.md).
          unit = pkgs.stdenv.mkDerivation {
            name = "device-priority-sanitizer-unit-test";
            src = self;
            nativeBuildInputs = [ pkgs.swift ];
            buildPhase = ''
              runHook preBuild
              swiftc -O \
                -module-name device_priority_sanitizer_tests \
                -o device-priority-sanitizer-unit-tests \
                Tests/DevicePrioritySanitizerTests/main.swift \
                Tests/DevicePrioritySanitizerTests/Harness.swift \
                Tests/DevicePrioritySanitizerTests/UnitTests.swift \
                Sources/DevicePrioritySanitizer/Command.swift \
                Sources/DevicePrioritySanitizer/Config.swift \
                Sources/DevicePrioritySanitizer/ConfigModel.swift \
                Sources/DevicePrioritySanitizer/State.swift \
                Sources/DevicePrioritySanitizer/Agent.swift \
                Sources/DevicePrioritySanitizer/Levels.swift \
                Sources/DevicePrioritySanitizer/MediaDevice.swift \
                Sources/DevicePrioritySanitizer/Camera.swift \
                Sources/DevicePrioritySanitizer/Priority.swift \
                Sources/DevicePrioritySanitizer/StatusMenu.swift
              runHook postBuild
            '';
            checkPhase = ''
              runHook preCheck
              ./device-priority-sanitizer-unit-tests
              runHook postCheck
            '';
            installPhase = ''
              runHook preInstall
              touch "$out"
              runHook postInstall
            '';
            doCheck = true;
          };

          # CLI integration tests: drive the built binary headlessly against
          # injected device-table fixtures (--devices) and --dry-run, one bats
          # test per behavior; exit codes asserted against sysexits.
          cli =
            pkgs.runCommandLocal "device-priority-sanitizer-cli-test"
              {
                nativeBuildInputs = [
                  pkgs.bats
                  pkgs.jq
                ];
                BIN = "${pkg}/bin/device-priority-sanitizer";
                TEST_HELPER = ./test/test_helper.sh;
              }
              ''
                set -euo pipefail
                bats ${./test}
                touch "$out"
              '';

          # swift-format over the Swift sources — check is format idempotency
          # (sources must be a fixed point of the formatter), the same gate
          # the other formatters in this repo use (nixfmt). Not a pre-commit
          # hook: pulling the Swift toolchain into `nix develop` for every
          # invocation is too heavy.
          format =
            pkgs.runCommandLocal "device-priority-sanitizer-swift-format"
              {
                nativeBuildInputs = [ pkgs.swift-format ];
                src = self;
              }
              ''
                set -euo pipefail
                cd "$src"
                mkdir -p $out/orig/src $out/orig/tests $out/fixed/src $out/fixed/tests
                cp Sources/DevicePrioritySanitizer/*.swift $out/orig/src/
                cp Tests/DevicePrioritySanitizerTests/*.swift $out/orig/tests/
                cp Sources/DevicePrioritySanitizer/*.swift $out/fixed/src/
                cp Tests/DevicePrioritySanitizerTests/*.swift $out/fixed/tests/
                swift-format format --parallel --in-place \
                  --configuration .swift-format $out/fixed/src/*.swift $out/fixed/tests/*.swift
                if ! diff -ruN $out/orig $out/fixed; then
                  echo "swift-format would reformat — run: swift-format format correctly" >&2
                  exit 1
                fi
                touch "$out"
              '';
        }
      );

      devShells = eachSystem (
        system:
        let
          pkgs = pkgsFor.${system};
          hooks = self.checks.${system}.pre-commit-check;
        in
        {
          default = pkgs.mkShellNoCC {
            inherit (hooks) shellHook;
            packages = [
              pkgs.bats
              pkgs.convco
              pkgs.gh
              pkgs.git
              pkgs.jq
              pkgs.nixd
              pkgs.nixfmt
              pkgs.shellcheck
              pkgs.shfmt
              pkgs.swift
              pkgs.swift-format
            ]
            ++ hooks.enabledPackages;
          };
        }
      );

      formatter = eachSystem (system: pkgsFor.${system}.nixfmt);

      homeManagerModules.default =
        { lib, pkgs, ... }:
        {
          imports = [ ./nix/home-manager.nix ];
          services.device-priority-sanitizer.package = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (
            lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default
          );
        };
    };
}
