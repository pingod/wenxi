package com.asterlink.app

import android.util.AtomicFile
import android.util.Base64
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/** Private-file replacement for the old Keystore-wrapped download database key. */
internal class EngineKeyStore(
    private val root: File,
    private val unwrapLegacy: (String) -> String?,
) {
    private val directory = File(root, "engine-key-private-v1")
    private val identity = AtomicFile(File(directory, "identity.bin"))
    private val records = listOf("primary.bin", "copy.bin").map { AtomicFile(File(directory, it)) }
    private val legacy = AtomicFile(File(root, "engine.key"))

    fun load(knownKey: String): String = synchronized(lock) {
        val supplied = decode(knownKey)
        val expected = if (exists(identity)) read(identity, 32).also {
            if (it.size != 32) throw Unavailable()
        } else null
        val saved = records.map { record ->
            try { read(record, 32).takeIf { it.size == 32 } } catch (_: IOException) { null }
        }
        val key = if (expected != null) {
            // A state-password recovery can supply the same engine key. The
            // committed identity prevents using the unrelated key older Flutter
            // versions generated but never passed through to the native engine.
            val persisted = saved.firstOrNull { it != null && matches(it, expected) }
            val recovered = supplied?.takeIf { matches(it, expected) }
            val value = persisted ?: recovered ?: throw Unavailable()
            if (persisted == null) {
                persist(value)
            } else {
                // Keep using the authenticated copy if a redundant repair hits
                // an IO failure. Do not overwrite the remaining good record.
                for (index in records.indices) {
                    if (saved[index]?.contentEquals(value) == true) continue
                    try { write(records[index], value) } catch (_: IOException) { }
                }
            }
            value
        } else {
            val pair = saved[0]?.takeIf { saved[1]?.contentEquals(it) == true }
            val value = when {
                // Finish a stopped migration without another Keystore access.
                pair != null -> pair
                exists(legacy) -> {
                    val wrapped = read(legacy, 8192).toString(Charsets.UTF_8)
                    decode(unwrapLegacy(wrapped)) ?: throw Unavailable()
                }
                File(root, "gopeed.db").exists() -> throw Unavailable()
                else -> supplied ?: error("下载组件密钥格式错误")
            }
            persist(value)
            value
        }
        Base64.encodeToString(key, Base64.NO_WRAP)
    }

    private fun persist(key: ByteArray) {
        check(directory.mkdirs() || directory.isDirectory)
        for (record in records) write(record, key)
        for (record in records) check(read(record, 32).contentEquals(key)) { "下载组件密钥保存校验失败" }
        // Publish only after both final files have been reopened and checked.
        write(identity, digest(key))
        check(read(identity, 32).contentEquals(digest(key))) { "下载组件密钥保存校验失败" }
    }

    private fun write(file: AtomicFile, bytes: ByteArray) {
        val stream = file.startWrite()
        try {
            stream.write(bytes)
            stream.fd.sync()
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }
    }

    private fun read(file: AtomicFile, maximum: Int): ByteArray = file.openRead().use { input ->
        val bytes = ByteArray(maximum + 1)
        var length = 0
        while (length < bytes.size) {
            val count = input.read(bytes, length, bytes.size - length)
            if (count < 0) break
            length += count
        }
        if (length > maximum) throw IOException("下载组件密钥记录损坏")
        bytes.copyOf(length)
    }

    private fun exists(file: AtomicFile) = file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()
    private fun digest(key: ByteArray) = MessageDigest.getInstance("SHA-256").digest(key)
    private fun matches(key: ByteArray, expected: ByteArray) = MessageDigest.isEqual(digest(key), expected)
    private fun decode(value: String?): ByteArray? = runCatching {
        value?.takeIf { it.length <= 128 }?.let { Base64.decode(it, Base64.DEFAULT) }?.takeIf { it.size == 32 }
    }.getOrNull()

    class Unavailable : IllegalStateException("下载组件原密钥无法读取，原下载记录已保留")

    companion object {
        private val lock = Any()

        fun directory(noBackupRoot: File, generation: String): File {
            require(generation.isEmpty() || generation.matches(Regex("[a-f0-9]{32}"))) { "下载组件存储配置无效" }
            return File(noBackupRoot, if (generation.isEmpty()) "gopeed" else "gopeed-$generation")
        }
    }
}
