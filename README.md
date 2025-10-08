# Wakeful

## Prevent automatic sleep and gracefully handle manual sleep by sending SIGINT to child processes.

Inspired by `caffeinate`, Wakeful prevents data corruption in long-running processes like [bitcoin-node-docker](https://github.com/sunknudsen/bitcoin-node-docker) by ensuring graceful shutdown before sleep.

## Installation

```console
$ swift build --configuration release

$ sudo cp .build/release/wakeful /usr/local/bin
```

## Distribution build (notarized)

> **Prerequisites:** 
> - Create “App Manager” API key on [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api)
> - Run `xcrun notarytool store-credentials wakeful-notarytool`
> - Run `cp .env.sample .env` and add your “Developer ID Application” signing identity

```console
$ source .env

$ swift build --configuration release

$ codesign --options runtime --sign "$CODESIGN_IDENTITY" --timestamp .build/release/wakeful

$ ditto -c -k --keepParent .build/release/wakeful wakeful.zip

$ xcrun notarytool submit wakeful.zip --keychain-profile "wakeful-notarytool" --wait

$ rm wakeful.zip
```

## Usage

```console
$ wakeful --help
Usage: wakeful [options] <command> [arguments...]

Options:
  -d, --display                 Prevent computer and display from sleeping
  -g, --grace-period <seconds>  Grace period for child process termination (default: 60)
  -h, --help                    Show this help message and exit
  -v, --verbose                 Make operation more talkative
  -V, --version                 Show version number and exit

Example: wakeful watch ls -la

```