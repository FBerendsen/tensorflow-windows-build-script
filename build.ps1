# Requires -RunAsAdministrator
# This script needs to be run with administrator rights.

param (
    [Parameter(Mandatory = $true)]
    [string]$BazelBuildParameters,

    [switch]$BuildCppAPI = $false,
    [switch]$BuildCppProtoBuf = $false,
    [switch]$ReserveSource = $false,
    [switch]$ReserveVenv = $false,
    [switch]$IgnoreDepsVersionIssues = $false,
    [switch]$InstallDefaultDeps = $false,
    [Parameter(Mandatory=$false)][string]$PythonCerts, # path to a modified cacert.pem for pip install (optional; in case of firewall)
    [Parameter(Mandatory=$false)][string]$JavaCerts # path to a modified cacerts for bazel build (optional; in case of firewall)
)

# Set parameters for execution.
Set-StrictMode -Version latest
$ErrorActionPreference = "Stop"

# Cleaning Work
Remove-Item tensorflow -ErrorAction SilentlyContinue -Force -Recurse
Remove-Item deps -ErrorAction SilentlyContinue -Force -Recurse
if (! $ReserveVenv) {
    Remove-Item venv -ErrorAction SilentlyContinue -Force -Recurse
}
if (! $ReserveSource) {
    Remove-Item source -ErrorAction SilentlyContinue -Force -Recurse
}

# Ask the specific version of Tensorflow.
$supportedVersions = @("v1.11.0")
$options = [Array]::CreateInstance([System.Management.Automation.Host.ChoiceDescription], $supportedVersions.Count + 1)
for ($i = 0; $i -lt $supportedVersions.Count; $i++) {
    $options[$i] = [System.Management.Automation.Host.ChoiceDescription]::new("&$($i + 1) - $($supportedVersions[$i])",
        "Build Tensorflow $($supportedVersions[$i]).")
}
$options[$options.Count - 1] = [System.Management.Automation.Host.ChoiceDescription]::new("&Select another version",
    "Input the custom version tag you want to build.")
$title = "Select a Tensorflow version:"
$chosenIndex = $Host.UI.PromptForChoice($title, "", $options, 0)

if ($chosenIndex -eq $supportedVersions.Count) {
    $buildVersion = Read-Host "Please input the version tag (e.g. v1.11.0)"
} else {
    $buildVersion = $supportedVersions[$chosenIndex]
}

# Install dependencies.
function CheckInstalled {
    param (
        [string]$ExeName,

        [Parameter(Mandatory = $false)]
        [string]$RequiredVersion
    )
    $installed = Get-Command $ExeName -All -ErrorAction SilentlyContinue
    if ($null -eq ($installed)) {
        Write-Host "Unable to find $ExeName." -ForegroundColor Red
        return $false
    } else {
        Write-Host "Found $ExeName installed." -ForegroundColor Green
        if ([string]::Empty -ne $RequiredVersion -and $true -ne $IgnoreDepsVersionIssues) {
            Write-Host $("But we've only tested with $ExeName $RequiredVersion.") -ForegroundColor Yellow
            $confirmation = Read-Host "Are you sure you want to PROCEED? [y/n]"
            while ($confirmation -ne "y") {
                if ($confirmation -eq 'n') {exit}
                $confirmation = Read-Host "Are you sure you want to PROCEED? [y/n]"
            }
        }
        return $true
    }
}

function askForVersion {
    param (
        [Parameter(Mandatory = $true)]
        [string]$DefaultVersion
    )

    if ($InstallDefaultDeps) {
        return $DefaultVersion
    }

    $version = Read-Host "Which version would you like to install? [Default version: $DefaultVersion]"
    return $version
}

if (! (CheckInstalled chocolatey)) {
    Write-Host "Installing Chocolatey package manager."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
}

choco feature enable -n allowGlobalConfirmation | Out-Null # Enable global confirmation for chocolatey package installation.

$ENV:Path += ";C:\msys64\usr\bin"
$ENV:Path += ";C:\Program Files\CMake\bin"
$ENV:BAZEL_SH = "C:\msys64\usr\bin\bash.exe"

if (! (CheckInstalled pacman)) {
    $version = askForVersion "20180531.0.0"
    choco install msys2 --version $version --params "/NoUpdate /InstallDir:C:\msys64"
    # Install tools that are necessary for buiding.
    pacman -S --noconfirm patch unzip
    if ($BuildCppProtoBuf) {
        pacman -S --noconfirm tar
    }
}

if (! (CheckInstalled bazel "0.15.0")) {
    # Bazel will also install msys2, but with an incorrect version, so we will ignore the dependencies.
    $version = askForVersion "0.15.0"
    choco install bazel --version $version --ignore-dependencies
}

if (! (CheckInstalled cmake "3.12")) {
    $version = askForVersion "3.12"
    choco install cmake --version $version
}

if (! (CheckInstalled git)) {
    choco install git
}

if (! (CheckInstalled python "3.6.7")) {
    $version = askForVersion "3.6.7"
    choco install python --version $version --params "'TARGETDIR:C:/Python36'"
}

# Get the source code of Tensorflow and checkout to the specific version.
if (! $ReserveSource) {
    git clone https://github.com/tensorflow/tensorflow.git
    Rename-Item tensorflow source
}
Set-Location source
git checkout -f tags/$buildVersion

# Apply patches to source.
git apply --ignore-space-change --ignore-white ..\patches\eigen_build.patch # Eigen Patch
Copy-Item ..\patches\eigen.patch third_party\

if ($BuildCppAPI) {
    # C++ Symbol Patch
    git apply --ignore-space-change --ignore-white ..\patches\cpp_symbol.patch
    Copy-Item ..\patches\tf_exported_symbols_msvc.lds tensorflow\
}

Set-Location ..

# Setup folder structure.
$rootDir = $pwd
$dependenciesDir = "$rootDir\deps"
$sourceDir = "$rootDir\source"
$venvDir = "$rootDir\venv"

mkdir $dependenciesDir | Out-Null

# Installing protobuf.
if ($BuildCppProtoBuf) {
    #    $ENV:Path += ";$dependenciesDir\protobuf\bin\bin"
    Set-Location $dependenciesDir

    mkdir (Join-Path $dependenciesDir protobuf) | Out-Null

    Set-Location protobuf
    $protobufSource = "$pwd\source"
    $protobufBuild = "$pwd\build"
    $protobufBin = "$pwd\bin"

    $protobuf_tar = "protobuf3.6.0.tar.gz"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "https://github.com/google/protobuf/archive/v3.6.0.tar.gz" -outfile $protobuf_tar

    mkdir source | Out-Null
    tar -xf $protobuf_tar --directory source --strip-components=1
    mkdir $protobufBuild | Out-Null
    mkdir $protobufBin | Out-Null

    Set-Location $protobufBuild
    cmake "$protobufSource\cmake" -G"Visual Studio 14 2015 Win64" -DCMAKE_INSTALL_PREFIX="$protobufBin" -DCMAKE_BUILD_TYPE=Release `
        -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_MODULE_COMPATIBLE=ON -Dprotobuf_MSVC_STATIC_RUNTIME=OFF
    cmake --build . --config Release
    cmake --build . --target install --config Release

    Set-Location $rootDir
}

# Create python environment.
if (! $ReserveVenv) {
    mkdir $venvDir | Out-Null
    py -3 -m venv venv
    .\venv\Scripts\Activate.ps1
	
	$PipCertParameters = ""
	if ($PythonCerts) {
		$PipCertParameters = "--cert " + $PythonCerts
	}

    Invoke-Expression ("pip3 install six numpy wheel" + $PipCertParameters)
    Invoke-Expression ("pip3 install keras_applications==1.0.5 --no-deps" + $PipCertParameters)
    Invoke-Expression ("pip3 install keras_preprocessing==1.0.3 --no-deps" + $PipCertParameters)
}

Set-Location $sourceDir

if ($ReserveSource) {
    # Cleaning Bazel files.
    bazel clean --expunge
    Remove-Item (Join-Path $sourceDir ".bazelrc") -ErrorAction SilentlyContinue
}

# Configure
$ENV:PYTHON_BIN_PATH = "$VenvDir/Scripts/python.exe" -replace '[\\]', '/'
$ENV:PYTHON_LIB_PATH = "$VenvDir/lib/site-packages" -replace '[\\]', '/'

py configure.py

$BazelCertParameters = ""
if ($JavaCerts) {
    $BazelCertParameters = "--host_jvm_args=-Djavax.net.ssl.trustStore=" + $JavaCerts
}


# Build
Invoke-Expression ("bazel " + $BazelCertParameters + " build " + $BazelBuildParameters)

# Shutdown Bazel
bazel shutdown

Set-Location $rootDir
