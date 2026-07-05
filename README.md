# c60-rootfs

Builds the slim Debian bookworm arm64 **Wayland/Cage kiosk** rootfs for
the **Polycom Trio C60** conference device (i.MX 8M Mini Quad, codename
`kepler_proto1`).

This repo only produces the rootfs.  The kernel comes from
`c60-kernel-patches` (a mainline Linux 6.6 patch series); the flashable
`boot.img` / `dtbo.img` / `vbmeta.img` artifacts are assembled by
`c60-firmware-build`, which embeds this repo as a submodule and packs
the rootfs into the raw ext4 `rootfs.img` flashed to `system_a`.

The C60 is a touch device, so the rootfs boots straight into a
fullscreen kiosk: the Cage compositor running the Cog/WPE WebKit browser
on the DRM/KMS console — the same Wayland/Cage model as `tc8-rootfs` —
plus the C60-specific boot-control and networking units.  Room is left
for C60-specific extra features on top of the base kiosk (see
[C60-specific extras](#c60-specific-extras)).

## What this builds

- `out/rootfs.tar.gz` — minbase Debian bookworm arm64 chroot with:
  - the Wayland kiosk stack (Cage compositor + Cog/WPE WebKit browser,
    seatd, Mesa/EGL)
  - the systemd-networkd stack and baked SSH host keys
  - the C60-specific units — `c60-mark-slot-success.service` (marks the
    A/B boot-control slot A successful so u-boot stops decrementing
    `tries_remaining`) and `c60-fec-mac-from-cmdline.service` (applies
    the `androidboot.ethmacaddr=` cmdline MAC to the FEC conduit + DSA
    `lan` port)
  - the BCM4356 Wi-Fi and NXP SDMA vendor firmware staged into
    `/lib/firmware/`
  - the `/etc` overlay applied on top

## Quick start

```bash
sudo apt-get install debootstrap qemu-user-static binfmt-support \
                     rsync tar gzip
sudo ./build.sh
```

Output: `out/rootfs.tar.gz`.  `c60-firmware-build/images/rootfs.sh`
turns that into the raw ext4 `rootfs.img` flashed to `system_a`.

## Build knobs

- `C60_ROOT_PASSWORD=...` — root password baked for tty + ssh
  (default `root`)
- `C60_SSH_PUBKEY=/path/to/id_ed25519.pub` env, or a `./authorized_keys`
  file (gitignored), to bake an SSH authorized key

## Repo layout

```
build.sh            # host-side: debootstrap, chroot, overlay, tarball
chroot-setup.sh     # runs inside the chroot: apt + cleanup + enable units
package-list.txt    # one Debian package per line (comments OK)
etc/                # files copied verbatim into the rootfs at the same path
out/                # build output (gitignored)
```

## What's installed

`package-list.txt` (~33 packages) covers:

- Boot/init: systemd, systemd-sysv, systemd-resolved, systemd-timesyncd,
  udev, dbus, libnss-systemd
- Networking: iproute2, iputils-ping, isc-dhcp-client, openssh-server
- Wayland kiosk: cage compositor, cog launcher, WPE WebKit + libwpe-fdo,
  xwayland (cage hard-requires it)
- GPU + input: seatd, libinput-bin, libegl1, libgles2, mesa-utils
- Minimal utils: util-linux, psmisc, procps, less, curl, ca-certificates,
  busybox-static, python3
- Locale/clock polish: locales, fake-hwclock
- u-boot env editing from running Linux: u-boot-tools, libubootenv-tool
- Audio tools: alsa-utils (`aplay`, `arecord`, `speaker-test`, `amixer`,
  `alsaucm`) and ffmpeg for decoding compressed audio formats into ALSA

`--no-install-recommends` everywhere; `/usr/share/doc`, `/usr/share/man`,
non-`en` locales stripped via `dpkg path-exclude`.

## Configuration

Per-build defaults live in `etc/`:

- `etc/systemd/system/c60kiosk.service` + `usr/local/bin/c60kiosk.sh` —
  the cage + cog kiosk. Runs as the `kiosk` user under `seatd` (no VT /
  logind session), scans out on the DSI panel
  (`WLR_DRM_DEVICES=/dev/dri/card1`) and renders GL on the Vivante GC520
  (`WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128`), fullscreen-showing
  `etc/tc8-kiosk/touchtest.html`
- `etc/tc8-kiosk/touchtest.html` — the bundled multi-touch test page
- `etc/udev/rules.d/99-c60-touch-calib.rules` — libinput calibration
  matrix (`-1 0 1 0 -1 1`) that flips the ft5x06 touch X+Y to match the
  panel mount (rootfs-only; no device-tree touch invert)
- `etc/udev/rules.d/{50-drm,70-seat}.rules` — give the `kiosk` user
  group access to `/dev/dri/*` and seat-tag `/dev/input/event*` so
  libinput finds the touchscreen
- `etc/systemd/network/lan.network` — DHCP on the DSA `lan` interface
- `etc/systemd/system/c60-mark-slot-success.*` and
  `etc/systemd/system/c60-fec-mac-from-cmdline.*` — the C60 boot-control
  and FEC-MAC units described above

## C60-specific extras

The rootfs is structured as a kiosk with headroom for C60-specific
features layered on top of the base Cage/Cog stack.  Extra packages go
in `package-list.txt`, extra config in the `etc/` overlay, and extra
units in `etc/systemd/system/` enabled from `chroot-setup.sh`. Python 3 is
included in the released image for on-device diagnostics and local service
helpers.

Audio is exposed through the ALSA card `keplerc60`. See `AUDIO.md` for
the hardware topology, PCM names, playback examples, capture examples, and
troubleshooting commands.

## SSH host keys

`chroot-setup.sh` runs `ssh-keygen -A` inside the chroot so every build
gets a fresh, unique set of host keys.  Keys are not committed to this
repo.

## Known limitations

- SSH host keys are per-build, not per-device (see above).

## Licensing

Build scripts and config files in this repo: GPL-2.0-only (see
`LICENSE`).  Installed Debian packages: their respective upstream
licenses (mostly GPL-2.0+ and LGPL-2.1+).
