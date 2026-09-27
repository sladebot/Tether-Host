Tether Guest Installer for Debian Desktop (ARM64)

Open Files, select the TETHERTOOLS disk, and launch Tether Guest Installer.
The guide prepares guest tools, connects Tailscale, installs Hermes, guides
model sign-in, enables computer use, and verifies the private connection.
Progress and detailed output stay inside the installer window.

Debian asks for your administrator password when system packages are needed.
Enter it only in Debian's authentication dialog. Complete provider sign-in
inside the VM. Do not share passwords or connection tokens.

After preparing tools, the guide is also available in the applications menu.
Existing Hermes data and connected Tailscale installations are reused.

Computer use may require Debian on Xorg; the guide checks the desktop before
verification. Text clipboard works from the logged-in desktop with either
Wayland or Xorg. Guest tools enable it during setup, and Tether Text Clipboard
in the applications menu can turn it off. Text moves only when you choose a
clipboard button in Tether Host; the clipboards do not synchronize in the
background.
