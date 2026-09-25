# NetUnstick app icon

The sign is a three-node local network with a continuous restored route. There is no text, third-party mark, or baked system mask. All five variants share the same vector geometry. `Sources/<variant>/` contains separate SVG layers (`background`, `route`, `nodes`) on a 1024 × 1024 viewBox:

- `Default`: dark teal tile and turquoise route, used by the macOS asset catalog.
- `Dark`: deeper navy tile for a dark appearance.
- `MonoTinted`: neutral blue tile and pale route as a monochrome/tint source.
- `ClearLight`: transparent canvas with dark silhouette for a light surface.
- `ClearDark`: transparent canvas with light silhouette for a dark surface.

These are **design sources**, not system-selected variants in the current app. `Generated/ContactSheet.png` shows, from top to bottom, the variants above; each row has 16, 32, 64, 128, and 512 px on light (left) and dark (right) backgrounds. ClearLight and ClearDark are intended for their matching surface.

## Regenerate and check

Run from the repository root:

```sh
swiftc -o /tmp/netunstick-appicon-generator Tools/AppIconGenerator/main.swift -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -framework CryptoKit -framework CoreText
/tmp/netunstick-appicon-generator
swiftc -o /tmp/netunstick-appicon-tests NetUnstickTests/AppIconAssetTests.swift -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers
/tmp/netunstick-appicon-tests
xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

The Swift/CoreGraphics generator reads the SVG layers, renders 10 macOS slots (16, 32, 128, 256, 512 pt at 1×/2×), checks PNG dimensions and alpha, writes `Contents.json`, and creates variant PNGs and the contact sheet. It refuses to overwrite unknown files or an edited generated file using an ownership marker and SHA-256 manifest. To intentionally replace a generated asset, edit its SVG source, then rerun the generator. Do not edit generated PNGs by hand.

The installed Xcode 27.0 includes `ictool`, whose help documents **exporting** images from an existing `.icon` document. `iconutil` accepts only `.icns` and `.iconset`. No documented command in the installed toolchain creates a layered `.icon` from SVG/PNG sources without the Icon Composer application, and no valid `.icon` document was available for a build proof. Therefore this repository does not claim system Default/Dark/Tinted/Clear switching or ship an invented `.icon`. The complete source variants remain ready for a future validated Composer workflow; `AppIcon.appiconset` is the built macOS 14.0-compatible fallback.

The legacy icon has a full-square tile; macOS applies its own icon mask. A visual Dock/Finder check needs an active graphical session and screen-capture permission. The contact sheet and asset tests are available without GUI access.
