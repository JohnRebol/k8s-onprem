# Provisions the Windows 11 golden image. Packer uploads this over WinRM and
# runs it as the winrm_username account (Administrator, by default) once
# enable-winrm.ps1 has made that connection possible. This is the Windows
# counterpart to ../packer/scripts/provision-k8s.sh: same role in the build
# (the real customization happens here, not in the answer file), same
# not-terminating-on-error discipline (set -euo pipefail there, $ErrorActionPreference
# = "Stop" here), different toolchain end to end.

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- Package manager ----------------------------------------------------
# Chocolatey is this build's equivalent of apt: a way to install known-good
# packages by name instead of hand-rolling a silent-install invocation (and
# the exact silent-install flags) for every app. Not the Microsoft Store --
# the Store needs a signed-in account and network access to Store services
# that an unattended build can't rely on.
Set-ExecutionPolicy Bypass -Scope Process -Force
Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
$env:Path = "$env:Path;$env:ALLUSERSPROFILE\chocolatey\bin"

choco install -y brave tailscale

# --- Blue Iris ------------------------------------------------------------
# Not packaged on Chocolatey -- it's commercial NVR software, downloaded
# directly from the vendor. Unlike Brave/Tailscale this almost certainly
# needs a real license key to do anything past a trial, and the installer's
# silent-install flags below (Inno Setup's standard set) are the most likely
# thing in this whole script to need adjusting once you've actually run it
# once and seen how it behaves.
$blueIrisInstaller = "$env:TEMP\BlueIris.exe"
Invoke-WebRequest -Uri "https://blueirissoftware.com/BlueIris5.exe" -OutFile $blueIrisInstaller
Start-Process -FilePath $blueIrisInstaller -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait
Remove-Item $blueIrisInstaller -Force

# Tailscale is installed but deliberately NOT authenticated here ("tailscale
# up" opens an interactive browser login, and each real machine needs its own
# identity on your tailnet) -- same principle as ../packer/README.md's "nothing
# inside [the golden image] should know which node it will become". Run
# `tailscale up` by hand (or with a per-machine auth key) on each clone.

# --- Strip build-time identity and secrets --------------------------------
# Windows Setup caches the answer file it used, including the plaintext
# winrm_password from autounattend.xml -- this is the Windows analogue of
# ../packer/scripts/provision-k8s.sh deleting SSH host keys before templating.
# Everything left here is inherited by every clone.
Remove-Item -Path "$env:WINDIR\Panther" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:WINDIR\System32\Sysprep\Panther" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" -Force -ErrorAction SilentlyContinue

# A handful of bundled Store apps are known to block sysprep's /generalize
# step with "was installed for a user, but not provisioned for all users"
# (error 0x8007007E) -- remove the usual offenders proactively rather than
# discovering this only when sysprep fails below.
Get-AppxPackage -AllUsers | Where-Object { $_.Name -match "Clipchamp|Todos|MicrosoftTeams|OutlookForWindows" } |
    Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue

# --- Generalize ------------------------------------------------------------
# sysprep strips the machine SID and other per-install identity, and shuts
# the VM down when it's done -- Packer (via qemu_agent) detects that shutdown
# and converts the VM into a template. Without this, every clone of the
# template would share one SID, which breaks Active Directory domain-join and
# confuses anything that identifies machines by it.
#
# There's no equivalent here of the Ubuntu build's cloud-init unseal, because
# there's no cloud-init: a fresh clone comes up, runs the specialize pass
# again (generalize is what makes that pass re-run), and lands back in OOBE --
# it will need its own answer file or a human at the console to get through
# that, unlike a Terraform-driven clone of the Ubuntu image. That gap is real
# and unsolved by this build; see README.md.
& "$env:WINDIR\System32\Sysprep\sysprep.exe" /oobe /generalize /shutdown /quiet
