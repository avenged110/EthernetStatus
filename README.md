# Ethernet Status

A macOS 15 MenuBar applet that shows whether or not a wired Ethernet connection is active.

- Optionally display the IP address of the primary interface in the menu (not the MenuBar).
- Optionally enumerate currently-attached Ethernet interfaces, with or without internal ones.

There are a bunch of these utilities available for macOS, but I never liked any of them. So Ethernet Status joins the stack of options. Plus, it uses Apple's private SF Symbols "ethernet" glyph, which looks nice.

## Installation

Ethernet Status is not signed with an Apple Developer ID and is not notarized. To launch it, you can either disable Gatekeeper, remove the quarantine flag manually with the command below (using the appropriate path for your installation, of course), navigate to System Settings > Privacy & Security and click "Open Anyway" after first attempting a launch, or build it yourself with Xcode (open `Ethernet Status.xcodeproj` in Xcode and choose Product > Build).

```sh
xattr -dr com.apple.quarantine "/Applications/Ethernet Status.app"
```

## System Requirements and Security

- macOS 15.6.0 or later, Apple Silicon only.
- An Ethernet port or adapter is required for this to be useful.
- Sandboxed, uses Apple's Hardened Runtime, and is compliant with Swift 6 (Strict Concurrency and Strict Memory Safety); built against Xcode 26.3.

## Support

If you find a bug, please report it here on GitHub and I will try to fix it. If it affects macOS 15, I will try harder. Please be as thorough in your reporting as you can.

You're welcome to request features or changes if you're so-inclined, and I will give such requests due consideration, but just know that this application was built first and foremost for an audience of one and I consider it largely feature-complete at this time.

Ethernet Status is available in English only, by design.

## Note

I am not a software engineer; all of the code for this project was written by Anthropic's Claude models. That said, I use all of the applications under this account regularly in my daily life, so while they're not perfect, I'm confident in their efficacy and general reliability.

## License

Ethernet Status is free software, licensed under the GNU General Public License, version 3 only (GPL-3.0-only). Copyright © 2025 avenged110. The full license text is in `COPYING`.
