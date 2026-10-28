#!/usr/bin/env python3
"""Build the pinned, minimal LGPL FFmpeg static libraries for two iOS arm64 SDKs."""
from __future__ import annotations

import argparse
import base64
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Vendor" / "FFmpeg"
ARCHIVE = VENDOR / "ffmpeg-9.0.2.tar.xz"
SIGNATURE = VENDOR / "ffmpeg-9.0.2.tar.xz.asc"
PUBLIC_KEY = VENDOR / "ffmpeg-devel.asc"
EXPECTED_SHA256 = "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
EXPECTED_FINGERPRINT = "FCF986EA15E6E293A5644F10B4322F04D67658D8"
JOBS = 4


def run(args: list[str], *, cwd: Path | None = None, log=None, env=None) -> None:
    print("+ " + " ".join(str(a) for a in args), flush=True)
    subprocess.run(args, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)


def armor_packets(path: Path):
    lines = path.read_text(encoding="ascii").splitlines()
    encoded = "".join(line for line in lines if line and not line.startswith("-----") and not line.startswith("="))
    blob = base64.b64decode(encoded, validate=True)
    offset = 0
    while offset < len(blob):
        header = blob[offset]
        offset += 1
        if header & 0x40:
            tag = header & 0x3F
            first = blob[offset]
            offset += 1
            if first < 192:
                length = first
            elif first < 224:
                length = ((first - 192) << 8) + blob[offset] + 192
                offset += 1
            elif first == 255:
                length = int.from_bytes(blob[offset:offset + 4], "big")
                offset += 4
            else:
                raise ValueError("OpenPGP partial packet lengths are unsupported")
        else:
            tag = (header >> 2) & 0x0F
            length_type = header & 0x03
            if length_type == 0:
                length = blob[offset]
                offset += 1
            elif length_type == 1:
                length = int.from_bytes(blob[offset:offset + 2], "big")
                offset += 2
            elif length_type == 2:
                length = int.from_bytes(blob[offset:offset + 4], "big")
                offset += 4
            else:
                length = len(blob) - offset
        packet = blob[offset:offset + length]
        if len(packet) != length:
            raise ValueError("Truncated OpenPGP packet")
        offset += length
        yield tag, packet


def read_mpi(data: bytes, offset: int) -> tuple[int, int]:
    bits = int.from_bytes(data[offset:offset + 2], "big")
    length = (bits + 7) // 8
    return int.from_bytes(data[offset + 2:offset + 2 + length], "big"), offset + 2 + length


def der_length(length: int) -> bytes:
    if length < 128:
        return bytes([length])
    raw = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(raw)]) + raw


def der_tlv(tag: int, body: bytes) -> bytes:
    return bytes([tag]) + der_length(len(body)) + body


def der_integer(value: int) -> bytes:
    raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
    if raw[0] & 0x80:
        raw = b"\0" + raw
    return der_tlv(2, raw)


def verify_release_signature() -> None:
    """Verify v4 RSA OpenPGP detached signature using system OpenSSL, no GPG install."""
    public_packets = list(armor_packets(PUBLIC_KEY))
    key = next(packet for tag, packet in public_packets if tag == 6)
    if key[0] != 4 or key[5] not in (1, 2, 3):
        raise ValueError("Expected an OpenPGP v4 RSA primary key")
    fingerprint = hashlib.sha1(b"\x99" + len(key).to_bytes(2, "big") + key).hexdigest().upper()
    if fingerprint != EXPECTED_FINGERPRINT:
        raise ValueError(f"FFmpeg key fingerprint mismatch: {fingerprint}")
    modulus, offset = read_mpi(key, 6)
    exponent, _ = read_mpi(key, offset)

    signature = next(packet for tag, packet in armor_packets(SIGNATURE) if tag == 2)
    if signature[0] != 4 or signature[2] not in (1, 2, 3):
        raise ValueError("Expected a v4 RSA detached signature")
    hash_id = signature[3]
    hash_names = {8: "sha256", 9: "sha384", 10: "sha512", 11: "sha224"}
    hash_name = hash_names.get(hash_id)
    if not hash_name:
        raise ValueError(f"Unsupported OpenPGP hash algorithm id {hash_id}")
    hashed_length = int.from_bytes(signature[4:6], "big")
    signed_prefix = signature[:6 + hashed_length]
    offset = 6 + hashed_length
    unhashed_length = int.from_bytes(signature[offset:offset + 2], "big")
    unhashed = signature[offset + 2:offset + 2 + unhashed_length]
    offset += 2 + unhashed_length

    issuer = None
    sub_offset = 0
    while sub_offset < len(unhashed):
        first = unhashed[sub_offset]
        sub_offset += 1
        if first < 192:
            sub_length = first
        elif first < 255:
            sub_length = ((first - 192) << 8) + unhashed[sub_offset] + 192
            sub_offset += 1
        else:
            sub_length = int.from_bytes(unhashed[sub_offset:sub_offset + 4], "big")
            sub_offset += 4
        if sub_length < 1:
            raise ValueError("Invalid OpenPGP signature subpacket")
        sub_type = unhashed[sub_offset] & 0x7F
        sub_body = unhashed[sub_offset + 1:sub_offset + sub_length]
        sub_offset += sub_length
        if sub_type == 16:
            issuer = sub_body.hex().upper()
    if issuer != fingerprint[-16:]:
        raise ValueError(f"OpenPGP issuer key id mismatch: {issuer}")

    expected_hash_prefix = signature[offset:offset + 2]
    signature_value, end = read_mpi(signature, offset + 2)
    if end != len(signature):
        raise ValueError("Trailing bytes in OpenPGP signature packet")
    hash_input = ARCHIVE.read_bytes() + signed_prefix + b"\x04\xff" + len(signed_prefix).to_bytes(4, "big")
    if hashlib.new(hash_name, hash_input).digest()[:2] != expected_hash_prefix:
        raise ValueError("OpenPGP signature digest prefix mismatch")

    rsa_body = der_integer(modulus) + der_integer(exponent)
    rsa_der = der_tlv(0x30, rsa_body)
    raw_signature = signature_value.to_bytes((modulus.bit_length() + 7) // 8, "big")
    with tempfile.TemporaryDirectory(prefix="ffmpeg-pgp-") as temporary:
        work = Path(temporary)
        key_der, key_pem = work / "rsa.der", work / "rsa.pem"
        signed_data, sig_data = work / "signed.bin", work / "signature.bin"
        key_der.write_bytes(rsa_der)
        signed_data.write_bytes(hash_input)
        sig_data.write_bytes(raw_signature)
        subprocess.run(["openssl", "rsa", "-RSAPublicKey_in", "-inform", "DER", "-in", str(key_der), "-pubout", "-out", str(key_pem)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["openssl", "dgst", f"-{hash_name}", "-verify", str(key_pem), "-signature", str(sig_data), str(signed_data)], check=True)
    print(f"OpenPGP signature: VERIFIED ({fingerprint})")


def tool(sdk: str, name: str) -> str:
    return subprocess.check_output(["xcrun", "--sdk", sdk, "--find", name], text=True).strip()


def build_one(platform: str, sdk_name: str) -> None:
    sdk_path = Path(subprocess.check_output(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True).strip())
    output = VENDOR / "build" / platform
    work = VENDOR / "build" / "work" / platform
    log_path = VENDOR / "build" / "logs" / f"{platform}.log"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True, exist_ok=True)
    with tarfile.open(ARCHIVE, "r:xz") as archive:
        archive.extractall(work, filter="data")
    source = work / "ffmpeg-9.0.2"
    if output.exists():
        shutil.rmtree(output)
    prefix = output.resolve()
    cc = tool(sdk_name, "clang")
    ar = tool(sdk_name, "ar")
    ranlib = tool(sdk_name, "ranlib")
    nm = tool(sdk_name, "nm")
    deployment = "-miphoneos-version-min=17.0" if sdk_name == "iphoneos" else "-mios-simulator-version-min=17.0"
    extra_cflags = f"-arch arm64 -isysroot {sdk_path} {deployment} -fPIC"
    extra_ldflags = f"-arch arm64 -isysroot {sdk_path} {deployment}"
    options = [
        "--prefix=" + str(prefix), "--target-os=darwin", "--arch=arm64",
        "--enable-cross-compile", "--enable-pic", "--enable-static", "--disable-shared",
        "--disable-everything", "--disable-gpl", "--disable-nonfree", "--disable-version3",
        "--disable-network", "--disable-programs", "--disable-doc", "--disable-devices",
        "--disable-filters", "--disable-avdevice", "--disable-avfilter",
        "--disable-autodetect", "--disable-debug", "--disable-iconv", "--disable-zlib",
        "--disable-bzlib", "--disable-lzma", "--disable-sdl2", "--enable-pthreads",
        "--enable-videotoolbox", "--enable-avformat", "--enable-avcodec", "--enable-avutil",
        "--enable-swscale", "--enable-swresample",
        "--enable-demuxer=mov,matroska,avi", "--enable-muxer=mp4", "--enable-protocol=file",
        "--enable-decoder=vp8,vp9,h264,hevc,mpeg4,mjpeg,aac,opus,vorbis,mp3,flac,pcm_s16le",
        "--enable-parser=vp8,vp9,h264,hevc,mpeg4video,mjpeg,aac,opus,vorbis,mpegaudio,flac",
        "--enable-encoder=h264_videotoolbox,aac",
        "--enable-bsf=aac_adtstoasc,extract_extradata,h264_mp4toannexb,hevc_mp4toannexb",
        "--cc=" + cc, "--ar=" + ar, "--ranlib=" + ranlib, "--nm=" + nm,
        "--sysroot=" + str(sdk_path), "--extra-cflags=" + extra_cflags,
        "--extra-ldflags=" + extra_ldflags,
    ]
    VENDOR.joinpath("build").mkdir(parents=True, exist_ok=True)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log:
        run([str(source / "configure"), *options], cwd=source, log=log)
        config = (source / "config_components.h").read_text(encoding="utf-8")
        required = ["CONFIG_H264_VIDEOTOOLBOX_ENCODER 1", "CONFIG_AAC_ENCODER 1", "CONFIG_VP9_DECODER 1"]
        missing = [item for item in required if item not in config]
        if missing:
            raise RuntimeError(f"Required FFmpeg components not configured: {missing}")
        run(["make", f"-j{JOBS}"], cwd=source, log=log)
        run(["make", "install"], cwd=source, log=log)
        (output / "build-configuration.txt").write_text("\n".join(options) + "\n", encoding="utf-8")
        (output / "sdk.txt").write_text(f"SDK={sdk_name}\nSDKROOT={sdk_path}\nDeploymentTarget=iOS 17.0\nArchitecture=arm64\n", encoding="utf-8")
    shutil.rmtree(work)
    print(f"Built {platform}: {output}")
    for lib in sorted((output / "lib").glob("*.a")):
        print(f"  {lib} sha256={hashlib.sha256(lib.read_bytes()).hexdigest()}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("ios-arm64", "ios-simulator-arm64"), action="append",
                        help="build only the selected target; repeat to build both (default)")
    args = parser.parse_args()
    if not ARCHIVE.is_file() or not SIGNATURE.is_file() or not PUBLIC_KEY.is_file():
        raise FileNotFoundError("Pinned source archive, detached signature, or official public key is missing")
    actual_sha = hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()
    print(f"FFmpeg 9.0.2 archive SHA-256: {actual_sha}")
    if actual_sha != EXPECTED_SHA256:
        raise ValueError(f"FFmpeg source SHA-256 mismatch: expected {EXPECTED_SHA256}, got {actual_sha}")
    verify_release_signature()
    selected = args.platform or ["ios-arm64", "ios-simulator-arm64"]
    for platform in selected:
        sdk = "iphoneos" if platform == "ios-arm64" else "iphonesimulator"
        build_one(platform, sdk)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"BUILD FAILED: {type(error).__name__}: {error}", file=sys.stderr)
        raise
