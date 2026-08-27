# fm-windows-git-bash.ps1 - resolve or run Git Bash without relying on PATH order.
#
# Usage:
#   . .\bin\fm-windows-git-bash.ps1
#   Resolve-FirstmateGitBash
#
#   .\bin\fm-windows-git-bash.ps1 <bash-argument> [<bash-argument> ...]
#
# Dot-source the script to use Resolve-FirstmateGitBash from another PowerShell
# script. Execute it with Bash arguments to run the resolved Git for Windows
# Bash directly instead of an ambient bash.exe that may be the WSL launcher.
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $GitBashArguments
)

function Resolve-FirstmateGitBash {
    [CmdletBinding()]
    param()

    $candidatePaths = [System.Collections.Generic.List[string]]::new()

    function Add-GitBashCandidate {
        param(
            [string]$Path
        )

        if ($Path) {
            $candidatePaths.Add($Path)
        }
    }

    $gitPaths = [System.Collections.Generic.List[string]]::new()
    $gitCommands = @(
        Get-Command "git.exe" -CommandType Application -All -ErrorAction SilentlyContinue
    )
    foreach ($gitCommand in $gitCommands) {
        $gitPaths.Add($gitCommand.Source)

        $gitItem = Get-Item -LiteralPath $gitCommand.Source -ErrorAction SilentlyContinue
        if ($gitItem) {
            $targetProperty = $gitItem.PSObject.Properties["Target"]
            if ($targetProperty -and $targetProperty.Value) {
                foreach ($target in @($targetProperty.Value)) {
                    if ([IO.Path]::IsPathRooted($target)) {
                        $gitPaths.Add($target)
                    }
                    else {
                        $gitPaths.Add((Join-Path $gitItem.DirectoryName $target))
                    }
                }
            }
        }
    }

    foreach ($gitPath in $gitPaths) {
        $gitDirectory = Split-Path -Parent $gitPath
        $gitRoot = Split-Path -Parent $gitDirectory
        Add-GitBashCandidate (Join-Path $gitRoot "bin\bash.exe")
        Add-GitBashCandidate (Join-Path $gitRoot "usr\bin\bash.exe")
    }

    $registryKeys = @(
        "HKLM:\SOFTWARE\GitForWindows",
        "HKLM:\SOFTWARE\WOW6432Node\GitForWindows",
        "HKCU:\SOFTWARE\GitForWindows"
    )
    foreach ($registryKey in $registryKeys) {
        $gitProperties = Get-ItemProperty `
            -LiteralPath $registryKey `
            -Name "InstallPath" `
            -ErrorAction SilentlyContinue
        if ($gitProperties -and $gitProperties.InstallPath) {
            Add-GitBashCandidate (Join-Path $gitProperties.InstallPath "bin\bash.exe")
            Add-GitBashCandidate (Join-Path $gitProperties.InstallPath "usr\bin\bash.exe")
        }
    }

    Add-GitBashCandidate (Join-Path $env:ProgramFiles "Git\bin\bash.exe")
    Add-GitBashCandidate (Join-Path $env:LOCALAPPDATA "Programs\Git\bin\bash.exe")

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($candidatePath in $candidatePaths) {
        if (-not $seenPaths.Add($candidatePath)) {
            continue
        }
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidatePath).Path
        }
    }

    throw "Git Bash was not found. Run .\bin\fm-install-windows.ps1 to install Git for Windows, then retry."
}

if ($MyInvocation.InvocationName -eq ".") {
    return
}

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $GitBashArguments -or $GitBashArguments[0] -in @("-h", "--help")) {
    Write-Output "usage: fm-windows-git-bash.ps1 <bash-argument> [<bash-argument> ...]"
    if (-not $GitBashArguments) {
        exit 2
    }
    exit 0
}

$gitBashPath = Resolve-FirstmateGitBash
& $gitBashPath @GitBashArguments
exit $LASTEXITCODE
