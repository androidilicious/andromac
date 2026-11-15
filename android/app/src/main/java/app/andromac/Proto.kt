package app.andromac

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Frame types. See PROTOCOL.md. */
object T {
    const val JSON = 1
    const val SCREEN = 2
    const val CAMERA = 3
    const val FILE = 4
    const val THUMB = 5
    const val ICON = 6
}

/** HKDF-SHA256 (RFC 5869) with a single 32-byte output block. Matches CryptoKit's HKDF. */
fun hkdf(ikm: ByteArray, salt: ByteArray, info: String): ByteArray {
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(salt, "HmacSHA256"))
    val prk = mac.doFinal(ikm)
    mac.init(SecretKeySpec(prk, "HmacSHA256"))
    mac.update(info.toByteArray(Charsets.UTF_8))
    mac.update(1.toByte())
    return mac.doFinal()
}

/**
 * Encrypted, framed channel over a TCP socket. The phone is always the client.
 *
 * Handshake (plaintext): "AMAC" + version(1) + 16-byte salt, in each direction.
 * Session keys: HKDF(pairing key, clientSalt + serverSalt, direction label).
 * Frames: u32 length, then AES-256-GCM(type byte + payload) with a counter nonce.
 */
class SecureChannel(private val sock: Socket, psk: ByteArray) {
    private val inp = DataInputStream(BufferedInputStream(sock.getInputStream(), 1 shl 16))
    private val out = DataOutputStream(BufferedOutputStream(sock.getOutputStream(), 1 shl 16))
    private val sendKey: SecretKeySpec
    private val recvKey: SecretKeySpec
    private var sendCtr = 0L
    private var recvCtr = 0L
    private val sendLock = Any()

    init {
        val clientSalt = ByteArray(16).also { SecureRandom().nextBytes(it) }
        out.write(MAGIC); out.writeByte(VERSION); out.write(clientSalt); out.flush()
        val magic = ByteArray(4); inp.readFully(magic)
        require(magic.contentEquals(MAGIC)) { "bad magic" }
        require(inp.readUnsignedByte() == VERSION) { "version mismatch" }
        val serverSalt = ByteArray(16); inp.readFully(serverSalt)
        val salt = clientSalt + serverSalt
        sendKey = SecretKeySpec(hkdf(psk, salt, "andromac v1 c2s"), "AES")
        recvKey = SecretKeySpec(hkdf(psk, salt, "andromac v1 s2c"), "AES")
    }

    private fun nonce(ctr: Long): ByteArray = ByteBuffer.allocate(12).putInt(0).putLong(ctr).array()

    fun send(type: Int, vararg parts: ByteArray) = synchronized(sendLock) {
        val plain = ByteArray(1 + parts.sumOf { it.size })
        plain[0] = type.toByte()
        var off = 1
        for (p in parts) { System.arraycopy(p, 0, plain, off, p.size); off += p.size }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, sendKey, GCMParameterSpec(128, nonce(sendCtr++)))
        val ct = c.doFinal(plain)
        out.writeInt(ct.size); out.write(ct); out.flush()
    }

    /** Blocks for the next frame. Returns (type, payload). Throws on any tampering or disconnect. */
    fun recv(): Pair<Int, ByteArray> {
        val n = inp.readInt()
        require(n in 17..MAX_FRAME) { "bad frame length $n" }
        val ct = ByteArray(n); inp.readFully(ct)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, recvKey, GCMParameterSpec(128, nonce(recvCtr++)))
        val p = c.doFinal(ct)
        return (p[0].toInt() and 0xff) to p.copyOfRange(1, p.size)
    }

    fun close() { try { sock.close() } catch (_: Exception) {} }

    companion object {
        val MAGIC = "AMAC".toByteArray(Charsets.US_ASCII)
        const val VERSION = 1
        const val MAX_FRAME = 8 * 1024 * 1024
    }
}
