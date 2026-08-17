# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Writing bits, most significant first.
##
## FLAC and ALAC both pack fields that are not whole bytes and both fill from
## the top of a byte down, so one writer serves them. It grows a string rather
## than seeking, because neither format revisits a field once written — a
## length known only later is patched into the finished bytes.

import contracts

type BitWriter* = object
  ## Bits accumulate into `data`; `bits` counts how many of the last byte are
  ## already used, so 0 means the next write starts a byte.
  data*: string
  bits*: int

proc put*(writer: var BitWriter; value: uint64; count: int) {.contractual.} =
  ## The low `count` bits of `value`, most significant first. Bits above
  ## `count` are ignored, so a caller need not mask first.
  ##
  ## A `count` of 0 writes nothing, which is what lets a field of computed width
  ## be written without a branch at the call site.
  require:
    count in 0 .. 64
  body:
    for index in countdown(count - 1, 0):
      if writer.bits == 0: writer.data.add '\0'
      let bit = uint8((value shr index) and 1)
      writer.data[^1] = char(uint8(writer.data[^1]) or (bit shl (7 - writer.bits)))
      writer.bits = (writer.bits + 1) and 7

proc putSigned*(writer: var BitWriter; value: int64; count: int)
    {.contractual.} =
  ## Two's complement in `count` bits: the sign bit lands at the top of the
  ## field, and the higher bits of a negative value are cut.
  ##
  ## The 64-bit case is separate because `1'u64 shl 64` is not defined in Nim —
  ## on x86 it yields 1, which would make the mask zero and write the field as
  ## zeros. At 64 bits every bit is wanted, so there is nothing to mask.
  require:
    count in 0 .. 64
  body:
    if count == 64:
      writer.put(cast[uint64](value), 64)
    else:
      writer.put(cast[uint64](value) and ((1'u64 shl count) - 1), count)

proc alignByte*(writer: var BitWriter) =
  ## Zero-fill to the next byte boundary, so the next write starts a byte.
  ## Already aligned means nothing is written.
  while writer.bits != 0: writer.put(0, 1)

func bitLength*(writer: BitWriter): int =
  ## Bits written so far, so one encoding can be priced against another before
  ## either is kept. Not `data.len * 8`: the last byte is usually partial.
  if writer.bits == 0: writer.data.len * 8
  else: (writer.data.len - 1) * 8 + writer.bits



