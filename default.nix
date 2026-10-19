{
  lib,
  pkgs,
  swift,
}:

pkgs.stdenv.mkDerivation {
  pname = "audio-priority-sanitizer";
  version = "0.1.0";

  src = ./.;

  strictDeps = true;

  nativeBuildInputs = [
    swift
  ];

  buildPhase = ''
    runHook preBuild
    mkdir -p build
    swiftc -O \
      -module-name audio_priority_sanitizer_module \
      -o build/audio-priority-sanitizer \
      Sources/AudioPrioritySanitizer/*.swift
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # CLI on PATH (same binary as the app bundle; renamed on install).
    install -Dm 0755 build/audio-priority-sanitizer $out/bin/audio-priority-sanitizer

    # Minimal accessory .app bundle (LSUIElement — menubar only, no Dock).
    bundle=$out/Applications/audio-priority-sanitizer.app
    install -Dm 0755 build/audio-priority-sanitizer $bundle/Contents/MacOS/audio-priority-sanitizer
    install -Dm 0644 Info.plist $bundle/Contents/Info.plist
    printf 'APPL????' > $bundle/Contents/PkgInfo

    # Raycast script commands delegating to the CLI.
    for script in raycast/*; do
      name=audio-priority-sanitizer-$(basename $script)
      install -Dm 0755 $script $out/bin/$name
      substituteInPlace $out/bin/$name \
        --replace-fail @bash@ ${pkgs.bash}/bin/bash \
        --replace-fail @cli@ $out/bin/audio-priority-sanitizer
    done

    runHook postInstall
  '';

  meta = with lib; {
    description = "macOS audio device priority sanitizer with menubar UI and CLI";
    license = licenses.mit;
    platforms = platforms.darwin;
    mainProgram = "audio-priority-sanitizer";
  };
}
