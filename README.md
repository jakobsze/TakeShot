# Takeshot

A free, local-only screen recorder and editor for macOS. Record your screen, a window or an area
with your camera and microphone, then turn it into a polished video with automatic zooms, a smooth
cursor, a camera bubble, backgrounds and captions. Nothing is uploaded anywhere.

Takeshot is free. If it saves you time, you can support its development:

<a href="https://buymeacoffee.com/touchdesign"><img src="https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=&slug=touchdesign&button_colour=FFDD00&font_colour=000000&font_family=Poppins&outline_colour=000000&coffee_colour=ffffff" alt="Buy me a coffee" height="44"></a>

- Record a display, a window or an area, with camera, microphone and system audio
- Pause, resume, restart or discard while recording
- Automatic zooms that follow your clicks, plus a smooth, resizable cursor
- Camera bubble, wallpapers and gradients, rounded corners and shadows
- On-device captions
- Export to MP4, MOV or GIF
- A small recording pill you can dock to any edge or corner of the screen
- Automatic updates

Requires macOS 13 or later, on Apple Silicon or Intel.

## Install

1. Download `Takeshot-<version>.zip` from the
   [latest release](https://github.com/jakobsze/TakeShot/releases/latest) and double-click it.
2. Drag **Takeshot.app** into your **Applications** folder.
3. Open it. The first time, macOS says it can't verify the app (it isn't notarized by Apple yet).
   Click **Done**, then open **System Settings → Privacy & Security**, scroll down and click
   **Open Anyway** next to the Takeshot message, and confirm. You only need to do this once.
4. Allow the permissions Takeshot asks for:
   - **Screen & System Audio Recording**: to record your screen
   - **Camera** and **Microphone**: only if you record them
   - **Accessibility**: to record clicks and keystrokes for automatic zooms and the cursor
   - **Speech Recognition**: only if you create captions

   After granting Screen Recording, macOS may ask you to quit and reopen Takeshot.

Recordings are saved to `~/Movies/Takeshot`. Later versions install themselves through
**Check for Updates…** (in the menu-bar icon and the pill's ⚙︎ menu).

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```bash
make app       # builds and signs dist/Takeshot.app
make install   # also copies it to /Applications and launches it
```

The Makefile signs with your Developer ID or Apple Development certificate if you have one, and
falls back to ad-hoc signing otherwise (macOS then asks for permissions again after each rebuild).

## Acknowledgements

Automatic updates use [Sparkle](https://sparkle-project.org) (MIT License). Its license text ships
inside the app at `Takeshot.app/Contents/Resources/Sparkle-LICENSE.txt`.
