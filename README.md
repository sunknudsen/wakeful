# Wakeful

## Build

```console
$ swift build
```

## Test

```console
$ .build/debug/wakeful --verbose ./test.sh

$ .build/debug/wakeful --verbose watch ls -la
```

## Release

```console
$ source .env

$ swift build -c release

$ codesign \
  --options runtime \
  --sign "$CODESIGN_IDENTITY" \
  --timestamp \
  .build/release/wakeful

$ ditto -c -k --keepParent .build/release/wakeful wakeful.zip

$ xcrun notarytool submit wakeful.zip \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait
```