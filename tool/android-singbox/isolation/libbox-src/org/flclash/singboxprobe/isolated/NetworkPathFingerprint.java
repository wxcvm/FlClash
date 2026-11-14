package org.flclash.singboxprobe.isolated;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Canonical path identity: DNS order is meaningful, address/route order is not. */
final class NetworkPathFingerprint {
    private NetworkPathFingerprint() {}

    static String of(String name, int index, List<?> dns, List<?> addresses,
                     List<?> routes, boolean privateDnsActive, String privateDnsName,
                     String domains, int mtu) {
        StringBuilder out = new StringBuilder();
        append(out, name);
        append(out, Integer.toString(index));
        appendList(out, dns, false);
        appendList(out, addresses, true);
        appendList(out, routes, true);
        append(out, Boolean.toString(privateDnsActive));
        append(out, privateDnsName);
        append(out, domains);
        append(out, Integer.toString(mtu));
        return out.toString();
    }

    private static void appendList(StringBuilder out, List<?> values, boolean sorted) {
        List<String> items = new ArrayList<>(values.size());
        for (Object value : values) items.add(String.valueOf(value));
        if (sorted) Collections.sort(items);
        append(out, Integer.toString(items.size()));
        for (String item : items) append(out, item);
    }

    private static void append(StringBuilder out, String value) {
        if (value == null) out.append("-1:");
        else out.append(value.length()).append(':').append(value);
    }
}
