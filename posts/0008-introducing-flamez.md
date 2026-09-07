Name: introducing-flamez
Title: Introducing Flamez
Description: A realtime build visualizer from vibes
Draft: false
Publish Date: Sep 6, 2026
---

I saw a tweet somewhere that pointed to [Daniel
Hooper's](https://danielchasehooper.com/posts/syscall-build-snooping/) build
time visualizer. He's got a callout at the end to try it, but I honestly don't
have any sufficiently large projects where running this would be interesting and
didn't want to bother asking for access. This project obviously takes
inspiration from the original!

At the same time, I was playing around with [ClayUI](https://www.clayui.com/) +
[raylib](https://www.raylib.com/) combo and figured I'd could see how far
gpt-5.6 sol could go in building one for me. It basically built it, though not
quite in one shot. I just guided it to use eBPF for linux and let it figure
everything else out. I knew just enough about eBPF that it should have
sufficient access to all the data we need to build this GUI, but nothing else.
Majority of the additional prompting was for:
- Improving visuals
- Improving performance
- A few bugs

The more I knew exactly what I wanted, the better sol would perform in general.
Mod one really weird bug[^bug], it was actually quite smooth sailing.

![building-self](video-self.mp4 "zig build for self"){gif}

I also asked for these features so that maybe this tool could be useful one day
(but really this is just a for fun vibe coded project):
- __Timeline zoom/keyboard/mouse support__: easily zoom in and out with
`ctrl+(mouse wheel)` or `ctrl+-/ctrl+=` (to reset: `ctrl+0`)
- __Thread CPU usage__: with just the parent/leaf bars, we need to guess why the
parent node is "idle". Seeing the CPU usage per bar at least lets us
disambiguate I/O time with CPU time (e.g if the parent process is performing
work in a thread pool vs being blocked by I/O).
- __Detailed pane__: this shows the exact command and args passed, it also follows
`exec`'s so we can see what the original command was before the process got taken
over by another command.
- __Import/export__: the entire trace data can be exported (and imported) via a
single JSON file
- __Anylsis mode__: a lossy conversion of the trace file ideally fit for agents to
troubleshoot any build slowdowns faster, though haven't seen it be that useful
yet. (Without actual integration into build tools, `flamez` will never have the
sufficient context to build a real DAG. It's hueristics all the way down.)

Some random builds for fun (these are fully collapsed, these are run on a
32-core machine so traces get _deep_):

![building-llama-cpp-vulkan](flamez-llama-cpp.png "llama.cpp (vulkan)")

![building-ghostty](flamez-ghostty.png "ghostty (debug)")

![building-ghostty-detailed](flamez-ghostty-detailed.png "ghostty
detailed pane")

It even supports macOS. I don't know anything about the underlying APIs used,
though supposedly in macOS 27, there's a better API being released, hence the
"best effort" label for now:

![building-self-macos](flamez-macos.png "flamez macos")

![building-self-macos-detailed](flamez-macos-detailed.png "flamez macos")

After becoming a father this year, it's amazing I can still work on these side
projects (and actually finish them). Queuing up a bunch of work and coming back
to seeing your asks mostly met is honestly a big hit of dompamine.

[Source](https://github.com/hspak/flamez)

[^bug]: In KDE, the dock will display a volume icon if that window is playing
    sound. I had helium (chromium-based browser) playing a video and noticed
    that flamez was also getting the volume icon... Something in KDE was saying that
    `helium app_id == flamez app_id` which is obviously false. I checked that helium
    properly sets the `app_id` in wayland. Flamez did not have an `app_id` set
    though. And it turns out there's some bug somewhere in the pipewire/KDE stack
    that is causing pipewire to see helium's `app_id` as `""`. Flamez' `app_id` was
    also `""` because it didn't have one. So due to `"" == ""`, that bad volume
    association bug happened. Ideally, I'd submit a bug report to KDE, but I don't
    know enough of the problem to write a coherent bug report. The fix for flamez
    also required a
    [patch](https://github.com/hspak/flamez/commit/1701f8f2f5c86c77ee40a9a4d7c04c6c75775609)
    to raylib. It's wayland GLFW backend currently resets all window hints and
    doesn't allow setting hints before the window gets drawn. Raylib is vendored in
    this project, so I just added a small workaround (too hacky to upstream).
