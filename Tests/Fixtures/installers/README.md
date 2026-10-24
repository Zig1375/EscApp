`probe-game.msi` is a Windows Installer package of the d3d9 probe, for the real-Wine install tests. Rebuild it with
msitools (`brew install msitools`), from this folder with `../probes/d3d9-x86.exe` copied to `payload/probegame.exe`:

    wixl -o probe-game.msi probe-game.wxs
