package com.follow.clash;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/** Small DNS wire-format check for the fixed diagnostic A question. */
final class ProbeDnsMessage {
    static byte[] query(int id) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        DataOutputStream out = new DataOutputStream(bytes);
        out.writeShort(id);
        out.writeShort(0x0100); // recursion desired
        out.writeShort(1);
        out.writeShort(0);
        out.writeShort(0);
        out.writeShort(0);
        for (String label : new String[] {"example", "com"}) {
            byte[] value = label.getBytes(StandardCharsets.US_ASCII);
            out.writeByte(value.length);
            out.write(value);
        }
        out.writeByte(0);
        out.writeShort(1); // A
        out.writeShort(1); // IN
        return bytes.toByteArray();
    }

    static void verify(byte[] bytes, int length, int id) throws IOException {
        if (length < 12 || length > bytes.length || u16(bytes, 0) != id) {
            throw new IOException("Invalid DNS response header or transaction ID");
        }
        int flags = u16(bytes, 2);
        if ((flags & 0x8000) == 0 || (flags & 0x0200) != 0 || (flags & 0x000f) != 0
                || u16(bytes, 4) != 1) {
            throw new IOException("DNS response was truncated or returned an error");
        }
        int answers = u16(bytes, 6);
        byte[] expected = query(id);
        int pos = expected.length;
        if (length < pos) throw new IOException("Truncated DNS question");
        for (int i = 12; i < pos; i++) {
            if (bytes[i] != expected[i]) throw new IOException("DNS question mismatch");
        }
        boolean found = false;
        for (int i = 0; i < answers; i++) {
            pos = skipName(bytes, length, pos);
            if (pos + 10 > length) throw new IOException("Truncated DNS record");
            int type = u16(bytes, pos);
            int klass = u16(bytes, pos + 2);
            int size = u16(bytes, pos + 8);
            pos += 10;
            if (pos + size > length) throw new IOException("Truncated DNS record data");
            if (type == 1 && klass == 1 && size == 4) found = true;
            pos += size;
        }
        if (!found) throw new IOException("DNS response contains no IPv4 answer");
    }

    private static int skipName(byte[] bytes, int length, int pos) throws IOException {
        while (pos < length) {
            int n = bytes[pos++] & 255;
            if (n == 0) return pos;
            if ((n & 0xc0) == 0xc0) {
                if (pos >= length || (((n & 63) << 8) | (bytes[pos] & 255)) >= length) {
                    throw new IOException("Invalid DNS name pointer");
                }
                return pos + 1;
            }
            if (n > 63 || pos + n > length) throw new IOException("Invalid DNS name");
            pos += n;
        }
        throw new IOException("Truncated DNS name");
    }

    private static int u16(byte[] bytes, int offset) {
        return ((bytes[offset] & 255) << 8) | (bytes[offset + 1] & 255);
    }
}
