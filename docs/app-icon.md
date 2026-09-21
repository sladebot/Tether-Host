# Tether Host app icon

The macOS app reuses the exact Tether iOS artwork: a cream Tether mark on a
near-black background. Source: `Personal-Agent/Tether/Resources/Assets.xcassets/
AppIcon.appiconset/AppIcon.png` in the sibling iOS repository.

`TetherHost/Resources/Assets.xcassets/AppIcon.appiconset` contains all ten macOS
16, 32, 128, 256 and 512 point representations at 1x and 2x. The 1024 pixel
representation is an unchanged copy of the iOS source; smaller PNGs were resized
with macOS sips. Debug and Release both select the AppIcon asset catalog entry.
Xcode generates the bundled AppIcon.icns and icon metadata during the build.

When the iOS icon changes, replace the 1024 pixel representation with that source
and regenerate each smaller representation with `sips -z PIXELS PIXELS SOURCE
--out DESTINATION`, using the dimensions from Contents.json.
