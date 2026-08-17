# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The bit writer FLAC and ALAC share.
##
## Bit order is the whole of it: a writer that fills a byte from the bottom up,
## or loses the top bit of a signed field, produces a stream every reference
## decoder rejects — and produces it silently. So each check reads the bits back
## out as text and compares them with what the format asks for.
import std/[unittest, sequtils, strutils]
import UniAudio/bitio

proc bitString(writer: BitWriter): string =
  ## Every written byte as '0'/'1', most significant bit first.
  for character in writer.data:
    for index in countdown(7, 0):
      result.add(if ((uint8(character) shr index) and 1'u8) == 1'u8: '1'
                 else: '0')

suite "unsigned fields":
  test "bits fill a byte from the top down":
    var writer = BitWriter()
    writer.put(1, 1)
    check writer.data.len == 1
    check uint8(writer.data[0]) == 0b1000_0000'u8

  test "a field spanning a byte boundary keeps its order":
    var writer = BitWriter()
    writer.put(0b101, 3)
    writer.put(0b1100_1010, 8)
    check writer.bitString()[0 ..< 11] == "10111001010"

  test "bits above the field width are ignored":
    # The caller does not have to mask: 0xFF in three bits is three ones.
    var writer = BitWriter()
    writer.put(0xFF'u64, 3)
    check writer.bitLength == 3
    check writer.bitString()[0 ..< 3] == "111"

  test "a zero-width field writes nothing":
    var writer = BitWriter()
    writer.put(0xFFFF_FFFF'u64, 0)
    check writer.bitLength == 0
    check writer.data.len == 0

  test "the full 64-bit width survives":
    var writer = BitWriter()
    writer.put(0xFFFF_FFFF_FFFF_FFFF'u64, 64)
    check writer.bitLength == 64
    check writer.bitString().allIt(it == '1')

suite "signed fields":
  test "a negative value fills its width with the sign":
    # -1 is all ones at every width. The 64-bit case is the one that used to
    # write zeros: `1'u64 shl 64` is undefined in Nim and yields 1 on x86, so
    # the mask came out zero and took the value with it.
    for width in [1, 2, 8, 17, 32, 63, 64]:
      var writer = BitWriter()
      writer.putSigned(-1'i64, width)
      check writer.bitLength == width
      check writer.bitString()[0 ..< width].allIt(it == '1')

  test "a positive value keeps a clear sign bit":
    var writer = BitWriter()
    writer.putSigned(3'i64, 8)
    check writer.bitString()[0 ..< 8] == "00000011"

  test "the higher bits of a negative value are cut, not carried":
    # -2 in four bits is 1110; the sign extension above bit 3 must not appear.
    var writer = BitWriter()
    writer.putSigned(-2'i64, 4)
    check writer.bitLength == 4
    check writer.bitString()[0 ..< 4] == "1110"

  test "the widest negative value round-trips":
    var writer = BitWriter()
    writer.putSigned(low(int64), 64)
    check writer.bitString() == "1" & repeat('0', 63)

suite "alignment and measurement":
  test "aligning pads with zeros to the byte":
    var writer = BitWriter()
    writer.put(0b111, 3)
    writer.alignByte()
    check writer.bitLength == 8
    check writer.bitString() == "11100000"

  test "aligning an aligned writer writes nothing":
    var writer = BitWriter()
    writer.put(0xAB'u64, 8)
    let before = writer.bitLength
    writer.alignByte()
    check writer.bitLength == before

  test "bitLength counts bits, not the bytes holding them":
    var writer = BitWriter()
    for _ in 0 ..< 9: writer.put(1, 1)
    check writer.data.len == 2
    check writer.bitLength == 9

  test "a width outside 0 to 64 is refused":
    # A precondition, so it holds in the debug build only. Every caller in this
    # library passes a constant well inside the range.
    when not defined(release):
      var writer = BitWriter()
      expect Exception:
        writer.put(0, 65)
      expect Exception:
        writer.putSigned(0, -1)
