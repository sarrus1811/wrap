# 1. Automatically Relaunch in PowerShell 7 as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($PSVersionTable.PSVersion.Major -lt 7 -or -not $isAdmin) {
    Write-Host "Legacy PowerShell or standard privileges detected. Relaunching in PowerShell 7 as Administrator..." -ForegroundColor Yellow
    $pwshPath = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 
        (Get-Command pwsh.exe).Source 
    }
    elseif (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe") {
        "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    }
    else {
        "pwsh.exe"
    }
    
    try {
        Start-Process -FilePath $pwshPath -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -ErrorAction Stop
        exit
    }
    catch {
        Write-Host "[✗] Failed to launch pwsh.exe. Ensure PowerShell 7 is installed." -ForegroundColor Red
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        Pause
        exit
    }
}

$env:IgnoreSpectreEncoding = $true
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Show-ProgramDetails {
    param (
        [psobject]$program
    )
    Write-Host "`n--- Program Details ---" -ForegroundColor Blue
    Write-Host "Name: $($program.Name)"
    Write-Host "Category: $($program.Category -join ', ')"
    Write-Host "Source: $($program.Source -join ', ')"
    Write-Host "Description: $($program.Description)"
    Write-Host "Documentation: $($program.Documentation)"
}

function Get-ProgramList {
    param (
        [psobject[]]$list
    )
    Write-Host "Listing all the programs..." -ForegroundColor Blue
    Write-Host "---------------------------" -ForegroundColor Blue
    Write-Host "Name                                            Category"
    Write-Host "----                                            --------"
    foreach ($program in $list) {
        if ($null -ne $program.Name -and $null -ne $program.Category) {
            Write-Output ("{0,-47} {1}" -f $program.Name, ($program.Category -join ', '))
        }
    }
}

function Get-CategoryWithCounts {
    param (
        [psobject[]]$list
    )
    $categoryCounts = @{}
    foreach ($item in $list) {
        foreach ($category in $item.Category) {
            if ($categoryCounts.ContainsKey($category)) {
                $categoryCounts[$category]++
            }
            else {
                $categoryCounts[$category] = 1
            }
        }
    }
    Write-Host "Category                      Count" -ForegroundColor Blue
    Write-Host "--------                      -----" -ForegroundColor Blue
    $categoryCounts.GetEnumerator() | Sort-Object Name | ForEach-Object {
        Write-Output ("{0,-30} {1}" -f $_.Name, $_.Value)
    }
}

function Get-ProgramsByCategory {
    param (
        [psobject[]]$list,
        [string]$category
    )
    Write-Host "Name                            Category" -ForegroundColor Blue
    Write-Host "----                            --------" -ForegroundColor Blue
    foreach ($program in $list) {
        if ($null -ne $program.Name -and $null -ne $program.Category) {
            if ($program.Category -contains $category) {
                Write-Output ("{0,-31} {1}" -f $program.Name, ($program.Category -join ', '))
            }
        }
    }
}

function Get-ProgramByName {
    param (
        [psobject[]]$list,
        [string]$name
    )
    try {
        foreach ($program in $list) {
            if ($program.Name -ieq $name) {
                # returns the object. All output will be handled by the calling function.
                return $program
            }
        }
        return $null
    }
    catch {
        Write-Error "An error occurred while processing the program list."
        Write-Error $_.Exception.Message
        return $null
    }
}

# Check if Visual Studio Build tools are installed (Updated for VS 2026)
function Invoke-VisualCppCheck {
    $BuildToolsId = "Microsoft.VisualStudio.BuildTools"
    $VCToolsWorkload = "Microsoft.VisualStudio.Workload.VCTools"

    Write-Host "`n--- Checking for existing Visual C++ Build Tools ---" -ForegroundColor Cyan

    $InstallCheck = winget list --id $BuildToolsId --exact 2>$null
    if ($InstallCheck -match $BuildToolsId) {
        Write-Host "[✓] Microsoft Visual Studio Build Tools found." -ForegroundColor Green
        return
    }

    Write-Host "Visual C++ Build Tools not found. Starting silent installation (this WILL take several minutes/gigabytes)..." -ForegroundColor Yellow
    
    $OverrideArgs = "--quiet --wait --norestart --add $VCToolsWorkload --includeRecommended"

    $wingetArgs = @(
        "install", "-e", "--id", $BuildToolsId, 
        "--source", "winget", 
        "--override", $OverrideArgs,
        "--accept-package-agreements",
        "--accept-source-agreements"
    )

    try {
        & winget @wingetArgs
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) { 
            Write-Host "[✓] Installation complete!" -ForegroundColor Green
        }
        else {
            Write-Host "[✗] Installation failed with exit code $LASTEXITCODE." -ForegroundColor Red
        }
    }
    catch {
        Write-Host "[✗] Installation failed. Error details: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- Environment / Pre-requisite Checks ---
# Test internet connection over HTTPS
function Test-Internet {
    Write-Host "--- Checking Internet Connection ---" -ForegroundColor Cyan
    
    $oldProgress = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    
    try {
        $null = Invoke-WebRequest -Uri "https://github.com" -Method Head -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-Host "[✓] Connected to the internet (GitHub accessible)." -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "[✗] Internet seems disconnected or GitHub is blocked." -ForegroundColor Red
        return $false
    }
    finally {
        $ProgressPreference = $oldProgress
    }
}

# Check Firewall status
function Test-Firewall {
    try {
        $service = Get-Service -Name "MpsSvc" -ErrorAction Stop
        if ($service.Status -eq "Running") {
            Write-Host "[!] Windows Firewall is running." -ForegroundColor Yellow
            return $true
        }
        else {
            Write-Host "[✓] Windows Firewall is not running." -ForegroundColor Green
            return $false
        }
    }
    catch {
        Write-Host "An error occurred while checking the Windows Firewall service." -ForegroundColor Red
        return $false
    }
}

# Test if the Windows Defender Antivirus service is running
function Test-Defender {
    try {
        $service = Get-Service -Name "WinDefend" -ErrorAction Stop
        if ($service.Status -eq "Running") {
            Write-Host "[!] Windows Defender is running." -ForegroundColor Yellow
            return $true
        }
        else {
            Write-Host "[✓] Windows Defender is not running." -ForegroundColor Green
            return $false
        }
    }
    catch {
        Write-Host "An error occurred while checking the Windows Defender service." -ForegroundColor Red
        return $false
    }
}

# Test if Windows Update service is enabled
function Test-WindowsUpdate {
    try {
        $service = Get-Service -Name "wuauserv" -ErrorAction Stop
        if ($service.StartType -ne "Disabled") {
            Write-Host "[!] Windows Update is not disabled (Current State: $($service.StartType)). This may cause network noise." -ForegroundColor Yellow
            return $true
        }
        else {
            Write-Host "[✓] Windows Update is disabled." -ForegroundColor Green
            return $false
        }
    }
    catch {
        Write-Host "An error occurred while checking the Windows Update service." -ForegroundColor Red
        return $false
    }
}

# Scaffold required directories
function Invoke-FolderCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Folders
    )
    
    foreach ($Folder in $Folders) {
        if (-not (Test-Path -Path $Folder -PathType Container)) {
            Write-Host "Directory '$Folder' does not exist. Creating..." -ForegroundColor DarkGray
            try {
                $newFolder = New-Item -Path $Folder -ItemType Directory -Force
                Write-Host "[✓] Directory: $($newFolder.FullName) created successfully." -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to create directory '$Folder'. Error: $($_.Exception.Message)"
            }
        }
        else {
            Write-Host "[✓] Directory '$Folder' already exists." -ForegroundColor Green
        }
    }
}

# Check for git installations
function Invoke-GitCheck {
    $GitPackageId = "Git.Git"
    Write-Host "`n--- Checking for Git installation ---" -ForegroundColor Cyan

    try {
        $GitPath = Get-Command git.exe -ErrorAction Stop | Select-Object -ExpandProperty Path
        Write-Host "[✓] Git found at: $GitPath" -ForegroundColor Green
        return
    }
    catch {
        Write-Host "Git executable not found in PATH. Initiating installation via winget..." -ForegroundColor Yellow
    }

    $wingetArgs = @(
        "install", "-e", "--id", $GitPackageId, 
        "--source", "winget", 
        "--silent", 
        "--accept-package-agreements", 
        "--accept-source-agreements", 
        "--disable-interactivity"
    )

    & winget @wingetArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[✓] Successfully installed Git." -ForegroundColor Green
    }
    else {
        Write-Host "[✗] Git installation failed. Check winget error output." -ForegroundColor Red
    }
}

# Check for mise
function Invoke-MiseCheck {
    $MisePackageId = "jdx.mise"
    Write-Host "`n--- Checking for mise installation ---" -ForegroundColor Cyan

    try {
        $MisePath = Get-Command mise.exe -ErrorAction Stop | Select-Object -ExpandProperty Path
        Write-Host "[✓] mise found at: $MisePath" -ForegroundColor Green
        return
    }
    catch {
        Write-Host "mise executable not found in PATH. Initiating installation via winget..." -ForegroundColor Yellow
    }

    $wingetArgs = @(
        "install", "-e", "--id", $MisePackageId, 
        "--source", "winget", 
        "--silent", 
        "--accept-package-agreements", 
        "--accept-source-agreements", 
        "--disable-interactivity"
    )
    & winget @wingetArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[✓] Successfully installed mise." -ForegroundColor Green
    }
    else {
        Write-Host "[✗] mise installation failed. Check winget error output." -ForegroundColor Red
    }
}

# Check if Visual Studio Build tools are installed
function Invoke-VisualCppCheck {
    $BuildToolsId = "Microsoft.VisualStudio.2022.BuildTools"
    $VCToolsWorkload = "Microsoft.VisualStudio.Workload.VCTools"

    Write-Host "`n--- Checking for existing Visual C++ Build Tools ---" -ForegroundColor Cyan

    $InstallCheck = winget list --id $BuildToolsId --exact 2>$null
    if ($InstallCheck -match $BuildToolsId) {
        Write-Host "[✓] Microsoft Visual Studio 2022 Build Tools found." -ForegroundColor Green
        return
    }

    Write-Host "Visual C++ Build Tools not found. Starting silent installation (this WILL take several minutes/gigabytes)..." -ForegroundColor Yellow
    
    $OverrideArgs = "--quiet --wait --norestart --add $VCToolsWorkload --includeRecommended"

    $wingetArgs = @(
        "install", "-e", "--id", $BuildToolsId, 
        "--source", "winget", 
        "--override", $OverrideArgs,
        "--accept-package-agreements",
        "--accept-source-agreements"
    )

    try {
        & winget @wingetArgs
        
        # 3010 - exit code for "Success, but a reboot is required"
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) { 
            Write-Host "[✓] Installation complete!" -ForegroundColor Green
        }
        else {
            Write-Host "[✗] Installation failed with exit code $LASTEXITCODE." -ForegroundColor Red
        }
    }
    catch {
        Write-Host "[✗] Installation failed. Error details: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Check if PwshSpectreConsole is installed, and install if missing
function Invoke-SpectreCheck {
    Write-Host "`n--- Checking for PwshSpectreConsole ---" -ForegroundColor Cyan
    if (Get-Module -ListAvailable -Name PwshSpectreConsole) {
        Write-Host "[✓] PwshSpectreConsole module found." -ForegroundColor Green
        return
    }

    Write-Host "PwshSpectreConsole not found. Initiating silent installation from PSGallery..." -ForegroundColor Yellow
    
    try {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        
        Install-Module -Name PwshSpectreConsole -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        
        Write-Host "[✓] Successfully installed PwshSpectreConsole." -ForegroundColor Green
    }
    catch {
        Write-Host "[✗] Failed to install PwshSpectreConsole." -ForegroundColor Red
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Init {
    Write-Host "`n--- Checking Prerequisites ---" -ForegroundColor Cyan
    
    $ScopeToCheck = "CurrentUser"
    Write-Host "Checking PowerShell Execution Policy for scope: $($ScopeToCheck)..." -ForegroundColor Yellow
    $currentPolicy = Get-ExecutionPolicy -Scope $ScopeToCheck
    if ($currentPolicy -ne "Unrestricted") {
        Write-Host "[✗] - The execution policy for '$ScopeToCheck' is set to '$currentPolicy'. This is NOT Unrestricted." -ForegroundColor Red
    }
    
    $null = Test-Internet
    $null = Test-Firewall
    $null = Test-Defender
    $null = Test-WindowsUpdate
    Invoke-FolderCheck -Folders @("C:\WRAP", "C:\WRAP\bin", "C:\WRAP\mise", "C:\WRAP\plugins")
    Invoke-GitCheck
    Invoke-MiseCheck
    Invoke-VisualCppCheck
    Invoke-SpectreCheck
    Import-Module PwshSpectreConsole -Global 
    Write-Host "`n-------------------------------------" -ForegroundColor Cyan
    if ($Host.UI.RawUI.KeyAvailable -or [System.Environment]::UserInteractive) {
        Write-Host "Press Enter to continue..." -ForegroundColor Cyan
        $null = Read-Host
    }
}

# --- Installation Helper Functions ---
# Installs IDA plugins
function Install-idaPlugins {
    param(
        [string]$Location
    )
    Write-Host "`nInstalling IDA plugins into $Location" -ForegroundColor Cyan

    # Change to the IDA plugins directory before cloning
    $PluginPath = Join-Path $Location "plugins"
    if (-not (Test-Path $PluginPath)) { New-Item -ItemType Directory -Path $PluginPath | Out-Null }
    Set-Location $PluginPath

    Invoke-Expression "git clone https://github.com/mandiant/capa.git"
    Invoke-Expression "git clone https://github.com/airbus-cert/comida.git"
    Invoke-Expression "git clone https://github.com/danigargu/deREferencing.git"
    Invoke-Expression "git clone https://github.com/joxeankoret/diaphora.git"
    Invoke-Expression "git clone https://github.com/mandiant/flare-ida.git"
    Invoke-Expression "git clone https://github.com/hasherezade/ida_ifl.git"
    Invoke-Expression "git clone https://github.com/patois/xray.git"
    Invoke-Expression "git clone https://github.com/mandiant/xrefer.git"
}

# Install x64dbg plugins
function Install-x64dbgPlugins {
    param(
        [string]$Location
    )
    Write-Host "`nInstalling x64dbg plugins into $Location" -ForegroundColor Cyan

    $PluginPath = Join-Path $Location "plugins"
    if (-not (Test-Path $PluginPath)) { New-Item -ItemType Directory -Path $PluginPath | Out-Null }
    Set-Location $PluginPath

    Invoke-Expression "git clone https://github.com/x64dbg/ScyllaHide.git"
    Invoke-Expression "git clone https://github.com/mrexodia/TitanHide.git"
    Invoke-Expression "git clone https://github.com/therealdreg/DbgChild.git"
}

# Install program using Winget
function Invoke-WingetInstall {
    param (
        [string[]]$Source,
        [string]$programName
    )

    $ID = $Source[1]
    $location = "C:\WRAP\$programName"

    Write-Host "Executing winget install for $programName ($ID)..." -ForegroundColor Cyan
    
    # Use array splatting instead of Invoke-Expression to safely handle args
    $wingetArgs = @(
        "install", "-e", $ID, 
        "--location", $location, 
        "--silent", 
        "--accept-package-agreements", 
        "--accept-source-agreements", 
        "--disable-interactivity"
    )
    
    & winget @wingetArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[✓] Successfully installed $programName." -ForegroundColor Green
        
        # Fixed dispatch logic
        if ($ID -ieq "Hex-Rays.IDA.Free") {
            Install-idaPlugins -Location $location
        }
        elseif ($ID -ieq "x64dbg.x64dbg") {
            Install-x64dbgPlugins -Location $location
        }
    }
    else {
        Write-Host "[✗] Winget installation failed for $programName with exit code $LASTEXITCODE." -ForegroundColor Red
    }
}

# Install using mise
function Invoke-MiseInstall {
    param (
        [Parameter(Mandatory = $true)][string]$MiseBackendSpec # e.g. "pypi:angr" or "github:hasherezade/pe-sieve"
    )
    
    Write-Host "Executing mise install for: $MiseBackendSpec" -ForegroundColor Cyan
    
    # Run mise install. The @latest tag forces it to grab the newest version
    $command = "mise use --global `"$MiseBackendSpec@latest`""
    Invoke-Expression $command

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[✓] Successfully installed $MiseBackendSpec via mise." -ForegroundColor Green
    }
    else {
        Write-Host "[✗] mise installation failed for $MiseBackendSpec." -ForegroundColor Red
    }
}

# Install directly
function Invoke-DirectInstall {
    param (
        [string]$Url,
        [string]$ProgramName
    )
    $DestDir = "C:\WRAP\$ProgramName"
    Invoke-FolderCheck -Folders @($DestDir)
    $FileName = [System.IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)
    $OutFile = Join-Path $DestDir $FileName

    Write-Host "`nDownloading $ProgramName from $Url..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing

    if ($FileName -match '\.msi$') {
        Write-Host "Installing MSI package for $ProgramName..." -ForegroundColor Cyan
        Start-Process "msiexec.exe" -ArgumentList "/i `"$OutFile`" /qn /norestart INSTALLDIR=`"$DestDir`"" -Wait
    }
    elseif ($FileName -match '\.zip$') {
        Expand-Archive -Path $OutFile -DestinationPath $DestDir -Force
        Remove-Item $OutFile -Force
    }
    Write-Host "[✓] Installed $ProgramName to $DestDir" -ForegroundColor Green
}

# Main installer function
function Install-Program {
    param (
        [psobject]$program
    )

    if ($program.Source.Count -gt 0) {
        $installer = $program.Source[0].ToLower()
        Write-Host "`nInstalling $($program.Name)..." -ForegroundColor Yellow
        
        switch ($installer) {
            "winget" {
                Invoke-WingetInstall -Source $program.Source -programName $program.Name
            }
            "mise" {
                # Setup Visual C++ Environment prior to compilation if marked in the schema
                if ($program.RequiresCpp) {
                    Invoke-VisualCppCheck
                    Write-Host "Attempting C++ Build Environment setup for compilation..." -ForegroundColor Yellow
                    Invoke-VisualStudioEnvironment
                }
                
                Invoke-MiseInstall -MiseBackendSpec $program.Source[1]
            }
            "other" {
                if ($Program.Source[1]) {
                    Invoke-DirectInstall -Url $Program.Source[1] -ProgramName $Program.Name
                }
            }
            Default {
                Write-Host "Installer type '$installer' not recognized. Cannot install $($program.Name)." -ForegroundColor Red
            }
        }
    }
}
# --- Menu Functions ---
function Invoke-FindFunctions {
    param (
        [psobject[]]$list
    )

    $searchMenuItems = @(
        "Find a program",
        "Find programs by category",
        "List all programs",
        "List categories",
        "List installed programs",
        "Return to Main Menu"
    )

    Clear-Host
    $selection = Read-SpectreSelection -Title "[bold yellow]--- Search Options ---[/]" -Choices $searchMenuItems -Color Blue

    switch ($selection) {
        "Find a program" {
            $programName = Read-SpectreText -Message "Search for"
            $foundProgram = Get-ProgramByName -list $list -name $programName
            if ($null -ne $foundProgram) {
                Show-ProgramDetails -program $foundProgram 
            }
            else {
                Write-SpectreHost "[bold red]Program '$programName' not found.[/]"
            }
        }
        "Find programs by category" {
            $inputCategory = Read-SpectreText -Message "Enter the category"
            Get-ProgramsByCategory -list $list -category $inputCategory
        }
        "List all programs" {
            Get-ProgramList $list
        }
        "List categories" {
            Get-CategoryWithCounts $list
        }
        "List installed programs" {
            Write-SpectreHost "[dim]Listing installed programs... (Pending implementation)[/]"
        }
        "Return to Main Menu" {
            return
        }
    }
    
    Write-SpectreHost "`n[dim]Press any key to continue...[/]"
    [System.Console]::ReadKey($true) | Out-Null
}

# ----------- Main Script Body (Execution) -------------
$env:IgnoreSpectreEncoding = $true
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$Data = Get-Content -Path ".\list.json" -Raw
$list = $Data | ConvertFrom-Json

Init

do {
    Clear-Host
    Write-SpectreHost "[bold cyan]WRAP - Windows Reverse-engineering & Analysis Platform[/]"
    
    $menuItems = @(
        "1. Install Program by Name",
        "2. Find",
        "3. Install Everything",
        "4. Exit"
    )

    $opt = Read-SpectreSelection -Title "Select an action:" -Choices $menuItems -Color Green

    switch ($opt) {
        "1. Install Program by Name" {
            $programName = Read-SpectreText -Message "Enter application name"
            $foundProgram = Get-ProgramByName -list $list -name $programName
            if ($foundProgram) {
                Show-ProgramDetails -program $foundProgram
                Install-Program -program $foundProgram
            }
        }
        "2. Find" {
            Invoke-FindFunctions -list $list
        }
        "3. Install Everything" {
            Install-Everything -list $list
        }
        "4. Exit" {
            Write-SpectreHost "[bold yellow]Exiting...[/]"
            break
        }
    }
} while ($true)