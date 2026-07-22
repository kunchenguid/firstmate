# Windows entrypoint for the tracked Linux launcher.
# Keep all selector validation and harness mechanics in bin/fm-primary-launch.sh.
$ErrorActionPreference = "Stop"

$wslArgs = @(
    "-d", "Ubuntu",
    "-u", "firstmate",
    "--cd", "/home/firstmate/firstmate",
    "-e", "/home/firstmate/firstmate/bin/fm-primary-launch.sh"
) + $args

& wsl.exe @wslArgs
exit $LASTEXITCODE
