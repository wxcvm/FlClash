package org.flclash.singboxprobe;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;

public final class ProbeDnsMessageTest {
    private static final int ID = 0x1234;

    private static byte[] answer() throws Exception {
        byte[] query = ProbeDnsMessage.query(ID);
        query[2] = (byte) 0x81;
        query[3] = (byte) 0x80;
        query[7] = 1;
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        buffer.write(query);
        DataOutputStream out = new DataOutputStream(buffer);
        out.writeShort(0xc00c);
        out.writeShort(1);
        out.writeShort(1);
        out.writeInt(60);
        out.writeShort(4);
        out.write(new byte[] {1, 2, 3, 4});
        return buffer.toByteArray();
    }

    private static void rejects(byte[] bytes, int size) throws Exception {
        try {
            ProbeDnsMessage.verify(bytes, size, ID);
        } catch (IOException expected) {
            return;
        }
        throw new AssertionError("Invalid DNS response accepted");
    }

    public static void main(String[] args) throws Exception {
        byte[] good = answer();
        ProbeDnsMessage.verify(good, good.length, ID);
        byte[] wrongId = good.clone(); wrongId[1] ^= 1; rejects(wrongId, wrongId.length);
        byte[] rcode = good.clone(); rcode[3] |= 3; rejects(rcode, rcode.length);
        byte[] truncated = good.clone(); truncated[2] |= 2; rejects(truncated, truncated.length);
        byte[] wrongQuestion = good.clone(); wrongQuestion[13] = 'x'; rejects(wrongQuestion, wrongQuestion.length);
        byte[] noAnswer = good.clone(); noAnswer[7] = 0; rejects(noAnswer, noAnswer.length);
        byte[] wrongType = good.clone(); wrongType[ProbeDnsMessage.query(ID).length + 3] = 28;
        rejects(wrongType, wrongType.length);
        byte[] badPointer = good.clone(); badPointer[ProbeDnsMessage.query(ID).length + 1] = (byte) 255;
        rejects(badPointer, badPointer.length);
        for (int i = 0; i < good.length; i++) rejects(good, i);
        System.out.println("PASS: DNS wire response and malformed/truncated cases");
    }
}
