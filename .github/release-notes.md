## Install on macOS

1. Download **SwapBot.dmg** below, open it and drag SwapBot into Applications.
2. SwapBot isn't notarised by Apple, so macOS refuses to open it at first. Clear the download flag in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/SwapBot.app
   ```

3. Open SwapBot. It appears as a robot in the menu bar.

Requires macOS 15 or later, on Apple silicon or Intel. The command-line tool is inside the app at `SwapBot.app/Contents/Helpers/swapbot`, or download **swapbot-macos** on its own.

## Install on Linux

Download **swapbot-linux-x86_64** or **swapbot-linux-arm64** below. It's a single static binary:

```sh
install -m 755 swapbot-linux-x86_64 ~/.local/bin/swapbot
swapbot --help
```
