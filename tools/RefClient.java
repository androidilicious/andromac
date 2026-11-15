// Line-for-line Java port of android/.../Proto.kt (same hand-written HKDF, same framing),
// run against tools/ref_server.py to prove the two sides interoperate. Usage: RefClient PORT KEY_HEX
import java.io.*; import java.net.Socket; import java.nio.ByteBuffer; import java.security.SecureRandom; import java.util.Arrays;
import javax.crypto.Cipher; import javax.crypto.Mac; import javax.crypto.spec.GCMParameterSpec; import javax.crypto.spec.SecretKeySpec;

public class RefClient {
    static byte[] hkdf(byte[] ikm, byte[] salt, String info) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(salt, "HmacSHA256"));
        byte[] prk = mac.doFinal(ikm);
        mac.init(new SecretKeySpec(prk, "HmacSHA256"));
        mac.update(info.getBytes("UTF-8")); mac.update((byte) 1);
        return mac.doFinal();
    }
    static byte[] nonce(long c) { return ByteBuffer.allocate(12).putInt(0).putLong(c).array(); }
    static DataInputStream in; static DataOutputStream out; static SecretKeySpec sendKey, recvKey; static long sendCtr, recvCtr;

    static void send(int type, byte[] payload) throws Exception {
        byte[] plain = new byte[1 + payload.length]; plain[0] = (byte) type;
        System.arraycopy(payload, 0, plain, 1, payload.length);
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, sendKey, new GCMParameterSpec(128, nonce(sendCtr++)));
        byte[] ct = c.doFinal(plain);
        out.writeInt(ct.length); out.write(ct); out.flush();
    }
    static byte[] recv() throws Exception {
        byte[] ct = new byte[in.readInt()]; in.readFully(ct);
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, recvKey, new GCMParameterSpec(128, nonce(recvCtr++)));
        return c.doFinal(ct);
    }
    public static void main(String[] a) throws Exception {
        byte[] psk = new byte[32];
        for (int i = 0; i < 32; i++) psk[i] = (byte) Integer.parseInt(a[1].substring(2 * i, 2 * i + 2), 16);
        Socket s = new Socket("127.0.0.1", Integer.parseInt(a[0]));
        in = new DataInputStream(s.getInputStream()); out = new DataOutputStream(s.getOutputStream());
        byte[] cs = new byte[16]; new SecureRandom().nextBytes(cs);
        out.write("AMAC".getBytes()); out.writeByte(1); out.write(cs); out.flush();
        byte[] magic = new byte[4]; in.readFully(magic);
        if (!Arrays.equals(magic, "AMAC".getBytes()) || in.readUnsignedByte() != 1) throw new RuntimeException("bad hello");
        byte[] ss = new byte[16]; in.readFully(ss);
        byte[] salt = new byte[32]; System.arraycopy(cs, 0, salt, 0, 16); System.arraycopy(ss, 0, salt, 16, 16);
        sendKey = new SecretKeySpec(hkdf(psk, salt, "andromac v1 c2s"), "AES");
        recvKey = new SecretKeySpec(hkdf(psk, salt, "andromac v1 s2c"), "AES");
        send(1, "{\"t\":\"hello\"}".getBytes());
        byte[] big = new byte[256 * 300]; for (int i = 0; i < big.length; i++) big[i] = (byte) (i % 256);
        send(4, big);
        byte[] p = recv();
        if (p[0] != 1 || !new String(p, 1, p.length - 1).equals("{\"t\":\"hello\",\"name\":\"ref\"}")) throw new RuntimeException("json mismatch");
        p = recv();
        if (p[0] != 5 || !new String(p, 9, p.length - 9).equals("thumb")) throw new RuntimeException("thumb mismatch");
        send(1, "{\"t\":\"ok\"}".getBytes());
        System.out.println("CLIENT OK");
    }
}
