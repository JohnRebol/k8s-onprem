# Windows 11 golden image

Builds a Proxmox VM template for a Windows 11 desktop with Brave, Blue Iris,
and Tailscale preinstalled. Sibling to [../packer](../packer) (the Kubernetes
golden image) -- same repo, same Proxmox host, unrelated purpose. Unlike that
project, this one isn't part of the k8s skills-ladder curriculum this repo is
otherwise scoped to (see [../.CLAUDE.md](../.CLAUDE.md)); it's a practical
utility that happens to reuse the same Packer + Proxmox pattern.

## How the build works

Same shape as `../packer`, almost nothing the same underneath:

1. Packer creates a temporary VM on Proxmox with UEFI, Secure Boot, and a
   virtual TPM 2.0 -- all three are hard requirements for Windows 11 Setup.
2. It attaches the Windows ISO (already uploaded to the datastore -- see
   `windows_iso_file` below), the VirtIO driver ISO (Windows has no built-in
   driver for the virtio-scsi disk controller), and a small ISO Packer
   generates on the fly containing `http/autounattend.xml` and
   `http/enable-winrm.ps1`. Windows Setup auto-scans every attached volume
   for `autounattend.xml`, so there's no boot_command URL fetch like Ubuntu's
   autoinstall.
3. `autounattend.xml` answers every Setup prompt, including which drive
   letters to search for the VirtIO driver. Its specialize pass runs
   `enable-winrm.ps1`, which turns on WinRM -- this build's equivalent of SSH
   already running by the time Packer connects.
4. Packer connects over WinRM and runs `scripts/provision-apps.ps1`, which
   installs the three apps via Chocolatey (plus a direct download for Blue
   Iris, which isn't packaged there), strips build-time secrets out of
   `C:\Windows\Panther`, and runs `sysprep /generalize /oobe /shutdown`.
5. The VM shuts itself down; Packer converts it into a template.

## Usage

```sh
cd packer-windows11
cp variables.auto.pkrvars.hcl.example variables.auto.pkrvars.hcl   # first time only
set -a; source ../.env; set +a
```

Add one variable to `.env` that `../packer` never needed -- this build
connects over WinRM, not SSH, so there's no key, only a password:

```sh
PKR_VAR_winrm_password='...'   # becomes the Administrator account's real password
```

Then:

```sh
packer init .
packer validate -var-file=variables.auto.pkrvars.hcl .
packer build -var-file=variables.auto.pkrvars.hcl .
```

Windows Setup + first-boot servicing is slower than Ubuntu's autoinstall --
budget close to an hour, more on a first attempt if anything in the answer
file needs fixing. Run it under `tmux`.

### The Windows ISO has to be uploaded by hand

Ubuntu's build downloads its ISO from a stable, static URL
(`releases.ubuntu.com`) with a published checksum file. Microsoft's Windows 11
download page is a session-gated JavaScript flow with no equivalent -- there
is no URL to hand to `iso_url`. Upload the ISO to the Proxmox datastore
yourself (via the UI, or `scp` + `pvesm`).

### Building the no-prompt ISO

Don't point `windows_iso_file` at that upload directly -- build a modified
copy first. Every official Windows ISO's own bootloader shows "Press any key
to boot from CD or DVD..." with a keypress window open for only a couple of
seconds and no second chance if it's missed. This is *not* an OVMF/Proxmox
boot-order quirk (there's no fix on the Packer config side); it's how
Microsoft ships the ISO, so that a leftover install disc doesn't force a
reinstall. No `boot_wait`/`boot_command` tuning can race it reliably -- on one
test host, POST time before the prompt even appeared varied from ~2s to 50+s
across otherwise-identical boots, and single keystrokes, spread-out
keystrokes, and 80 seconds of tight 1-second-interval keystrokes all still
missed it at least some of the time.

The real fix: Microsoft already ships a second, no-prompt variant of the same
two boot files on every install ISO, specifically for unattended deployment
-- `efi/microsoft/boot/{cdboot,efisys}_noprompt.{efi,bin}` sit right next to
the normal ones. Swap them in with `xorriso`, once, and the prompt never
appears at all:

```sh
ssh root@<proxmox-host>

# Extract the two no-prompt files from the ISO you already uploaded.
mkdir -p /root/winiso-mount /root/winiso-work
mount -o loop,ro /nvmePCI/template/iso/Win11_25H2_English_x64_v2.iso /root/winiso-mount
cp /root/winiso-mount/efi/microsoft/boot/efisys_noprompt.bin /root/winiso-work/
cp /root/winiso-mount/efi/microsoft/boot/cdboot_noprompt.efi /root/winiso-work/
umount /root/winiso-mount

# Full copy first, then modify IN PLACE with a single -dev (not separate
# -indev/-outdev -- that mode does NOT carry over the original file tree,
# it only writes what's explicitly mapped, producing a ~2MB husk of an ISO).
cp /nvmePCI/template/iso/Win11_25H2_English_x64_v2.iso \
   /nvmePCI/template/iso/Win11_25H2_English_x64_v2-noprompt.iso

xorriso -dev /nvmePCI/template/iso/Win11_25H2_English_x64_v2-noprompt.iso \
  -boot_image any replay \
  -map /root/winiso-work/efisys_noprompt.bin efi/microsoft/boot/efisys.bin \
  -map /root/winiso-work/cdboot_noprompt.efi efi/microsoft/boot/cdboot.efi \
  -commit
```

`-boot_image any replay` clones the existing El Torito boot catalog instead
of reconstructing one from scratch by hand, which is the fragile part of most
guides that use plain `mkisofs`/`genisoimage` flags for this. Ignore the
"Cannot enable EL Torito boot image ... because it is not a data file"
`SORRY` lines this prints -- they're about the legacy BIOS boot record, which
this build never uses (it's UEFI/OVMF-only); the write itself still succeeds,
and the output size should match the original (check with `ls -la`).

Point `windows_iso_file` at the `-noprompt.iso` result, not the original.
With it, `ide0` boots straight into Setup with nothing to press and nothing
to race -- `boot_wait` only needs to cover ordinary firmware POST.

### VirtIO driver URLs must be fully resolved, not the "convenience" link

Proxmox's server-side ISO downloader (`iso_download_pve = true`) does not
follow HTTP redirects. The VirtIO project's usual `stable-virtio/virtio-win.iso`
URL is a 2-hop redirect to a version-specific archive path, and Proxmox fails
that download with a generic "failed to download ISO with all the provided
URLs" and no indication *why*. If you bump `virtio_iso_url` to a newer
release, resolve the redirect yourself first (`curl -sSIL <stable-virtio URL>`)
and use the final URL.

## What's different from ../packer, and why

| | Ubuntu (`../packer`) | Windows (here) |
| --- | --- | --- |
| Answer file | `user-data`, fetched via a boot_command URL Packer serves | `autounattend.xml`, auto-detected on any attached volume |
| Remote access | SSH, via a key baked in by cloud-init | WinRM, via a password set by the answer file |
| Package manager | apt | Chocolatey (Blue Iris has no package -- direct download) |
| Per-clone reset | cloud-init unseal (`provision-k8s.sh`) | `sysprep /generalize` |
| Driver situation | none needed -- Linux has virtio drivers built in | VirtIO driver ISO required just to see the disk during Setup |
| Boot firmware | seabios | OVMF (UEFI) + TPM 2.0, both required by Windows 11 |

## Known gap: there is no cloud-init here

This is the biggest structural difference from `../packer`, and it isn't
fully solved by this build. cloud-init is what lets a single Ubuntu template
become many differently-configured nodes -- each clone reads its own
hostname/IP/SSH key on first boot from a virtual CD Proxmox attaches, driven
by Terraform. Windows has no equivalent shipped by default.

`sysprep /generalize` strips this image's machine identity (SID, etc.) so
clones don't collide, but a generalized Windows image re-enters the
specialize/oobeSystem passes on its *next* boot with no answer file attached
-- it lands in interactive OOBE, waiting for a human at the console. If this
image is ever cloned more than once, that gap needs solving (a per-clone
answer file injected the same way Terraform injects cloud-init data for the
Ubuntu nodes, or an unattended sysprep answer baked in some other way) before
it works like `../packer`'s template does.

## Known gap: Tailscale is installed but not authenticated

`tailscale up` requires an interactive browser login (or a per-machine auth
key) -- baking a real one into the golden image would mean every clone shares
one identity on your tailnet, which defeats the point of Tailscale's device
model. Run `tailscale up` by hand on each real machine.

## Debugging a stuck build

Windows unattended installs are notoriously sensitive to exact XML schema
details. If Setup stalls with no Packer log output, there is no serial
console to check (contrast Ubuntu, where you'd tail `/var/log/syslog`) --
you're debugging a GUI you can't see from the Packer log alone. The most
useful tool for that is a QEMU monitor screendump taken directly on the
Proxmox host:

```sh
ssh root@<proxmox-host>
echo "screendump /tmp/vm9005.ppm" | qm monitor 9005
```

Pull `/tmp/vm9005.ppm` back and view it -- it's a raw screenshot (PPM format)
of whatever the VM's virtual display is showing at that instant, often the
only way to see a stuck installer error dialog. A real bug in this build was
only found this way: an earlier version nested `<PnPCustomizationsWinPE>`
inside the `Microsoft-Windows-Setup` component in `autounattend.xml`, which
isn't valid there -- it belongs in its own sibling
`Microsoft-Windows-PnpCustomizationsWinPE` component. Nested wrong, the
VirtIO driver path was silently never applied, Setup couldn't see the
virtio-scsi disk it was told to partition, and it crashed (splash screen
going blank, VM rebooting) partway through the windowsPE pass with no visible
error. It was isolated by comparing against a bare-bones VM booting the same
ISO with no answer file attached at all: that one reached Setup's UI fine,
which pointed the bug at `autounattend.xml` specifically rather than the VM
hardware config.

## Known bug (fixed): vioscsi driver files landed one directory too deep

`cd_files = ["${path.root}/http/vioscsi"]` in `windows11.pkr.hcl` copied the
driver files to `http/vioscsi/w11/amd64/...` inside the generated CD, not
`vioscsi/w11/amd64/...` -- Packer's `cd_files` preserves the path relative to
`path.root`, so a source of `http/vioscsi` keeps the `http/` segment instead
of dropping it. `autounattend.xml`'s `<DriverPaths>` only ever looks at
`D:/E:/F:\vioscsi\w11\amd64`, so the driver was silently never found -- same
failure mode as the nested-component bug above (Setup can't see the
virtio-scsi disk, crashes partway through windowsPE with no visible error).
Confirmed by mounting the generated cidata ISO directly on the Proxmox host
and comparing its file tree against `<DriverPaths>`. Fixed by moving the
`vioscsi/` directory to be a sibling of `http/` (top-level in this directory)
and pointing `cd_files` at `${path.root}/vioscsi` instead.

## Known blocker (unresolved): OVMF hangs when a second CD-ROM is attached

As of 2026-08-22, on this Proxmox host (`pve-qemu-kvm 11.0.0-3`,
`pve-edk2-firmware-ovmf 4.2025.05-2`), attaching **any** second CD-ROM-like
device alongside the Windows ISO -- the `additional_iso_files` cidata device
this build has always used -- makes OVMF hang. It never even reaches Windows
Boot Manager: the screen sits on `BdsDxe: starting Boot0002 "UEFI QEMU
DVD-ROM ..."` (still the firmware, before Windows' own bootloader runs) for
roughly 2 minutes, then visually resets to the initial boot-menu splash and
repeats, apparently forever. This is a *different* bug from the two above --
those were `autounattend.xml`/Packer-config mistakes; this one reproduces on
a bare hand-built VM with no answer file, no Packer, and no `autounattend.xml`
involved at all, so it isn't fixable from this repo's config alone.

Isolated by manually building a diagnostic VM (`qm create` on the Proxmox
host directly, id 9006) and toggling one variable at a time, confirmed via
continuous `qm monitor ... screendump` polling:

| Config | Result |
| --- | --- |
| `ide0` (Windows ISO) alone | Boots fine, reaches Setup's language screen in ~15-20s |
| `ide0` + `ide1` (cidata CD) | Hangs/loops, never reaches Setup |
| `ide0` + `ide1` + `scsi0` (OS disk) -- this build's real config | Hangs/loops, same as above |
| Same, with `tpmstate0` removed | Still hangs -- rules out vTPM/measured-boot as the cause |
| Same, pinned to `pc-q35-9.2` instead of the default `pc-q35-11.0` | Still hangs -- rules out the newest q35 machine-type revision |
| `ide0` + cidata moved to `scsi1` (virtio-scsi) instead of `ide1` | **Boots fine**, reaches Setup's language screen |
| `ide0` + cidata attached as a USB CD-ROM (`usb-bot` + `scsi-cd`, via a raw `args:` line -- `usb-storage` alone doesn't work, it emulates a disk, not a CD-ROM, so Windows can't parse the ISO9660 filesystem on it) | Hangs/loops, same as the ide1 case |

So the hang tracks specifically with a second AHCI/SATA-family or USB-BOT
boot candidate -- virtio-scsi is the only tested bus that avoids it. That
reopens the *original* problem this build's cidata-on-`ide1` design was
chosen to solve (see the `additional_iso_files` block's comment in
`windows11.pkr.hcl`): Setup's very first scan for `autounattend.xml` happens
before any driver from `<DriverPaths>` is loaded, so a cidata volume on
`scsi1` is invisible at exactly the moment Setup needs to find the answer
file on it -- confirmed still true on this same host, live, via the same
diagnostic VM (boots to Setup's interactive language-selection screen instead
of silently applying the answer file, exactly like the historical account
above).

Also tried and ruled out: baking `autounattend.xml` + the vioscsi files
directly into a single custom ISO (no second device at all), by extending the
existing no-prompt `xorriso -boot_image any replay` remaster with `-map`
entries for the new files. This does not work for this specific ISO: `replay`
produces an ISO that fails outright with `BdsDxe: ... No mapping` (the boot
catalog now points at the wrong sectors), and `-boot_image any patch`
"succeeds" (no error) but still produces a non-booting image. `xorriso` warns
why on this exact ISO: `Found hidden El-Torito image. Its size could not be
figured out, so image modify or boot image patching may lead to bad results`
-- Microsoft's ISO uses a "hidden" (untracked, not a normal named file) El
Torito boot image, and `xorriso` can't safely relocate/patch its LBA
reference once other files shift data around it. The no-prompt remaster
(swapping `cdboot.efi`/`efisys.bin` for same-named, same-size files, adding
nothing new) sidesteps this; adding brand-new files to the tree does not.

**Update, same day, later session:** the framing above ("OVMF hangs") turned
out to be wrong in an important way -- see the next section. Keeping the
table above because the *empirical* per-config results in it are still
accurate and useful; only the explanation was off.

## Update: it's not an OVMF hang, it's a guest-internal crash-reboot -- and CPU, not I/O

Proved via `dmesg -T` on the Proxmox host during a "hung" boot: the VM's own
`tap9006i0` host-side network interface never flapped (no unregister/recreate
events) while the screen was stuck looping through the OVMF splash. If OVMF
or the qemu process itself had actually restarted, that interface would have
been torn down and recreated -- it wasn't. The *qemu process never restarted*
across the whole "hang." What looks identical to a fresh POST on screen is
actually the **guest** doing a full ACPI/hardware reset from inside Windows
Setup's WinPE environment, which naturally restarts the video output from
OVMF's splash too. This reframes the entire earlier investigation: it was
never a firmware boot-catalog issue -- it's the same class of bug as the
historical nested-`<PnPCustomizationsWinPE>` bug and the vioscsi-path bug
above (something in the automated windowsPE pass fails, WinPE crashes, the
system does a hardware reset), just not yet root-caused to a specific line
in `autounattend.xml`.

Two things made real progress on this same-day, in this order:

1. **A single combined ISO (no second device) is buildable and does boot**,
   contrary to the earlier "xorriso can't do this" conclusion above -- that
   conclusion was specific to *in-place* modification (`-boot_image
   patch`/`replay` on the existing Windows ISO). The reliable technique is a
   **full rebuild**: extract the entire ISO to a directory (`cp -a` off a
   loopback mount, not `xorriso -osirrox extract`, which only pulled 1 node
   for this particular ISO for unknown reasons), overlay the no-prompt boot
   files + `autounattend.xml` + `enable-winrm.ps1` + `vioscsi/` at the tree
   root, split `sources/install.wim` into sub-4GB `sources/install*.swm`
   parts with `wimlib-imagex split` (this xorriso build has no `-udf`
   support in `-as mkisofs` mode, and ISO9660 alone caps single files at
   ~4GB -- Setup natively detects and uses split `.swm` files with no
   answer-file changes needed), then rebuild fresh with `xorriso -as
   mkisofs -iso-level 4 -J -joliet-long -R -eltorito-boot boot/etfsboot.com
   ... -eltorito-alt-boot ... -eltorito-boot efi/microsoft/boot/efisys.bin
   ...` (matching Microsoft's original dual BIOS+UEFI El Torito catalog
   structure -- a single-entry UEFI-only catalog also produced a valid,
   bootable image, so the dual entry isn't required, just what was tested).
   This avoids the second-device question entirely: everything lives on
   `ide0`, so there's no `ide1`/`scsi1` visibility problem to solve at all.

2. **`<DriverPaths>` only listed `D:/E:/F:`, narrower than
   `enable-winrm.ps1`'s own `D E F G H` loop** -- widened to `C:` through
   `H:` to remove the mismatch as a possible cause of Setup failing to find
   the vioscsi driver on a single-ISO layout (where the drive letter the ISO
   itself gets is not guaranteed to be the same as in the old two-device
   layout). Applied to `http/autounattend.xml` in this repo.

With both changes, boots got *meaningfully further* than any earlier
config -- one clean run reached Windows Setup's own purple background
(the real Setup UI, not firmware) at ~185s before eventually crash-rebooting,
well past where every earlier config had already failed. But **run-to-run
timing on the identical ISO is wildly inconsistent** -- a second clean run
(no keypresses, confirmed by process-of-elimination after ruling out
Shift+F10 spam interrupting OVMF's own any-key boot-menu listener as a
contaminating factor in earlier tests) was still stuck on the *same* OVMF
splash frame past 7 minutes, never reaching Setup at all in that run.

The likely reason: **the VM's qemu process sits at 150-200%+ CPU utilization
throughout the stuck period** -- this is a genuine busy-spin, not I/O wait.
Switching both `ide0` (the ISO) and `scsi0` (the OS disk) from Proxmox 9.2's
default `aio=io_uring` to `aio=threads` did *not* fix it (still 205% CPU
after the switch), which rules out an io_uring-specific QEMU bug as the sole
cause, but the busy-spin itself is real and is the most likely explanation
for both the inconsistent timing and the eventual crash (something is
retrying in a tight loop instead of blocking on I/O, and either succeeds
once by chance before a watchdog fires, or doesn't).

**State at end of session (2026-08-22):** VM 9006 on the Proxmox host is the
disposable scratch VM used for all of this -- currently stopped.
`/nvmePCI/template/iso/Win11_combo-rebuild.iso` (the single-ISO rebuild with
widened DriverPaths) was deleted afterward at user request, along with every
screenshot taken during this investigation -- re-run the extract + overlay +
`wimlib-imagex split` + `xorriso -as mkisofs` steps above to reproduce it;
none of that is a one-time cost except the `wimlib-imagex split`, which is
slow (~7GB) but deterministic. The extraction tree (`/root/winiso-extract`
on the Proxmox host) is still there, so at least that step doesn't need
repeating -- but double-check it's still present before assuming so, since
it's 7.8GB of scratch data and may get cleaned up too.
`windows11.pkr.hcl`'s provisioner is still swapped to the bare inline test
from earlier in this file's history, not the real `provision-apps.ps1` --
restore that once a build completes cleanly end to end.

**Not yet tried**, in rough order of promise now: (1) find what's actually
spinning -- attach `strace -p <qemu-pid> -c` or `perf top -p <pid>` on the
Proxmox host during a stuck boot to see which syscall/function is hot,
which would settle the CPU-spin question directly instead of inferring it
from `ps`; (2) capture OVMF's own debug log via a `serial0` device wired to
a socket/file (Proxmox's default OVMF build doesn't surface debug messages
to the video console) to get an actual panic/exception reason instead of
inferring one from screenshots -- now more promising than before since we
know the crash happens well into Setup, past OVMF, so a serial log capturing
WinPE/Setup's own output (if any reaches a virtual COM port) might show the
real error; (3) mount the OS disk (`scsi0`) after a crash, before the next
attempt overwrites it, and check `Windows/Panther/setupact.log` /
`setuperr.log` for whatever Setup itself logged right before the crash;
(4) try `cores`/`sockets` = 1 (rule out an SMP-specific race in WinPE); (5)
check Proxmox's bug tracker for this exact `pve-qemu-kvm 11.0.0-3` version
given how recent it is.
