# Camera RAW Inspector / RAW Inspector

App Store-oriented SwiftUI iPhone/iPad project for camera RAW metadata inspection, Fujifilm RAF Image Count reading, batch inspection, and seller/buyer report export.

Copyright © 2026 Soroosh AGHAEI. All rights reserved.

## Current version

Version: 2.3.0  
Build: 5

## Main features

- Choose from Photos for convenience.
- Choose one or more original RAW files from the iOS Files app for the most reliable shutter-count reading.
- Batch inspect multiple files.
- Read camera model, brand, firmware/software, serial number when stored, lens model when stored, capture date, file size, file verification, and metadata status.
- Read Fujifilm `.RAF` Image Count from MakerNote tag `0x1438`.
- Best-effort Nikon `.NEF` / `.NRW` shutter count reading when MakerNote tag `0x00A7` is available and readable.
- Canon `.CR2` / `.CR3` and Sony `.ARW` metadata inspection, with clear warnings when shutter count is not available from normal RAW metadata.
- Warn when metadata is missing, MakerNote is stripped, file extension is unsupported, the file looks too small for RAW, or the software field suggests editing/export.
- Export a seller/buyer report as PDF.
- Export a seller/buyer report as PNG.
- Local-only processing: no upload, no analytics, no ads, no account system.
- Responsive SwiftUI layout designed for different iPhone, iPad, and Mac Catalyst window sizes.
- Mac Catalyst enabled for running on macOS from the same project.

## Version roadmap implemented in this package

### 1.0

Fujifilm RAF shutter count, clean UI, local-only privacy, and clear disclaimers.

### 1.1

Camera metadata fields: model, serial number when available, firmware/software, lens used, date, file type verification, missing metadata warning, edited/exported file warning.

### 1.2

Batch inspection for multiple RAW files.

### 2.0

Added Canon/Nikon/Sony support where metadata allows it. Fujifilm remains the strongest supported shutter-count path. Nikon shutter count is best-effort. Canon and Sony shutter counts often remain unavailable because many files do not expose a reliable count in ordinary RAW metadata.

### 2.1

PDF and PNG seller/buyer report export.

### 2.2

Photos import added. Files import kept for original RAW reliability. Blank PDF export fixed by forcing white report pages with black text.

### 2.3

Mac Catalyst support enabled. The same project can run on iPhone, iPad, iOS Simulator, and Mac Catalyst destinations in Xcode. Compatibility documentation updated for Apple arm64 devices.

## Compatibility

This project targets iPhone and iPad with iOS/iPadOS 16.0 or later, and Mac through Mac Catalyst with macOS 13.0 or later. It supports Apple arm64 iPhone/iPad devices that can run iOS/iPadOS 16+, and Apple Silicon Macs through the Mac Catalyst build. It does not support Apple Watch, Apple TV, Android, Linux, Windows, or older iPhones/iPads that cannot install iOS 16.

## Project status

This is not a signed IPA. To publish or install it on a physical iPhone, open the Xcode project and sign it with your own Apple Developer account.

1. Open `RAFShutterCount.xcodeproj` in Xcode.
2. Select the app target.
3. In **Signing & Capabilities**, select your Apple Developer team.
4. Confirm or change the bundle identifier: `com.sorooshaghaei.rafshuttercount`.
5. Build and test on real iPhone/iPad devices and on **My Mac (Mac Catalyst)**.
6. Test with multiple original `.RAF`, `.NEF`, `.CR2`, `.CR3`, and `.ARW` files.
7. Test both **Choose from Photos** and **Choose from Files**.
8. Export PDF and PNG reports in Light Mode and Dark Mode.
9. Archive the app in Xcode.
10. Upload the archive to App Store Connect.
11. Add screenshots, app metadata, support URL, and privacy policy URL.
12. Submit for App Review.

## Important limitations

Shutter count is not standardized across camera manufacturers.

- Fujifilm RAF: supported through MakerNote Image Count tag `0x1438`.
- Nikon NEF/NRW: best-effort support where MakerNote tag `0x00A7` is present and readable.
- Canon CR2/CR3: metadata report supported; shutter count often unavailable from ordinary RAW metadata.
- Sony ARW/SR2/SRF: metadata report supported; shutter count often unavailable from ordinary RAW metadata.

The app should not claim forensic certainty. Firmware updates, service events, stripped metadata, exported files, or model-specific storage differences can affect the stored values.

## Recommended App Store privacy answer

For this version, the expected App Privacy answer is normally:

**Data Not Collected**

Reason: all processing is local, no network upload is used, no analytics SDK is included, no advertising SDK is included, and no user account system exists.

You must verify this before submission. If you later add analytics, crash reporting, ads, cloud upload, server-side processing, or user accounts, the privacy answer must change.
