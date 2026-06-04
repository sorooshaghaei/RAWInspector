# Changelog

## 2.3.0 — Mac Catalyst and Apple arm64 compatibility

- Enabled Mac Catalyst in the Xcode project.
- Added macOS support through the same SwiftUI/UIKit Catalyst target.
- Supported platforms now include iPhone, iPad, iOS Simulator, and Mac Catalyst.
- Targeted device families now include iPhone, iPad, and Mac.
- Documentation updated to clarify Apple arm64 compatibility and platform limits.
- App text updated from “iPhone or iPad” to “device or Mac” where relevant.

## 2.2.0 — Photos import and report fixes

- Added Choose from Photos.
- Kept Choose from Files for original RAW reliability.
- Fixed blank PDF export by forcing white report pages with black text.
- Fixed PNG report rendering for Dark Mode cases.

## 2.1.0

- Added PDF seller/buyer report export.
- Added PNG seller/buyer report export.

## 2.0.0

- Added best-effort Nikon metadata support.
- Added Canon and Sony metadata inspection with warnings where shutter count is unavailable.

## 1.2.0

- Added batch inspection for multiple RAW files.

## 1.1.0

- Added camera model, firmware/software, serial number, lens, capture date, file verification, and warning fields.

## 1.0.0

- Initial Fujifilm RAF shutter/image count inspector.
