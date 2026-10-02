#!/usr/bin/env python3
"""Offline generator for the PDF-import test fixtures.

Run once from the repo root; the produced .pdf files are committed so the
Dart tests never need Python at runtime.

    pip install pillow img2pdf pypdf pikepdf
    python test/fixtures/pdf/generate_fixtures.py

Every fixture is the same 2-page image PDF - one red page, one blue page -
under a different set of encodings:

  plain_jpeg.pdf     - JPEG (DCTDecode) passthrough, no encryption
  enc_rc4_128.pdf    - RC4-128, user password "user123"
  enc_aes128.pdf     - AES-128,  user password "user123"
  enc_aes256_r6.pdf  - AES-256 (R6), user password "user123"
  owner_only.pdf     - RC4-128, owner password "owner", EMPTY user password
                       (must open silently without prompting)
"""
import io
import os

import img2pdf
import pikepdf
import pypdf
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
USER_PW = "user123"


def _page_jpeg(color, size=(8, 8)):
    img = Image.new("RGB", size, color)
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    return buf.getvalue()


def _base_pdf_bytes():
    # img2pdf embeds each JPEG as a DCTDecode image XObject without re-encoding.
    pages = [_page_jpeg((255, 0, 0)), _page_jpeg((0, 0, 255))]
    return img2pdf.convert([io.BytesIO(p) for p in pages])


def _write(name, data):
    path = os.path.join(HERE, name)
    with open(path, "wb") as f:
        f.write(data)
    print("wrote", name, len(data), "bytes")


def _pypdf_encrypt(base, user_pw, owner_pw=None, algorithm="RC4-128"):
    w = pypdf.PdfWriter()
    w.append(io.BytesIO(base))
    if owner_pw is None:
        w.encrypt(user_password=user_pw, algorithm=algorithm)
    else:
        w.encrypt(user_password=user_pw, owner_password=owner_pw,
                  algorithm=algorithm)
    buf = io.BytesIO()
    w.write(buf)
    return buf.getvalue()


def main():
    base = _base_pdf_bytes()
    _write("plain_jpeg.pdf", base)
    _write("enc_rc4_128.pdf", _pypdf_encrypt(base, USER_PW))
    _write("enc_aes128.pdf", _pypdf_encrypt(base, USER_PW, algorithm="AES-128"))
    # Empty user password: the parser must open this without ever prompting.
    _write("owner_only.pdf", _pypdf_encrypt(base, "", owner_pw="owner"))

    r6 = os.path.join(HERE, "enc_aes256_r6.pdf")
    with pikepdf.open(io.BytesIO(base)) as pdf:
        pdf.save(r6, encryption=pikepdf.Encryption(
            owner="owner", user=USER_PW, R=6))
    print("wrote", "enc_aes256_r6.pdf", os.path.getsize(r6), "bytes")


if __name__ == "__main__":
    main()
