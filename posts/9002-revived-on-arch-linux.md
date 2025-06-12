Name: on-arch-linux
Title: On Arch Linux
Description: Revived post from my older blog
Draft: false
Publish Date: Mar 5, 2014
---
(Revive note: I lost the original images and a lot of links are dead.)

I recently helped a friend of mine install [Arch Linux](https://archlinux.org/)
and it’s motivated me to write about Arch. This is not a tutorial or promotional
blog for Arch. These are my ramblings on Arch, my experiences with Arch and my
recommendations for using Arch.

## Brief Personal History

I found Arch Linux sometime early in 2009 when I grew bored of how Windows XP
looked and wanted an easier way to make my system look more ‘l33t.’ Windows
Vista was not encouraging and Windows 7 was not yet released. I practiced
installing inside a Virtualbox machine and eventually, managed to setup
successful installation. Unfortunately, I didn’t have the courage to install on
bare metal thinking I might cause hardware damage if I do something wrong. With
the Windows 7 release around the corner, my interest in Linux dropped until 2011
where I had that itch to try something new again. I’ve been an active user
since.

## Installing Arch Linux

The biggest hurdle to almost everyone who wants to try Arch Linux for the first
time is the installation. In mid 2012, they
[announced](https://www.archlinux.org/news/install-media-20120715-released/)
that they removed their installer, named AIF (Arch Installation Framework), and
in its place, several small scripts are provided for convenience. At their
defence, The original installer software didn’t provide much functionality
except to show a very minimal GUI with a list of steps to finish the
installation.

`<missing-image>`

For those more experienced, this change allows faster installs, and those new
are at the mercy of the [wiki](https://wiki.archlinux.org/title/Main_page). They
also adopted a monthly release cycle for their install medias. Because Arch is a
rolling release, it makes no sense for the liveCD’s to have tools that are
heavily outdated.

The current Arch Linux installation really only has 3 major steps: - Setup your
disk and partitions Install base packages Setup the bootloader

I don’t plan on writing up an installation guide (the
[Arch](https://wiki.archlinux.org/title/Installation_guide)
[Wiki](https://wiki.archlinux.org/title/Help:Reading#Installation_of_packages)
pages on installation are fairly extensive, although be wary of the beginner’s
guide – I’ve seen some questionable recommendations), but I have a few remarks
on some potential quirks that some people may run into.

1. **[UEFI](https://en.wikipedia.org/wiki/UEFI)**: It is the new cool thing that
   replaces BIOS and is now shipped with all modern computers. It requires
   different steps than the traditional installs with BIOS. To check whether
   your machine uses UEFI or BIOS, go into your BIOS settings on boot and it
   should be indicated somewhere under Boot Options. If you have a pretty GUI,
   its UEFI. Usually computers that support UEFI also supports legacy boot so
   for some, they have the option to stick with the old. The noticeable
   difference during setup is that UEFI requires a specific boot partition. If
   you plan on dual booting, different system’s have different levels of
   support:

    - **Windows 7/8 32-bit**: UEFI is not supported.
    - **Windows 7/8 64-bit**: In order to use UEFI, your disk must use GPT which is
      a successor to the MBR
    - **OS X**: It already uses UEFI* and GPT. It doesn’t support MBR at all.
    - **Linux**: Any combination of MBR/GPT and BIOS/UEFI is supported. If you do
      plan on dual booting, try to install Linux second. OS X and Windows are pretty
      strict about their paritions and will auto-create the EFI parition. Then you
      can either choose to share the EFI parition or create a separate one for each
      system. I personally like to share the parition, but to each to their own. I
      also recommend gummiboot *(revive edit: this is now systemd-boot)*. It’s a
      very simple-to-setup UEFI boot manager.

    \* Apple uses their own EFI implementation which may or may not be compliant with
  the UEFI standards[1].

2. **Network Access**: Without any network access, you cannot install Arch
Linux. Why? There are no packages on the media for you to install. Going back to
the install media, it doesn’t make much sense to ‘store’ packages in a rolling
release distro. You’ll have an update to just about every package you have
installed. Every once in a while, updates require manual intervention. These
updates tend to break systems who’s system is very out-of-date. Check out the
infamous filesystem update. This makes it very difficult to install on systems
that can’t connect out-of-the-box (i.e Macbooks whose wifi drivers do not have
official support). Easiest way to setup on those systems would be to find a
prebuilt package (or build it yourself in another Arch system) to install the
wifi drivers through a flash drive. Some people have had success tethering their
phones as well.

3. **Dedicated Graphics Cards**: These bad boys don’t get much love from
anybody. The open source drivers perform underwhelmingly because neither AMD nor
Nvidia provide sufficient support. The open source drivers exist solely because
open source community was able to reverse engineer the GPU’s. There are binary
blobs available for both AMD and Nvidia, but their support is about a generation
behind, their performance is inferior to Windows[2] and it can be a pain to
setup properly. Valve appears to be working with Nvidia and Intel to ready their
release of SteamOS and Steam boxes so expect better support/performance
(hopefully). I recommend skipping the dedicated cards, especially on laptops.
The open source graphics drivers for Intel perform extremely well but the
switchable graphics systems blow on Linux. If you must have the power, Nvidia is
the only officially supported platform on Arch. Official AMD(ATI) support was
dropped several years ago.

Once the installation is complete, you have the bare Linux setup and it’s up to
the user to configure their settings to their desire. I believe this is one of
the biggest reasons why Arch has been consistently in the top 10 most used Linux
distributions[3]. The only software that is required by Arch is the Arch package
manager, pacman. Some could argue that systemd has been forced upon users, but
it has heavy support from Red Hat. Also, Debian (and Ubuntu) have announced that
they are transitioning to systemd so yay systemd! For the anti-fans, there are
so many alternatives gaining support from the Arch community.

In the end, the installation process is just a bunch of commands you run. I’ve
been writing a bare minimum installer for my personal use. It’s meant to setup
my current system from scratch.

## Using Arch Linux

These are a few tips on maintaining a healthy Arch installation.

- **Avoid Yaourt**: Do everyone a favor and choose a different AUR helper.
  Usually what happens is the new Arch users follow tutorials which tell them to
  install yaourt to install packages from the AUR. They blindly use this tool
  which completely removes the need to understand how the Arch packaging system
  works. Then they ask for help and then get derailed for not RTFM. I suggest
  cower. There are many wrappers also for cower available for those who want
  more automation.

- **Keep Your System Up-to-date**: Try to update your system at least once a
  week. I update my system daily and it has caused me no problems. The Arch
  developers work on up-to-date systems and make sure that their packages work
  with other up-to-date packages. It’s probably ideal to follow the developers.

- **Never pacman -Sy (package)**: This cherry-picks an up-to-date package with
  your out-of-date system. It’s an incredibly easy way to break your install.

- **Never Auto-Update Packages**: This is another taboo in Arch. Some packages
  have useful outputs when they update and they require some user intervention.
  You also want to know what you’re updating. If something randomly breaks,
  you’ll have a much harder time finding the cause. Don’t have a background job
  running pacman -Syu all the time. If you want to know if you have any
  out-of-date packages, pacman comes with a simple script called checkupdates
  which safely checks for out-of-date packages.

- **Arch Tools**: A tool I use often is pkgfile. It’s an incredibly useful tool
  that lets you know which package offers which file. Say a package was missing
  a dependency and it had some error stating a library was missing. Running
  pkgfile on that library will tell you what package to download only if it is
  in one of your pacman servers you have listed in /etc/pacman.conf. Arch also
  has ABS which is very similar to FreeBSD Ports. It’s useful if you need to
  build an official package with different flags. For example, I rebuild vim
  updates because the python interpreter for Vim is disabled on the official
  package and it’s required by the YouCompleteMe Vim plugin.

- **Reading PKGBUILDS**: When installing a new package from the AUR, it is good
  practice to look at the PKGBUILD’s before you install the package. Anyone can
  upload anything in the AUR. It’s your responsibility to check the integrity of
  the package.

- **Have a LiveCD available**: This is common practice for any Linux
  distribution, but it’s vital you have one for Arch. You may have an update
  that somehow broke your system and you can’t boot anymore. You can’t fix that
  without a LiveCD available.

- **The Kernel Issues**: Arch uses the newest stable release of Linux which may
  have some regressions. I had a pretty severe power regression a while back on
  my laptop which took several kernel iterations until it was finally fixed.
  Sometimes it may be more convenient to tell pacman to ignore the kernel
  updates if some problems arise in the newer ones.

- **Window Managers**: This is personal opinion, but I believe it is easier to
  maintain your system without a desktop environment (Gnome, KDE). Because DE’s
  are essentially software suites, there are many points of failure. When
  something doesn’t work the way you think it should, it’s more difficult to
  decided where to first look. Standalone window managers on the other hand do
  exactly as they’re labeled; they manage windows. Everything else is configured
  by the user, which also fits into the DIY mentally like the rest of Arch.

Obligatory screenshot to end the blog: `<missing-image>`.

----

[1] [Wikipedia](https://en.wikipedia.org/wiki/Unified_Extensible_Firmware_Interface#Operating_systems)

[2] [Maybe not always](http://blogs.valvesoftware.com/linux/faster-zombies/)

[3] It’s not the most accurate benchmark, but there seems to be no alternatives.

