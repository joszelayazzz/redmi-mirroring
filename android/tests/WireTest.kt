package com.redmimirroring.companion

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.nio.ByteBuffer

fun main() {
    var passed = 0
    fun verify(condition: Boolean) { check(condition); passed++ }
    val encoded = ByteArrayOutputStream()
    Wire.write(DataOutputStream(encoded), Wire.Frame(Wire.JSON, "unicode \uD83D\uDCF1".toByteArray()))
    val decoded = Wire.read(DataInputStream(ByteArrayInputStream(encoded.toByteArray())))
    verify(decoded.type == Wire.JSON && String(decoded.bytes) == "unicode \uD83D\uDCF1")
    verify(encoded.toByteArray()[3].toInt() == decoded.bytes.size + 1)
    for (size in listOf(0, -1, Wire.MAX_FRAME + 1)) {
        val input = ByteBuffer.allocate(4).putInt(size).array()
        verify(runCatching { Wire.read(DataInputStream(ByteArrayInputStream(input))) }.isFailure)
    }
    verify(runCatching { Wire.read(DataInputStream(ByteArrayInputStream(byteArrayOf(0, 0, 0, 3, 1, 2)))) }.isFailure)
    verify(runCatching { Wire.read(DataInputStream(ByteArrayInputStream(ByteBuffer.allocate(4).putInt(4098).array())), 4097) }.isFailure)
    verify(Wire.safeFilename("../../secret.txt") == "secret.txt")
    verify(Wire.safeFilename("..\\..\\secret.txt") == "secret.txt")
    verify(Wire.safeFilename("..") == "Transferred file")
    verify(Wire.safeFilename("a\u0000b.txt") == "a_b.txt")
    verify(Wire.safeFilename("x".repeat(200)).length == 120)
    val timed = Wire.timed(0x0102030405060708, byteArrayOf(9, 10))
    verify(timed.contentEquals(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)))
    println("PASS: $passed framing, truncation, timestamp and path-safety checks")
}
