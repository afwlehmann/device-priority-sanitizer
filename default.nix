{
  lib,
  pkgs,
  swift,
}:

pkgs.stdenv.mkDerivation {
  pname = "device-priority-sanitizer";
  version = "0.6.0";

  # Focused source: only what the build consumes — tests and docs live in the
  # repo but must not change the package hash.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Sources
      ./raycast
      ./Info.plist
    ];
  };

  strictDeps = true;

  nativeBuildInputs = [
    swift
  ];

  buildPhase = ''
    runHook preBuild
    mkdir -p build
    swiftc -O \
      -module-name device_priority_sanitizer_module \
      -o build/device-priority-sanitizer \
      Sources/DevicePrioritySanitizer/*.swift
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # CLI on PATH (same binary as the app bundle; renamed on install).
    install -Dm 0755 build/device-priority-sanitizer $out/bin/device-priority-sanitizer

    # Minimal accessory .app bundle (LSUIElement — menubar only, no Dock).
    bundle=$out/Applications/device-priority-sanitizer.app
    install -Dm 0755 build/device-priority-sanitizer $bundle/Contents/MacOS/device-priority-sanitizer
    install -Dm 0644 Info.plist $bundle/Contents/Info.plist
    printf 'APPL????' > $bundle/Contents/PkgInfo

    # Raycast script commands delegating to the CLI.
    for script in raycast/*; do
      name=device-priority-sanitizer-$(basename $script)
      install -Dm 0755 $script $out/bin/$name
      substituteInPlace $out/bin/$name \
        --replace-fail @bash@ ${pkgs.bash}/bin/bash \
        --replace-fail @cli@ $out/bin/device-priority-sanitizer
    done

    runHook postInstall
  '';

  meta = with lib; {
    description = "macOS device priority sanitizer with menubar UI and CLI";
    homepage = "https://github.com/afwlehmann/device-priority-sanitizer";
    license = licenses.mit;
    platforms = platforms.darwin;
    mainProgram = "device-priority-sanitizer";
  };
}
