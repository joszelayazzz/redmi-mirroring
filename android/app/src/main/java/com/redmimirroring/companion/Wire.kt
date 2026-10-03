package com.redmimirroring.companion

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException

object Wire {
    const val MAX_FRAME = 16 * 1024 * 1024
    const val JSON = 1
    const val CONFIG = 2
    const val VIDEO = 3
    const val AUDIO = 4
    const val FILE = 5
    data class Frame(val type: Int, val bytes: ByteArray)
    fun read(input: DataInputStream, maxFrame: Int = MAX_FRAME): Frame {
        val count = input.readInt()
        if (count < 1 || count > maxFrame) throw IOException("Invalid frame size")
        val type = input.readUnsignedByte()
        val bytes = ByteArray(count - 1)
        input.readFully(bytes)
        return Frame(type, bytes)
    }
    fun write(output: DataOutputStream, frame: Frame) {
        require(frame.bytes.size < MAX_FRAME)
        output.writeInt(frame.bytes.size + 1)
        output.writeByte(frame.type)
        output.write(frame.bytes)
        output.flush()
    }
    fun timed(presentationTimeUs: Long, bytes: ByteArray): ByteArray = java.nio.ByteBuffer.allocate(bytes.size + 8).putLong(presentationTimeUs).put(bytes).array()
    fun safeFilename(raw: String): String {
        val name = raw.replace('\\', '/').substringAfterLast('/').replace(Regex("[^\\p{L}\\p{N} ._()-]"), "_").take(120)
        return if (name.isBlank() || name == "." || name == "..") "Transferred file" else name
    }
}
