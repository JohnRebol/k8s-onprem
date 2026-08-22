# Runs once, unattended, during Setup's specialize pass (see the
# RunSynchronousCommand in autounattend.xml). Its only job is to get WinRM
# listening -- this is the equivalent of Ubuntu already having sshd running by
# the time Packer connects; Windows needs to be told to turn WinRM on first.
#
# No parameters: the built-in Administrator account (which WinRM here
# connects as) already has full local access once autounattend.xml enables it
# and sets its password -- this script only needs to configure the listener,
# not touch any account.

$ErrorActionPreference = "Stop"

# A fresh network adapter starts in the "Public" firewall profile, which
# blocks WinRM's inbound rule. There's no user around to answer the "Public or
# Private?" prompt Windows would normally show, so force it -- safe here
# because this VM only exists on the build LAN.
Get-NetConnectionProfile | ForEach-Object {
    Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
}

Set-Service -Name WinRM -StartupType Automatic
Start-Service WinRM

# -quiet skips the interactive y/n prompts quickconfig normally shows; there's
# no console attached to answer them during specialize.
winrm quickconfig -quiet

# Basic auth + unencrypted transport: matches winrm_insecure = true in
# windows11.pkr.hcl. Plain WinRM-over-HTTP is fine on a trusted build LAN and
# wrong anywhere else -- same tradeoff as insecure_skip_tls_verify for Proxmox
# in ../windows11.pkr.hcl.
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'
winrm set winrm/config/client '@{AllowUnencrypted="true"}'

# Default envelope size is tuned for small remote commands; provision-apps.ps1
# is a much longer script than WinRM expects to receive in one call.
winrm set winrm/config '@{MaxEnvelopeSizekb="8192"}'

# quickconfig normally adds this, but do it explicitly rather than trust that
# -- a silently-missing firewall rule here is a confusing way for the Packer
# build to hang on "waiting for WinRM" with no error.
if (-not (Get-NetFirewallRule -DisplayName "WinRM HTTP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "WinRM HTTP" -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow | Out-Null
}

Restart-Service WinRM
