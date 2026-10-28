# Pinned FFmpeg iOS static libraries

This directory carries the unmodified official FFmpeg 9.0.2 release archive, its detached signature, the official FFmpeg release-signing public key, and FFmpeg's LGPL/GPL license texts. No codec library is patched or bundled separately.

Build the arm64 iOS 17+ device and arm64 iOS 17+ simulator static libraries with:

```sh
python3 scripts/build-ffmpeg-ios.py
```

Run this command from the repository root. The script verifies the archive's pinned SHA-256 and detached RSA OpenPGP signature against the pinned FFmpeg release key before configuring either build. It uses only Xcode SDKs/tools, Python's standard library, and system OpenSSL; it does not download during the build. Build logs and products are under `Vendor/FFmpeg/build/`.

The configure profile is LGPL-only: GPL, version-3-only, and nonfree components are disabled. It enables only the FFmpeg libraries and formats/codecs listed in `build-configuration.txt` written with each successful output. There are no external codec libraries such as libx264 or libvpx. The build does not integrate FFmpeg into CivitViewer or create a framework; a caller must link the required Apple frameworks when assembling a dynamic framework.

License texts: `COPYING.LGPLv2.1` is the license for the configured FFmpeg build; `COPYING.GPLv2` is included as source-distribution context and is not enabled in the build. Review FFmpeg's source-file notices and codec patent obligations separately before distribution. This build artifact is not a patent clearance.

Pinned input SHA-256: `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`.

Pinned official FFmpeg signing-key fingerprint: `FCF986EA15E6E293A5644F10B4322F04D67658D8`.
