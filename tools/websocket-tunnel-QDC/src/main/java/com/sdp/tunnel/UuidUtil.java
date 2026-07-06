//============================================================================================================
//  
//                   Copyright (c) 2023, Qualcomm Innovation Center, Inc. All rights reserved.
//                               SPDX-License-Identifier: BSD-3-Clause
//  
//============================================================================================================ 

package com.sdp.tunnel;

import java.nio.ByteBuffer;
import java.util.UUID;

/**
 * Utility for converting between {@link UUID} and 16-byte arrays.
 * Compatible with the Python tunnel's UUID framing protocol.
 */
public final class UuidUtil {

    private UuidUtil() {}

    /** Generate a random UUID as a 16-byte array. */
    public static byte[] randomBytes() {
        return toBytes(UUID.randomUUID());
    }

    /** Convert a UUID to a 16-byte big-endian array. */
    public static byte[] toBytes(UUID uuid) {
        ByteBuffer bb = ByteBuffer.allocate(16);
        bb.putLong(uuid.getMostSignificantBits());
        bb.putLong(uuid.getLeastSignificantBits());
        return bb.array();
    }

    /** Convert 16 bytes (starting at offset 0) to a UUID. */
    public static UUID fromBytes(byte[] data) {
        return fromBytes(data, 0);
    }

    /** Convert 16 bytes starting at the given offset to a UUID. */
    public static UUID fromBytes(byte[] data, int offset) {
        ByteBuffer bb = ByteBuffer.wrap(data, offset, 16);
        return new UUID(bb.getLong(), bb.getLong());
    }

    /** Return the hex string of 16 bytes (same format as Python uuid.hex). */
    public static String toHex(byte[] uuidBytes) {
        StringBuilder sb = new StringBuilder(32);
        for (byte b : uuidBytes) {
            sb.append(String.format("%02x", b & 0xFF));
        }
        return sb.toString();
    }

    /** Short hex prefix for logging (first 8 hex chars = 4 bytes). */
    public static String shortHex(byte[] uuidBytes) {
        return toHex(uuidBytes).substring(0, 8);
    }

    /** Parse a 32-char hex string into 16 bytes. */
    public static byte[] fromHex(String hex) {
        if (hex.length() != 32) {
            throw new IllegalArgumentException("Expected 32 hex chars, got " + hex.length());
        }
        byte[] out = new byte[16];
        for (int i = 0; i < 16; i++) {
            out[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
        }
        return out;
    }
}