# fm-install-windows.ps1 - install Firstmate's Windows prerequisites.
#
# Run from PowerShell:
#   .\bin\fm-install-windows.ps1
#
# Installs the native tools with winget, installs Treehouse and no-mistakes
# through their official PowerShell installers, installs the required AXI
# packages globally with npm, configures their hooks, and disables this
# repository's Claude project hooks by renaming .claude/settings.json to
# .claude/settings.json.disabled.
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Native {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Assert-Command {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name was installed but is not available on PATH. Restart PowerShell and rerun this script."
    }
}

function Get-CommandVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    switch ($Command) {
        "shellcheck" {
            $versionOutput = & $Command "--version"
            if ($LASTEXITCODE -ne 0) {
                throw "$Command --version failed with exit code $LASTEXITCODE."
            }

            $versionLine = $versionOutput |
                Where-Object { $_ -match "^version:\s*" } |
                Select-Object -First 1
            if (-not $versionLine) {
                throw "Could not determine the installed $Command version."
            }

            return ($versionLine -replace "^version:\s*", "").Trim()
        }
        "actionlint" {
            $versionOutput = & $Command "-version"
            if ($LASTEXITCODE -ne 0) {
                throw "$Command -version failed with exit code $LASTEXITCODE."
            }

            return ($versionOutput | Select-Object -First 1).Trim()
        }
        default {
            throw "No version probe is defined for $Command."
        }
    }
}

function Install-WingetCommand {
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [Parameter(Mandatory)]
        [string]$Command,

        [string]$Version
    )

    Refresh-ProcessPath
    $forceVersionInstall = $false
    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        if (-not $Version) {
            Write-Host "$Command is already installed."
            return
        }

        $installedVersion = Get-CommandVersion $Command
        if ($installedVersion -eq $Version) {
            Write-Host "$Command $Version is already installed."
            return
        }

        Write-Host "Replacing $Command $installedVersion with required version $Version."
        $forceVersionInstall = $true
    }

    $wingetArguments = @(
        "install"
        "--id"
        $PackageId
        "--exact"
    )
    if ($Version) {
        $wingetArguments += @("--version", $Version)
    }
    if ($forceVersionInstall) {
        $wingetArguments += "--force"
    }
    $wingetArguments += @(
        "--accept-package-agreements"
        "--accept-source-agreements"
    )

    & winget @wingetArguments
    $wingetExitCode = $LASTEXITCODE

    Refresh-ProcessPath
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        if ($wingetExitCode -ne 0) {
            throw "winget failed to make $Command available on PATH (exit code $wingetExitCode)."
        }

        Assert-Command $Command
    }

    if ($Version) {
        $installedVersion = Get-CommandVersion $Command
        if ($installedVersion -ne $Version) {
            throw "$Command $Version is required, but version $installedVersion is first on PATH."
        }
    }
}

function Install-RemoteScriptCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string]$InstallerUrl
    )

    Refresh-ProcessPath
    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "$Command is already installed."
        return
    }

    Invoke-Expression (Invoke-RestMethod $InstallerUrl)

    Refresh-ProcessPath
    Assert-Command $Command
}

function Install-NoMistakes {
    Refresh-ProcessPath
    if (Get-Command "no-mistakes" -ErrorAction SilentlyContinue) {
        Write-Host "no-mistakes is already installed."
        return
    }

    $installerUrl = "https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.ps1"
    $installerPath = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "fm-no-mistakes-$([Guid]::NewGuid().ToString('N')).ps1"

    try {
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath
        $powerShellPath = (Get-Process -Id $PID).Path
        $installer = Start-Process `
            -FilePath $powerShellPath `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installerPath) `
            -NoNewWindow `
            -PassThru

        $installerCompleted = $installer.WaitForExit(180000)
        if (-not $installerCompleted) {
            Stop-Process -Id $installer.Id
            $installer.WaitForExit()
            Write-Warning "The no-mistakes installer exceeded three minutes and was stopped after its bounded install window."
        }
        elseif ($installer.ExitCode -ne 0) {
            throw "The no-mistakes installer failed with exit code $($installer.ExitCode)."
        }

        Refresh-ProcessPath
        Assert-Command "no-mistakes"
        Invoke-Native "no-mistakes" "daemon" "status"
    }
    finally {
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force
        }
    }
}

if ($env:OS -ne "Windows_NT") {
    throw "This installer supports Windows only."
}

Assert-Command "winget"

Install-WingetCommand "jqlang.jq" "jq"
Install-WingetCommand "koalaman.shellcheck" "shellcheck" "0.11.0"
Install-WingetCommand "rhysd.actionlint" "actionlint" "1.7.12"
Install-WingetCommand "OpenJS.NodeJS.LTS" "node"
Assert-Command "npm"

$nodeVersionText = (& node --version).TrimStart("v")
if ($LASTEXITCODE -ne 0) {
    throw "node --version failed with exit code $LASTEXITCODE."
}

$nodeVersion = [Version]$nodeVersionText
$minimumNodeVersion = [Version]"22.19.0"
if ($nodeVersion -lt $minimumNodeVersion) {
    throw "Node.js $nodeVersion is installed, but Firstmate requires at least $minimumNodeVersion."
}

Install-RemoteScriptCommand "treehouse" "https://kunchenguid.github.io/treehouse/install.ps1"
Install-NoMistakes

$axiPackages = @(
    "gh-axi",
    "chrome-devtools-axi",
    "lavish-axi",
    "tasks-axi",
    "quota-axi"
)
Invoke-Native "npm" "install" "--global" @axiPackages

Refresh-ProcessPath
foreach ($package in $axiPackages) {
    Assert-Command $package
}

Invoke-Native "gh-axi" "setup" "hooks"
Invoke-Native "chrome-devtools-axi" "setup" "hooks"
Invoke-Native "lavish-axi" "setup" "hooks"

$repoRoot = Split-Path -Parent $PSScriptRoot
$claudeSettings = Join-Path $repoRoot ".claude\settings.json"
$disabledClaudeSettings = "$claudeSettings.disabled"

if (Test-Path -LiteralPath $claudeSettings) {
    if (Test-Path -LiteralPath $disabledClaudeSettings) {
        throw "Cannot disable Claude hooks because both '$claudeSettings' and '$disabledClaudeSettings' exist."
    }

    Move-Item -LiteralPath $claudeSettings -Destination $disabledClaudeSettings
    Write-Host "Disabled repository Claude hooks: $disabledClaudeSettings"
}
elseif (Test-Path -LiteralPath $disabledClaudeSettings) {
    Write-Host "Repository Claude hooks are already disabled: $disabledClaudeSettings"
}
else {
    Write-Warning "No repository Claude settings file was found at '$claudeSettings'."
}

Write-Host ""
Write-Host "Firstmate's Windows tools are installed."
Write-Host "Restart PowerShell, Git Bash, and agent sessions so they inherit the updated PATH and hooks."
