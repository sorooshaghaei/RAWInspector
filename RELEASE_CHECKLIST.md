# Release Checklist

## Code

- [ ] Open `RAFShutterCount.xcodeproj` in the current stable Xcode.
- [ ] Set your Apple Developer Team.
- [ ] Confirm bundle identifier.
- [ ] Confirm version `2.1.0` and build `3`.
- [ ] Build on a physical iPhone.
- [ ] Build on iPad or iPad simulator.
- [ ] Test small iPhone screen layout.
- [ ] Test large iPhone screen layout.
- [ ] Test landscape where supported.

## File tests

- [ ] Test an original Fujifilm `.RAF` file.
- [ ] Confirm Fujifilm Image Count reads correctly.
- [ ] Test an original Nikon `.NEF` or `.NRW` file.
- [ ] Test an original Canon `.CR2` file.
- [ ] Test an original Canon `.CR3` file.
- [ ] Test an original Sony `.ARW` file.
- [ ] Test an unsupported JPEG and confirm warning behavior.
- [ ] Test batch import with multiple RAW files.
- [ ] Test PDF report export.
- [ ] Test PNG report export.

## App Store Connect

- [ ] Create app record.
- [ ] Upload screenshots.
- [ ] Add support URL.
- [ ] Add privacy policy URL.
- [ ] Complete App Privacy with `Data Not Collected`, if no new data collection code is added.
- [ ] Add metadata from `APP_STORE_METADATA.md`.
- [ ] Upload archive from Xcode.
- [ ] Submit for review.

## Legal and wording

- [ ] Keep manufacturer disclaimer visible.
- [ ] Do not claim universal or forensic shutter-count certainty.
- [ ] Verify all rights and assets are owned by Soroosh AGHAEI or properly licensed.

## Additional 2.2.0 checks

- Test Choose from Photos with a RAF file stored in Photos.
- Test Choose from Photos with JPEG/HEIC and confirm warning behavior.
- Test Choose from Files with the original RAF file.
- Export PDF in both Light Mode and Dark Mode and confirm text is visible.
- Export PNG in both Light Mode and Dark Mode and confirm text is visible.
- Test on at least one small iPhone screen and one large iPhone/iPad screen.


## Mac Catalyst checks

- In Xcode, select **My Mac (Mac Catalyst)** and build.
- Test file import on Mac using original RAF/NEF/CR2/CR3/ARW files.
- Test Photos import on Mac if available.
- Test PDF and PNG export on Mac.
- Check that the app window is usable at small and large sizes.
- Confirm App Store Connect Mac availability settings before release.
