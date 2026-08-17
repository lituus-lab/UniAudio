# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## What a file says about itself.
##
## Four unrelated tagging schemes grew up around these formats, and a caller
## should not have to know which one a given file uses: ID3 in MPEG audio,
## Vorbis comments in Ogg and FLAC, iTunes-style atoms in MP4. They are read
## into one shape.
##
## Dates are kept exactly as written. Tags carry `2019`, `2019-04-01` and
## worse, and parsing them here would mean deciding which half of a bare
## `01/02/2019` is the month — a question the file does not answer.
##
## A name this module does not recognise is not dropped: it goes to `other`
## under the name the file used, so nothing is silently lost.
##
## A container too broken to walk raises rather than returning nothing: an
## empty result would say the file has no tags, which is a different claim.

import contracts
import ./ogg
import ./isobmff

const
  MaxTagBytes = 64 * 1024 * 1024
    ## An embedded cover runs to megabytes; past this the length field is
    ## malformed rather than generous.
  Id3v1Bytes = 128

type
  Tags* = object
    ## An empty string or a zero means the file said nothing, not that it said
    ## something empty.
    title*, artist*, album*, albumArtist*, composer*: string
    genre*, comment*, date*: string
    trackNumber*, trackTotal*: int
    discNumber*, discTotal*: int
    other*: seq[tuple[key, value: string]]

func isEmpty*(tags: Tags): bool =
  ## Whether the file said nothing at all. A file with no tags reads as an empty
  ## `Tags` rather than raising, so this is how a caller tells "untagged" from
  ## "tagged with blank fields" — every string empty, every number zero and
  ## `other` empty.
  tags.title.len == 0 and tags.artist.len == 0 and tags.album.len == 0 and
    tags.albumArtist.len == 0 and tags.composer.len == 0 and
    tags.genre.len == 0 and tags.comment.len == 0 and tags.date.len == 0 and
    tags.trackNumber == 0 and tags.discNumber == 0 and tags.other.len == 0

func trimmed(text: string): string =
  ## Drop the padding and terminators these formats leave behind.
  var first = 0
  var last = text.len - 1
  while first <= last and text[first] in {'\0', ' '}: inc first
  while last >= first and text[last] in {'\0', ' '}: dec last
  if last < first: "" else: text[first .. last]

func appendUtf8(target: var string; codepoint: int) =
  ## Append one code point as UTF-8, in one to four bytes. Tags arrive in three
  ## encodings — Latin-1, UTF-16 and UTF-8 — and every reader here converts into
  ## this one shape, so a caller never has to know which the file used.
  if codepoint < 0x80:
    target.add char(codepoint)
  elif codepoint < 0x800:
    target.add char(0xC0 or (codepoint shr 6))
    target.add char(0x80 or (codepoint and 0x3F))
  elif codepoint < 0x10000:
    target.add char(0xE0 or (codepoint shr 12))
    target.add char(0x80 or ((codepoint shr 6) and 0x3F))
    target.add char(0x80 or (codepoint and 0x3F))
  else:
    target.add char(0xF0 or (codepoint shr 18))
    target.add char(0x80 or ((codepoint shr 12) and 0x3F))
    target.add char(0x80 or ((codepoint shr 6) and 0x3F))
    target.add char(0x80 or (codepoint and 0x3F))

func latin1ToUtf8(text: string): string =
  ## Latin-1 to UTF-8. Every byte is a valid Latin-1 code point, so this is the
  ## one reading that cannot fail — which is why ID3v1, whose encoding is not
  ## recorded anywhere, is read as Latin-1.
  for character in text:
    appendUtf8(result, int(uint8(character)))

func utf16ToUtf8(text: string; bigEndian: bool): string =
  ## Surrogate pairs are joined; a lone surrogate passes through as itself
  ## rather than being dropped, so a damaged tag still reads as something.
  var index = 0
  while index + 1 < text.len:
    let first = int(uint8(text[index]))
    let second = int(uint8(text[index + 1]))
    var unit = if bigEndian: (first shl 8) or second
               else: (second shl 8) or first
    index += 2
    if unit >= 0xD800 and unit <= 0xDBFF and index + 1 < text.len:
      let third = int(uint8(text[index]))
      let fourth = int(uint8(text[index + 1]))
      let next = if bigEndian: (third shl 8) or fourth
                 else: (fourth shl 8) or third
      if next >= 0xDC00 and next <= 0xDFFF:
        unit = 0x10000 + ((unit - 0xD800) shl 10) + (next - 0xDC00)
        index += 2
    appendUtf8(result, unit)

func decodeId3Text(encoding: int; body: string): string =
  ## ID3 states the encoding in one byte ahead of the text.
  case encoding
  of 0: latin1ToUtf8(body)
  of 1:
    # UTF-16 with a byte-order mark, which is the only thing saying which way
    # round it is.
    if body.len >= 2 and uint8(body[0]) == 0xFF and uint8(body[1]) == 0xFE:
      utf16ToUtf8(body[2 .. ^1], bigEndian = false)
    elif body.len >= 2 and uint8(body[0]) == 0xFE and uint8(body[1]) == 0xFF:
      utf16ToUtf8(body[2 .. ^1], bigEndian = true)
    else:
      utf16ToUtf8(body, bigEndian = false)
  of 2: utf16ToUtf8(body, bigEndian = true)
  of 3: body
  else: latin1ToUtf8(body)

func splitCount(text: string): tuple[number, total: int] =
  ## `3/12` and a bare `3` are both common.
  var number = 0
  var total = 0
  var seenSlash = false
  var digits = false
  for character in text:
    if character in '0' .. '9':
      digits = true
      if seenSlash: total = total * 10 + (ord(character) - ord('0'))
      else: number = number * 10 + (ord(character) - ord('0'))
    elif character == '/':
      if seenSlash: break
      seenSlash = true
    elif digits and not seenSlash:
      break
  (number, total)

func upper(text: string): string =
  ## ASCII upper-casing, for comparing a Vorbis comment's field name. Deliberately
  ## not `strutils.toUpperAscii`'s locale-free equivalent for the whole string:
  ## only the names matter, they are ASCII by specification, and mapping bytes
  ## above 127 would corrupt a UTF-8 name that happens to be compared.
  for character in text:
    result.add(if character in 'a' .. 'z': char(ord(character) - 32)
               else: character)

func assign(tags: var Tags; key, value: string) =
  ## Route one name-value pair into its field. The names are the union of what
  ## the four schemes use; callers fold case before calling.
  if value.len == 0: return
  case key
  of "TITLE", "TIT2", "TT2": tags.title = value
  of "ARTIST", "TPE1", "TP1": tags.artist = value
  of "ALBUM", "TALB", "TAL": tags.album = value
  of "ALBUMARTIST", "ALBUM ARTIST", "TPE2", "TP2": tags.albumArtist = value
  of "COMPOSER", "TCOM", "TCM": tags.composer = value
  of "GENRE", "TCON", "TCO": tags.genre = value
  of "COMMENT", "DESCRIPTION", "COMM", "COM": tags.comment = value
  of "DATE", "TDRC", "TYER", "TYE", "YEAR": tags.date = value
  of "TRACKNUMBER", "TRACK", "TRCK", "TRK":
    let (number, total) = splitCount(value)
    tags.trackNumber = number
    if total != 0: tags.trackTotal = total
  of "TRACKTOTAL", "TOTALTRACKS": tags.trackTotal = splitCount(value).number
  of "DISCNUMBER", "DISC", "TPOS", "TPA":
    let (number, total) = splitCount(value)
    tags.discNumber = number
    if total != 0: tags.discTotal = total
  of "DISCTOTAL", "TOTALDISCS": tags.discTotal = splitCount(value).number
  else: tags.other.add (key, value)

# --- ID3 --------------------------------------------------------------------

func syncsafe(data: string; offset: int): int =
  ## Four bytes with the top bit of each cleared, so a size can never be
  ## mistaken for a frame sync.
  for index in 0 .. 3:
    result = (result shl 7) or (int(uint8(data[offset + index])) and 0x7F)

func beU32(data: string; offset: int): int =
  ## Big-endian, as ID3v2 writes a frame size. Distinct from the syncsafe reader
  ## above it: ID3v2.3 frame sizes are plain big-endian, while the tag's own size
  ## is syncsafe, and reading one as the other is off by up to a factor of 16.
  for index in 0 .. 3:
    result = (result shl 8) or int(uint8(data[offset + index]))

proc readId3v2*(data: string): Tags =
  ## The tag at the front of an MPEG audio file. Versions 2.2 through 2.4
  ## differ in how a frame states its own length, and in little else that
  ## matters here.
  if data.len < 10 or data[0 .. 2] != "ID3": return
  let major = int(uint8(data[3]))
  if major notin 2 .. 4: return
  let size = syncsafe(data, 6)
  if size <= 0 or size > MaxTagBytes: return
  var at = 10
  let limit = min(data.len, 10 + size)

  # An extended header sits between the header and the first frame.
  if (uint8(data[5]) and 0x40'u8) != 0 and at + 4 <= limit:
    let extended = if major == 4: syncsafe(data, at) else: beU32(data, at) + 4
    if extended > 0 and at + extended <= limit: at += extended

  let idLen = if major == 2: 3 else: 4
  let headerLen = if major == 2: 6 else: 10
  while at + headerLen <= limit:
    let id = data[at ..< at + idLen]
    if id[0] == '\0': break # padding, which runs to the end
    var frameLen: int
    if major == 2:
      frameLen = (int(uint8(data[at + 3])) shl 16) or
                 (int(uint8(data[at + 4])) shl 8) or int(uint8(data[at + 5]))
    elif major == 3:
      frameLen = beU32(data, at + 4)
    else:
      frameLen = syncsafe(data, at + 4)
    if frameLen <= 0 or at + headerLen + frameLen > limit: break
    let body = data[at + headerLen ..< at + headerLen + frameLen]
    at += headerLen + frameLen
    if body.len < 2: continue
    let encoding = int(uint8(body[0]))

    if id == "TXXX" or id == "TXX":
      # A user-defined text frame: its own name, terminated, then the value.
      # Writers reach for it whenever no standard frame fits, so the name it
      # carries is what decides where the value belongs.
      let rest = decodeId3Text(encoding, body[1 .. ^1])
      let split = rest.find('\0')
      if split > 0:
        assign(result, upper(trimmed(rest[0 ..< split])),
          trimmed(rest[split + 1 .. ^1]))
    elif id == "COMM" or id == "COM":
      # An encoding byte, a three-letter language, then a description and the
      # comment itself, each terminated.
      if body.len < 5: continue
      let rest = decodeId3Text(encoding, body[4 .. ^1])
      let split = rest.find('\0')
      let text = if split >= 0: rest[split + 1 .. ^1] else: rest
      assign(result, "COMM", trimmed(text))
    elif id[0] == 'T':
      # A version 2.4 text frame may hold several values separated by a zero;
      # the first is the one these fields describe.
      var text = decodeId3Text(encoding, body[1 .. ^1])
      let stop = text.find('\0')
      if stop >= 0: text = text[0 ..< stop]
      assign(result, id, trimmed(text))

proc readId3v1*(data: string): Tags =
  ## The 128 bytes some files still carry at the end. Its fields are fixed
  ## width and space padded, and its text declares no encoding at all, so
  ## Latin-1 is the only reading that cannot fail.
  if data.len < Id3v1Bytes: return
  let at = data.len - Id3v1Bytes
  if data[at ..< at + 3] != "TAG": return
  assign(result, "TITLE", trimmed(latin1ToUtf8(data[at + 3 ..< at + 33])))
  assign(result, "ARTIST", trimmed(latin1ToUtf8(data[at + 33 ..< at + 63])))
  assign(result, "ALBUM", trimmed(latin1ToUtf8(data[at + 63 ..< at + 93])))
  assign(result, "DATE", trimmed(latin1ToUtf8(data[at + 93 ..< at + 97])))
  let comment = data[at + 97 ..< at + 127]
  # Version 1.1 took the last two bytes of the comment for a track number.
  if comment[28] == '\0' and comment[29] != '\0':
    result.trackNumber = int(uint8(comment[29]))
    assign(result, "COMMENT", trimmed(latin1ToUtf8(comment[0 ..< 28])))
  else:
    assign(result, "COMMENT", trimmed(latin1ToUtf8(comment)))
  # The genre is an index into a list this module does not carry, so it is
  # reported as the number rather than as a guessed name.
  let genre = int(uint8(data[at + 127]))
  if genre != 255: result.other.add ("GENRECODE", $genre)

# --- Vorbis comments --------------------------------------------------------

func leU32(data: string; offset: int): int =
  ## Little-endian, as a Vorbis comment writes its lengths — the opposite of
  ## ID3v2, in the same file family.
  for index in countdown(3, 0):
    result = (result shl 8) or int(uint8(data[offset + index]))

proc readVorbisComment*(field: string): Tags =
  ## A vendor string, a count, then that many `KEY=value` pairs in UTF-8. Keys
  ## are case insensitive, so they are folded before matching.
  if field.len < 8: return
  let vendorLen = leU32(field, 0)
  if vendorLen < 0 or 4 + vendorLen + 4 > field.len: return
  var at = 4 + vendorLen
  let count = leU32(field, at)
  at += 4
  if count < 0 or count > field.len div 4: return
  for _ in 0 ..< count:
    if at + 4 > field.len: break
    let length = leU32(field, at)
    at += 4
    if length < 0 or at + length > field.len: break
    let entry = field[at ..< at + length]
    at += length
    let split = entry.find('=')
    if split <= 0: continue
    assign(result, upper(entry[0 ..< split]), entry[split + 1 .. ^1])

proc readOggTags*(data: string): Tags =
  ## The comment header is the second packet of a Vorbis stream.
  let packets = oggPackets(data)
  if packets.len < 2: return
  let comment = packets[1].data
  if comment.len < 8 or uint8(comment[0]) != 3 or comment[1 .. 6] != "vorbis":
    return
  readVorbisComment(comment[7 .. ^1])

proc readFlacTags*(data: string): Tags =
  ## FLAC carries a Vorbis comment as one of its metadata blocks, the fourth
  ## kind. The blocks run from just past the signature to the one that says it
  ## is the last.
  if data.len < 8 or data[0 .. 3] != "fLaC": return
  var at = 4
  while at + 4 <= data.len:
    let header = uint8(data[at])
    let kind = int(header and 0x7F'u8)
    let length = (int(uint8(data[at + 1])) shl 16) or
                 (int(uint8(data[at + 2])) shl 8) or int(uint8(data[at + 3]))
    at += 4
    if length < 0 or at + length > data.len: break
    if kind == 4: return readVorbisComment(data[at ..< at + length])
    at += length
    if (header and 0x80'u8) != 0: break

# --- MP4 --------------------------------------------------------------------

const Mp4Names = {
  "\xA9nam": "TITLE", "\xA9ART": "ARTIST", "\xA9alb": "ALBUM",
  "aART": "ALBUMARTIST", "\xA9wrt": "COMPOSER", "\xA9gen": "GENRE",
  "\xA9day": "DATE", "\xA9cmt": "COMMENT", "\xA9too": "ENCODER"}

proc readMp4Tags*(data: string): Tags =
  ## iTunes-style atoms under `moov/udta/meta/ilst`. `meta` states a version
  ## and flags ahead of its children, unlike every other box here.
  let udta = findBox(data, 0, data.len, ["moov", "udta"])
  if udta.body < 0: return
  let meta = findBox(data, udta.body, udta.bodyEnd, ["meta"])
  if meta.body < 0 or meta.body + 4 > meta.bodyEnd: return
  let ilst = findBox(data, meta.body + 4, meta.bodyEnd, ["ilst"])
  if ilst.body < 0: return

  for name, body, bodyEnd in boxes(data, ilst.body, ilst.bodyEnd):
    for kind, valueAt, valueEnd in boxes(data, body, bodyEnd):
      if kind != "data" or valueAt + 8 > valueEnd: continue
      let payload = data[valueAt + 8 ..< valueEnd]
      if name == "trkn" or name == "disk":
        # Two 16-bit numbers inside a fixed eight-byte record.
        if payload.len >= 6:
          let number = (int(uint8(payload[2])) shl 8) or int(uint8(payload[3]))
          let total = (int(uint8(payload[4])) shl 8) or int(uint8(payload[5]))
          if name == "trkn":
            result.trackNumber = number
            result.trackTotal = total
          else:
            result.discNumber = number
            result.discTotal = total
        continue
      var mapped = ""
      for (atom, field) in Mp4Names:
        if name == atom: mapped = field
      assign(result, (if mapped.len > 0: mapped else: name), trimmed(payload))

# --- one entry point --------------------------------------------------------

proc readTags*(data: string): Tags =
  ## Whatever the file carries, in whichever scheme it uses.
  ##
  ## An MPEG file may hold both an ID3v2 tag and an ID3v1 one. The newer is
  ## read first and the older only fills what it left empty, which is all the
  ## older tag can be trusted for.
  if data.len < 8: return
  if data[0 .. 2] == "ID3" or
      (uint8(data[0]) == 0xFF and (uint8(data[1]) and 0xE0'u8) == 0xE0'u8):
    result = readId3v2(data)
    let older = readId3v1(data)
    if result.title.len == 0: result.title = older.title
    if result.artist.len == 0: result.artist = older.artist
    if result.album.len == 0: result.album = older.album
    if result.date.len == 0: result.date = older.date
    if result.comment.len == 0: result.comment = older.comment
    if result.trackNumber == 0: result.trackNumber = older.trackNumber
    for (key, value) in older.other:
      var known = false
      for (existing, _) in result.other:
        if existing == key: known = true
      if not known: result.other.add (key, value)
  elif data[0 .. 3] == "fLaC":
    result = readFlacTags(data)
  elif data[0 .. 3] == "OggS":
    result = readOggTags(data)
  elif data[4 .. 7] == "ftyp":
    result = readMp4Tags(data)

proc readTagsFile*(path: string): Tags {.contractual.} =
  ## `readTags` over a file: whichever scheme it carries, read into one shape.
  ## A file with no tags yields an empty `Tags`, not an error.
  require:
    path.len > 0
  body:
    readTags(readFile(path))


