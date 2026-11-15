# AndroMac wire protocol (v1)

One TCP connection on the local network. The Mac listens and advertises itself over Bonjour as
`AndroMac-<id>._andromac._tcp`. The phone connects.

## Pairing

The Mac shows a QR code containing:

    andromac://pair?h=<mac ip>&p=<port>&k=<32-byte key, base64url>&id=<mac id>&n=<mac name>

The key never travels over the network. Anyone who sees the QR code can pair, so treat it like a password.
"Reset pairing" on the Mac creates a new key.

## Handshake

Each side sends, in plaintext: `"AMAC"`, one version byte (`1`), 16 random salt bytes. Phone first.

    salt     = phoneSalt + macSalt
    key c2s  = HKDF-SHA256(pairing key, salt, info "andromac v1 c2s")   phone to Mac
    key s2c  = HKDF-SHA256(pairing key, salt, info "andromac v1 s2c")   Mac to phone

Fresh salts give fresh keys for every connection, so nonces never repeat.

## Frames

    u32 big-endian length | AES-256-GCM ciphertext + 16-byte tag

The nonce is 4 zero bytes plus a 64-bit big-endian counter that starts at 0 and counts frames per direction.
It is not transmitted. A frame that fails to decrypt (wrong key, tampering, replay, reordering) closes the connection.
The Mac only accepts a new connection as "the phone" after its first frame decrypts.

Plaintext is one type byte followed by the payload:

| Type | Meaning | Payload |
|---|---|---|
| 1 | JSON message | UTF-8 JSON object with a `t` field |
| 2 | Screen video | flags(1) + pts in microseconds(8) + H.264 Annex B |
| 3 | Camera video | same as 2 |
| 4 | File chunk | file id(4) + bytes |
| 5 | Photo thumbnail | photo id(8) + JPEG |

Video flags: bit 0 = SPS/PPS, bit 1 = keyframe.

## JSON messages

Phone to Mac: `hello{name}`, `status{accessibility,notifications,mirror,camera}`, `clip{text}`,
`notif{key,app,title,text,reply}`, `notif_gone{key}`, `file_start{id,name,size,photo?}` (`photo` is the photo id when the file answers `photo_get`), `file_end{id,ok}`,
`photos{offset,items[{id,name,ts}],more}`, `contacts{items[{name,phones[]}]}`, `mirror_info{w,h}`, `error{msg}`,
`sms_threads{items[{id,address,name,snippet,ts,out,unread}]}`, `sms{thread,items[{id,body,ts,out}]}` (oldest first),
`sms_changed` (a message arrived or was sent; reload).

Mac to phone: `hello{name}`, `ping`, `clip{text}`, `reply{key,text}`, `dismiss{key}`,
`file_start{id,name,size}`, `file_end{id,ok}`, `photos_get{offset,limit}`, `thumb_get{id}`, `photo_get{id}`,
`contacts_get`, `sms_threads_get`, `sms_get{thread,limit}`, `sms_send{to,text}`, `mirror_start{max,bitrate}`, `mirror_stop`, `keyframe`, `cam_start{front}`, `cam_stop`,
`input{k,...}` where k is `tap{x,y}`, `swipe{x,y,x2,y2,ms}`, `key{key}` (back, home, recents, notifications, del, enter)
or `text{text}`. Coordinates are 0..1 of the screen, origin top-left.

Each side sends one file at a time.
