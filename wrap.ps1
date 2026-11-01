# Automatically Relaunch in PowerShell 7 as Administrator
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

    Write-SpectreRule -Title "Checking for existing Visual C++ Build Tools" -Alignment Left -Color Cyan

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
# Test internet connectionS
function Test-Internet {
    Write-SpectreRule -Title "Checking Internet Connection" -Alignment Left -Color Cyan
    
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
    Write-SpectreRule -Title "Checking for Git installation" -Alignment Left -Color Cyan
    

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
    Write-SpectreRule -Title "Checking for mise installation" -Alignment Left -Color Cyan

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

# Bootstrap foundational language runtimes using mise
function Invoke-MiseRuntimes {
    Write-SpectreRule -Title "Bootstrapping Core Runtimes via mise" -Alignment Left -Color Cyan
    $ConfigPath = "C:\WRAP\mise.toml"

    if (-not (Test-Path $ConfigPath)) {
        Write-Host "Creating base C:\WRAP\mise.toml configuration..." -ForegroundColor DarkGray
        $MiseConfig = @"
[env]
MISE_DATA_DIR = "C:\\WRAP\\mise"
MISE_CACHE_DIR = "C:\\WRAP\\mise\\cache"

[tools]
python = "3.14"
uv = "latest"
node = "lts"
go = "latest"
rust = "latest"
dotnet = "latest"
java = "temurin-21"
"@
        Set-Content -Path $ConfigPath -Value $MiseConfig -Encoding UTF8
    }

    Write-Host "Installing runtimes (Python, Node, Rust, Go, .NET, Java). This may take a few minutes..." -ForegroundColor Yellow
    
    $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -notmatch 'Program Files\\dotnet' }) -join ';'
    Push-Location "C:\WRAP"
    & mise install
    $exitCode = $LASTEXITCODE
    Pop-Location

    if ($exitCode -eq 0) {
        Write-Host "[✓] Core runtimes installed successfully." -ForegroundColor Green
    }
    else {
        Write-Host "[✗] Runtime installation failed with exit code $exitCode." -ForegroundColor Red
    }
}

# Permanently add the mise shims to the User PATH
function Invoke-MiseShimPath {
    Write-SpectreRule -Title "Configuring mise PATH" -Alignment Left -Color Cyan
    
    $MiseShims = if (Test-Path "C:\WRAP\mise\shims") { "C:\WRAP\mise\shims" } else { "$env:LOCALAPPDATA\mise\shims" }
    $WrapBin = "C:\WRAP\bin"
    
    if (-not (Test-Path $MiseShims)) {
        New-Item -ItemType Directory -Path $MiseShims -Force | Out-Null
    }
    
    $ExistingJava = Get-Command java.exe -ErrorAction SilentlyContinue
    if (-not $ExistingJava -and -not (Test-Path "$env:JAVA_HOME")) {
        Write-Host "Java not found in PATH. Configuring Java via mise..." -ForegroundColor Cyan
        $JavaInstallDir = & mise where java 2>$null
        
        if ($JavaInstallDir -and (Test-Path $JavaInstallDir)) {
            [Environment]::SetEnvironmentVariable("JAVA_HOME", $JavaInstallDir, "User")
            $env:JAVA_HOME = $JavaInstallDir
            Write-Host "[✓] JAVA_HOME set to: $JavaInstallDir" -ForegroundColor Green
        }
        else {
            Write-Host '[!] Java runtime not found via mise. Ensure ' + "'java = ""temurin-21""'" + ' is in mise.toml.' -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "[✓] Java is already configured in the environment (Path: $($ExistingJava.Source))." -ForegroundColor Green
    }

    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    
    if ($UserPath -notlike "*$WrapBin*") {
        $cleanedPath = ($UserPath -split ';' | Where-Object { $_ -ne $MiseShims -and $_ -ne $WrapBin }) -join ';'
        $newPath = "$WrapBin;$MiseShims;$cleanedPath"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Host "[✓] Added WRAP bin and mise shims to User PATH." -ForegroundColor Green
    }
    else {
        Write-Host "[✓] mise shims are already at the front of User PATH." -ForegroundColor Green
    }
}

# Automatically create direct Java wrappers for .jar files and regenerate mise shims
function Repair-ReTools {
    $BinDir = "C:\WRAP\bin"
    if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }

    $NeedsReshim = $false

    if (-not (Test-Path "$BinDir\apktool.cmd")) {
        $ApkDir = & mise where "github:iBotPeaches/Apktool" 2>$null
        if ($ApkDir -and (Test-Path $ApkDir)) {
            $ApkJar = (Get-ChildItem -Path $ApkDir -Filter "*.jar" -Recurse | Select-Object -First 1).FullName
            if ($ApkJar) {
                Set-Content -Path "$BinDir\apktool.cmd" -Value "@java -jar `"$ApkJar`" %*"
                Write-Host "[✓] Custom Java wrapper created for Apktool." -ForegroundColor Green
                $NeedsReshim = $true
            }
        }
    }

    if (-not (Test-Path "$BinDir\bytecode-viewer.cmd")) {
        $BcDir = & mise where "github:Konloch/bytecode-viewer" 2>$null
        if ($BcDir -and (Test-Path $BcDir)) {
            $BcJar = (Get-ChildItem -Path $BcDir -Filter "*.jar" -Recurse | Select-Object -First 1).FullName
            if ($BcJar) {
                Set-Content -Path "$BinDir\bytecode-viewer.cmd" -Value "@java -Djava.security.manager=allow -jar `"$BcJar`" %*"
                Write-Host "[✓] Custom Java wrapper created for Bytecode Viewer." -ForegroundColor Green
                $NeedsReshim = $true
            }
        }
    }

    if ($NeedsReshim) {
        Write-Host "--- Re-linking Java and Reshimming RE Tools ---" -ForegroundColor Cyan
        & mise reshim
    }
}

# Checks if Visual Studio Build tools are installed
function Invoke-VisualCppCheck {
    $BuildToolsId = "Microsoft.VisualStudio.2022.BuildTools"
    $VCToolsWorkload = "Microsoft.VisualStudio.Workload.VCTools"

    Write-SpectreRule -Title "Checking for existing Visual C++ Build Tools" -Alignment Left -Color Cyan

    $InstallCheck = winget list --id $BuildToolsId --exact 2>$null
    if ($InstallCheck -match $BuildToolsId) {
        Write-Host "[✓] Microsoft Visual Studio 2022 Build Tools found." -ForegroundColor Green
        return
    }

    Write-Host "Visual C++ Build Tools not found. Starting silent installation (this CAN take several minutes/gigabytes)..." -ForegroundColor Yellow
    
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
        # Exit code 3010; 'Success and need to reboot'
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


# Checks if PwshSpectreConsole is installed; install if missing
function Invoke-SpectreCheck {
    Write-SpectreRule -Title "Checking for PwshSpectreConsole" -Alignment Left -Color Cyan
    
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
    Write-SpectreRule -Title "Checking Prerequisites" -Alignment Left -Color Cyan
    
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
    $DesktopPath = [Environment]::GetFolderPath("Desktop")
    $WrapShortcutPath = Join-Path $DesktopPath "WRAP Home.lnk"
    
    if (-not (Test-Path $WrapShortcutPath)) {
        Write-Host "Creating WRAP Home shortcut on desktop..." -ForegroundColor DarkGray
        try {
            $WshShell = New-Object -ComObject WScript.Shell
            $Shortcut = $WshShell.CreateShortcut($WrapShortcutPath)
            $Shortcut.TargetPath = "C:\WRAP"
            $Shortcut.IconLocation = "shell32.dll, 4"
            $Shortcut.Save()
        }
        catch {
            Write-Host "[!] Failed to create WRAP desktop shortcut." -ForegroundColor Yellow
        }
    }
    Invoke-GitCheck
    Invoke-MiseCheck
    Invoke-MiseShimPath
    Invoke-MiseRuntimes
    Invoke-VisualCppCheck
    Invoke-SpectreCheck
    Import-Module PwshSpectreConsole -Global
    try {
        winget settings --enable InstallerHashOverride *>&1 | Out-Null
    }
    catch {
        Write-Host "[!] Failed to enable InstallerHashOverride." -ForegroundColor Yellow
    } 
    Write-SpectreRule -Color Cyan
    if ($Host.UI.RawUI.KeyAvailable -or [System.Environment]::UserInteractive) {
        Write-Host "Press Enter to continue..." -ForegroundColor Cyan
        $null = Read-Host
    }
}

# --- Installation Helper Functions ---
# Installs IDA plugins
function Install-idaPlugins {
    param([string]$Location)
    Write-Host "`nInstalling IDA plugins into $Location" -ForegroundColor Cyan

    $PluginPath = Join-Path $Location "plugins"
    if (-not (Test-Path $PluginPath)) { New-Item -ItemType Directory -Path $PluginPath | Out-Null }
    
    Push-Location $PluginPath
    git clone https://github.com/mandiant/capa.git
    git clone https://github.com/airbus-cert/comida.git
    git clone https://github.com/danigargu/deREferencing.git
    git clone https://github.com/joxeankoret/diaphora.git
    git clone https://github.com/mandiant/flare-ida.git
    git clone https://github.com/hasherezade/ida_ifl.git
    git clone https://github.com/patois/xray.git
    git clone https://github.com/mandiant/xrefer.git
    Pop-Location
}

# Install x64dbg plugins
function Install-x64dbgPlugins {
    param([string]$Location)
    Write-Host "`nInstalling x64dbg plugins into $Location" -ForegroundColor Cyan

    $PluginPath = Join-Path $Location "plugins"
    if (-not (Test-Path $PluginPath)) { New-Item -ItemType Directory -Path $PluginPath | Out-Null }
    
    Push-Location $PluginPath
    git clone https://github.com/x64dbg/ScyllaHide.git
    git clone https://github.com/mrexodia/TitanHide.git
    git clone https://github.com/therealdreg/DbgChild.git
    Pop-Location
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

# Create a Desktop Shortcut for GUI applications installed with winget
function New-DesktopShortcut {
    param (
        [string]$TargetExecutable,
        [string]$ShortcutName
    )
    
    $DesktopPath = [Environment]::GetFolderPath("Desktop")
    $ShortcutPath = Join-Path $DesktopPath "$ShortcutName.lnk"
    
    Write-Host "Creating desktop shortcut: $ShortcutName" -ForegroundColor Cyan
    
    try {
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = $TargetExecutable
        $Shortcut.Save()
        Write-Host "[✓] Shortcut created on Desktop." -ForegroundColor Green
    }
    catch {
        Write-Host "[✗] Failed to create shortcut: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Install using mise
function Invoke-MiseInstall {
    param (
        [Parameter(Mandatory = $true)][string]$MiseBackendSpec
    )

    if ($MiseBackendSpec -match "^pypi:") {
        Write-Host "`nPython package detected. Bootstrapping 'uv' into mise to handle the installation..." -ForegroundColor DarkGray
        $uvArgs = @("use", "--global", "uv@latest")
        & mise @uvArgs
    }

    Write-Host "Executing mise install for: $MiseBackendSpec" -ForegroundColor Cyan
    $ToolName = $MiseBackendSpec.Split(':')[1].Split('@')[0]

    #  Handle specific tool exceptions and build dependencies
    if ($ToolName -ieq "peepdf") {
        Write-Host "Detected package with complex native dependencies. Pre-installing build requirements..." -ForegroundColor Yellow
        $uvPipArgs = @("pip", "install", "--global", "settings", "setuptools", "wheel")
        & uv @uvPipArgs
    }
    
    if ($MiseBackendSpec -match "^dotnet:") {
        if ($ToolName -ieq "sfextract") {
            Write-Host "Detected sfextract requirement. Bootstrapping isolated .NET 8 SDK..." -ForegroundColor Yellow
            & mise install dotnet@8 
            $MiseDotNetPath = & mise where dotnet@8 2>$null
        }
        else {
            Write-Host "Detected standard .NET tool requirement. Locating default .NET SDK..." -ForegroundColor DarkGray
            $MiseDotNetPath = & mise where dotnet 2>$null
        }
        
        if ($MiseDotNetPath) {
            $env:DOTNET_ROOT = $MiseDotNetPath
            $env:PATH = "$MiseDotNetPath;$env:PATH" 
        }
    }

    $miseArgs = @("use", "--global", "$MiseBackendSpec@latest")
    & mise @miseArgs

    if ($LASTEXITCODE -eq 0) {
        & mise reshim
        Write-Host "[✓] Successfully installed and reshimmed $MiseBackendSpec via mise." -ForegroundColor Green
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
    elseif ($FileName -match '\.exe$') {
        Write-Host "Installing EXE package for $ProgramName..." -ForegroundColor Cyan
        # Most standard EXEs (InnoSetup, Nullsoft) respect /S for silent installs
        Start-Process $OutFile -ArgumentList "/S" -Wait
    }
    elseif ($FileName -match '\.zip$') {
        Expand-Archive -Path $OutFile -DestinationPath $DestDir -Force
        Remove-Item $OutFile -Force
    }
    
    Write-Host "[✓] Installed $ProgramName to $DestDir" -ForegroundColor Green
}

# Selection Install
function Install-Selection {
    param (
        [Parameter(Mandatory = $true)]
        [psobject[]]$List
    )

    $uniqueTools = $List | Group-Object Name | ForEach-Object { $_.Group[0] }
    $choiceGroups = $uniqueTools | Group-Object { 
        $cat = if ($_.Category -and $_.Category.Count -gt 0) { $_.Category[0] } else { "Uncategorized" } 
        "📂 $cat" 
    } | Sort-Object Name | ForEach-Object {
        @{
            Name    = $_.Name
            Choices = @($_.Group | Sort-Object Name)
        }
    }

    $selectedTools = Read-SpectreMultiSelectionGrouped `
        -Message "Select tools to install (Space to toggle, Enter to confirm)" `
        -Choices $choiceGroups `
        -ChoiceLabelProperty "Name" `
        -PageSize 20 `
        -Color Green

    if (-not $selectedTools -or $selectedTools.Count -eq 0) {
        Write-SpectreHost "`n[bold yellow]No tools selected. Returning to menu...[/]"
        Start-Sleep -Seconds 1
        return
    }

    $toolNames = $selectedTools | ForEach-Object { $_.Name }
    $toolListString = $toolNames -join ", "

    Write-SpectreHost "`n[bold cyan]Starting batch installation of $($selectedTools.Count) tool(s) in total...[/]"
    Write-SpectreHost "[bold yellow]Will install: $toolListString[/]`n"
    
    foreach ($tool in $selectedTools) {
        Install-Program -Program $tool
    }

    Write-SpectreHost "`n[bold green]Batch installation complete![/]"
    Write-SpectreHost "[dim]Press Enter to continue...[/]"
    $null = Read-Host
}

# Install everything
function Install-Everything {
    param (
        [Parameter(Mandatory = $true)]
        [psobject[]]$List
    )
    
    Write-Host "`n[!] Initiating batch installation of all $($List.Count) tools. This will take some time..." -ForegroundColor Yellow
    
    foreach ($program in $List) {
        try {
            Install-Program -Program $program
        }
        catch {
            Write-Host "[✗] Failed to install $($program.Name): $_" -ForegroundColor Red
        }
    }

    Repair-ReTools
    
    Write-Host "`n[✓] Batch installation sequence complete!" -ForegroundColor Green
    Write-Host "Press Enter to return to the menu..." -ForegroundColor Cyan
    $null = Read-Host
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
                if ($program.RequiresCpp) {
                    Invoke-VisualCppCheck
                    Write-Host "Attempting C++ Build Environment setup for compilation..." -ForegroundColor Yellow
                    Invoke-VisualStudioEnvironment
                }
                
                Invoke-MiseInstall -MiseBackendSpec $program.Source[1]
            }
            Default {
                Write-Host "Installer type '$installer' not recognized. Cannot install $($program.Name)." -ForegroundColor Red
            }
            "other" {
                if ($Program.Source[1]) {
                    Invoke-DirectInstall -Url $Program.Source[1] -ProgramName $Program.Name
                }
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
        "1. Install"
        "2. Find and Install",
        "3. Install Everything",
        "4. Find",
        "5. Exit"
    )

    $opt = Read-SpectreSelection -Title "Select an action:" -Choices $menuItems -Color Green

    switch ($opt) {
        "1. Install" {
            Install-Selection -List $list
        }
        "2. Find and Install" {
            $programName = Read-SpectreText -Message "Enter application name"
            $foundProgram = Get-ProgramByName -list $list -name $programName
            if ($foundProgram) {
                Show-ProgramDetails -program $foundProgram
                Install-Program -program $foundProgram
            }
        }
        "3. Install Everything" {
            Install-Everything -list $list
        }
        "4. Find" {
            Invoke-FindFunctions -list $list
        }
        "5. Exit" {
            Write-SpectreHost "[bold yellow]Exiting...[/]"
            exit 0
        }
    }
} while ($true)