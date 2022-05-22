Name: publish-npm
Title: Publishing a Go binary to NPM
Description: Why does NPM feel like remote code execution as a service?
Draft: false
Publish Date: May 22, 2022
---

I recently published a Go binary to [NPM](https://www.npmjs.com/), similar to
how [esbuild](https://github.com/evanw/esbuild) is a go binary that's also
published to NPM. When I finally understood how publishing NPM packages worked
(on a surface level), I had this... uncanny feeling on how much flexibility NPM
provides to anyone who wants to publish a package.

It ultimately allows the user to **upload a directory of whatever** they would like
and write an **arbitary javascript code that is allowed to run on install**.

### Publishing Go to NPM

The first question may be why I'm bothering to try this in the first place? I
hacked on a [weekend project](https://github.com/hspak/gopm3) to ~spite~
scratch an itch on how much work it would take to replace
[pm2](https://github.com/Unitech/pm2) for some basic process "management" for
local dev purposes. I wanted to maintain feature parity for things I cared
about, one of which was ease of installation for JS devs.

All that was really required to publish an NPM package is to have a directory with
a `package.json` file, stick whatever else you'd like in that directory, and use
their CLI tool to publish it to their registry. To break down the full
requirements of publishing Go to NPM, it is:
- Build the go binaries targetting the OS/Architectures you'd like to support.
- Place the go binaries in the NPM directory.
- Have an install script that checks to see what OS/Arch the requesting system is.
- Have a small javascript shim to run the correct go binary as a child process.

Esbuild goes one step further that this and leverages the `optionalDependencies`
feature of NPM to only download the go binary for the exact OS/Arch of the
requesting system. I've opted for the dumb and simple route of just publishing
all the go binaries in the same package.

### How I Implemented

I started with a completely bottoms up approach because I knew nothing about
publishing NPM modules going into this project. But as a result, I think what I
ended up with is the most simple process you could have (though it's not
automated and not really reproducible the way it's setup today).

First, I have a dedicated `npm` directory that represents the skeleton of the
NPM package that will ultimately be published. The things that matter are:
- These bits in the `package.json`:
  ```json
    "scripts": {
      "postinstall": "node install.js"
    },
    "bin": {
      "gopm3": "src/index.js"
    },
  ```
  The `postinstall` step runs a script to determine which go binary we need to
  actually install and delete the rest.

  The `bin` specifies the entrypoint of the program which is a JS shim to
  execute the go binary as a child process.
- There is a dumb shell script that builds the go binaries for all the OS/Arch
  pairs that we care about and places them in the NPM dir where the
  `postinstall` script expects them. It then templates out a `package.json` just
  to update the version. To finish, we tag the git repo and call the `npm` CLI
  to publish the `npm` directory to their registry.

Feel free to check out the [project repo](https://github.com/hspak/gopm3) to see
the full picture! (And the [npm package](https://www.npmjs.com/package/@hspak/gopm3) itself)
