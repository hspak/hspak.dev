Name: framework-laptop
Title: Framework Laptop
Description: Theoretically the last laptop I will buy*
Draft: false
Publish Date: November 14, 2021
---

I recently purchased the [framework laptop](https://frame.work) for personal
use and have been dailying it for almost a month now. It's spec'd as follows:
- DIY Edition
- i7-1165G7 (will be referring to this as the tiger lake CPU)
- Intel wifi AX210 no vPro
- [1 TB SK hynix Gold P31](https://www.amazon.com/gp/product/B08DKB5LWY)
- [32 GB Crucial DDR4 3200 MHz](https://www.amazon.com/gp/product/B08C4X9VR5)
- 2x USB-C, 1x USB-A, 1x microSD modules

[The install process was super easy](https://guides.frame.work/Guide/Framework+Laptop+DIY+Edition+Quick+Start+Guide/57),
except for hooking up the tiny connectors for the wifi module. I also recently
got an M1 max macbook for work and the build quality is honestly not far behind.
It's respectable considering it's almost 3x cheaper than the macbook. There are
a couple things I would like to see improved however:
- The hinge feels a bit too stiff and wobbles a bit more than I'd like. Compared
  to the macbook hinge, it feels lacking.
- The venting is also a bit lacking and the CPU feels like it's choking at times
  (though this is probably the consequence of the CPU choice -- more on this
  later).

I have Arch linux on it with [my own bespoke
installer](https://github.com/hspak/homelab/blob/master/laptops/fmw) and almost
everything _just works_.

I'm coming from a Lenovo Thinkpad X1 Carbon Gen 5 so my thoughts will be
baselined from how the Framework laptop performs against it.

### What Works Well

The display is great (though glossy) and the 3:2 aspect ratio is great. I am
running a wayland based window manager and the HiDPI is not an issue -- I had no
problems with scaling. I also love the manual kill switches for the webcam and
microphone.

The keyboard is also solid and I don't feel any sort of flexing. I do want to
re-iterate that the build quality is great considering they optimized the laptop
for full repairability.

The Framework team is fairly active on their [community forum](https://community.frame.work/)
which is great to see. Some examples:
- They were proactive about letting users know of the
[bluetooth issues on linux](https://community.frame.work/t/using-the-ax210-with-linux-on-the-framework-laptop/1844).
- They're currently working on getting the
[bios update support through LVFS](https://community.frame.work/t/public-beta-test-bios-v3-06-driver-bundle-2021-10-29/10167/100).

### What Doesn't Work Well

The CPU is super power hungry and I've seen it temporarily pull ~42W of power on
on occasion which spikes the CPU temps to 100C. For sustained load, it seems to
maintain a steady ~28W of power draw and usually hovers around 80C. This wouldn't
necessarily be an issue, but the fan is quite loud when it kicks on and it tends
to kick on more often than I'd like. (Numbers were pulled from [s-tui](https://github.com/amanusk/s-tui).)

The tiger lake CPU doesn't [suspend well](https://twitter.com/jeremy_soller/status/1335591509207384065?s=20).
_Technically_ tiger lake on the Framework does support deep sleep which you can
enable by toggling the method in `/sys/power/mem_sleep`, but it seem to cause
resuming to take an absurd amount of time (10+ seconds). You may as well
just poweroff the laptop at that point. For reference, mine boots around 12
seconds pretty consistently:
```
$ systemd-analyze
Startup finished in 7.670s (firmware) + 249ms (loader) + 1.129s (kernel) + 288ms (initrd) + 3.025s (userspace) = 12.364s 
```
The current (and default) suspend setup eats a significant amount of power.
Anecdotally, it drains 2.5% to 3% of the battery per hour. This is a huge
regression from my Thinkpad which could stay suspended for a week and I still
wouldn't have to worry about battery life. This is probably my biggest complaint
of the laptop.

### Concluding Thoughts

I think the Framework laptop is great, but unless you absolutely need a laptop
today -- I would recommend you wait until there is a better CPU option. The
thermal load combined with the suspend issues make the tiger lake a really
annoying option as a laptop CPU.

If Framework is able to continue to grow their marketplace and start supporting
more CPU and other components, I think there's zero reason for me to purchase
another laptop. I would love to be able to swap the CPU/mainboard at some point
in the future.
