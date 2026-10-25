package com.asterlink.app

import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.PatternMatcher
import android.provider.Settings
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.w3c.dom.Element

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class LinkOpeningTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val ns = "http://schemas.android.com/apk/res/android"
    private fun Element.attr(name: String) = getAttributeNS(ns, name)
    private fun Element.children(tag: String): List<Element> = (0 until childNodes.length)
        .mapNotNull { childNodes.item(it) as? Element }.filter { it.tagName == tag }
    private fun aliases(): Map<String, Element> {
        val root = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(File("src/main/AndroidManifest.xml")).documentElement
        return root.children("application").single().children("activity-alias").associateBy { it.attr("name") }
    }
    private fun filters(entry: Element): List<IntentFilter> = entry.children("intent-filter").map { source ->
        IntentFilter().apply {
            source.children("action").forEach { addAction(it.attr("name")) }
            source.children("category").forEach { addCategory(it.attr("name")) }
            source.children("data").forEach { data ->
                data.attr("scheme").takeIf(String::isNotEmpty)?.let(::addDataScheme)
                data.attr("mimeType").takeIf(String::isNotEmpty)?.let(::addDataType)
                data.attr("host").takeIf(String::isNotEmpty)?.let { addDataAuthority(it, null) }
                for ((key, kind) in listOf("path" to PatternMatcher.PATTERN_LITERAL,
                    "pathPrefix" to PatternMatcher.PATTERN_PREFIX, "pathPattern" to PatternMatcher.PATTERN_SIMPLE_GLOB)) {
                    data.attr(key).takeIf(String::isNotEmpty)?.let { addDataPath(it, kind) }
                }
            }
        }
    }
    private fun matches(entry: Element, url: String, action: String = Intent.ACTION_VIEW, mime: String? = null): Boolean {
        val uri = Uri.parse(url)
        return filters(entry).any { it.match(action, mime, uri.scheme, uri, setOf(Intent.CATEGORY_DEFAULT), "links-test") >= 0 }
    }

    @Test fun declaredSharePathsOpenButUnrelatedWebsitesAndLoginPagesDoNot() {
        val aliases = aliases()
        val cases = mapOf(
            "QuarkEntry" to "https://pan.quark.cn/s/abc123?pwd=1234",
            "UcEntry" to "https://drive.uc.cn/s/abc123",
            "BaiduEntry" to "https://pan.baidu.com/share/init?surl=abc123",
            "AliyunEntry" to "https://www.alipan.com/s/abc123",
            "TianyiEntry" to "https://cloud.189.cn/web/share?code=abc123",
            "C139Entry" to "https://yun.139.com/shareweb/#/w/i/abc123",
            "WopanEntry" to "https://pan.wo.cn/s/abc123",
            "GuangyaEntry" to "https://www.guangyapan.com/s/abc123",
            "XunleiEntry" to "https://pan.xunlei.com/s/abc123",
            "Pan115Entry" to "https://115cdn.com/s/abc123",
            "Pan123Entry" to "https://www.123865.com/s/abc123",
            "LanzouEntry" to "https://wws.lanzout.com/iabc123",
            "CtfileEntry" to "https://url95.ctfile.com/f/123-456",
            "FeijipanEntry" to "https://www.feijipan.com/#/s/abc123",
            "PikpakEntry" to "https://mypikpak.com/s/abc123",
        )
        for ((name, url) in cases) {
            val entry = aliases.getValue("com.asterlink.app.link.$name")
            assertTrue("Missing $url", matches(entry, url))
            assertTrue("Missing HTTP fallback for $name", matches(entry, url.replace("https:", "http:")))
            assertFalse("Unrelated website captured by $name", matches(entry, "https://example.test/s/abc123"))
            assertTrue(entry.children("intent-filter").all { it.attr("autoVerify") != "true" })
        }
        assertFalse(matches(aliases.getValue("com.asterlink.app.link.QuarkEntry"), "https://pan.quark.cn/login"))
        assertFalse(matches(aliases.getValue("com.asterlink.app.link.QuarkEntry"), "https://pan.quark.cn.evil.test/s/abc123"))
        assertFalse(matches(aliases.getValue("com.asterlink.app.link.Pan115Entry"), "https://115.com/login"))
    }

    @Test fun everySettingOwnsOneEnabledAliasAndOnlyExpectedActionsAreExposed() {
        val aliases = aliases()
        assertEquals(LinkOpening.targets.size, LinkOpening.targets.map { it.alias }.distinct().size)
        for (target in LinkOpening.targets) {
            val entry = aliases.getValue(target.alias)
            assertEquals("true", entry.attr("enabled"))
            assertEquals("true", entry.attr("exported"))
            assertEquals(".MainActivity", entry.attr("targetActivity"))
        }
        assertTrue(matches(aliases.getValue("com.asterlink.app.link.ProtocolEntry"), "wenxi://resolve?url=x"))
        assertTrue(matches(aliases.getValue("com.asterlink.app.link.ProtocolEntry"), "wenxi://download?url=x"))
        assertFalse(matches(aliases.getValue("com.asterlink.app.link.ProtocolEntry"), "wenxi://delete?url=x"))
        assertTrue(matches(aliases.getValue("com.asterlink.app.link.ShareEntry"), "", Intent.ACTION_SEND, "text/plain"))
        assertTrue(matches(aliases.getValue("com.asterlink.app.link.SelectionEntry"), "", Intent.ACTION_PROCESS_TEXT, "text/plain"))
    }

    @Test fun changingOneCloudPersistsAcrossManagerInstancesAndLeavesOthersEnabled() {
        val first = LinkOpening(context)
        assertTrue(first.status().all { it["enabled"] == true })
        first.setEnabled("quark", false)
        val next = LinkOpening(context)
        assertEquals(false, next.status().single { it["id"] == "quark" }["enabled"])
        assertTrue(next.status().filter { it["id"] != "quark" }.all { it["enabled"] == true })
        next.setEnabled("quark", true)
        assertTrue(first.status().all { it["enabled"] == true })
    }

    @Test(expected = IllegalArgumentException::class) fun unknownComponentCannotBeChanged() {
        LinkOpening(context).setEnabled("MainActivity", false)
    }

    @Test fun olderAndroidOpensTheAppDetailsPageForManualAssociation() {
        LinkOpening(context).openSettings(null)
        val intent = shadowOf(context as Application).nextStartedActivity
        assertEquals(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, intent.action)
        assertEquals("package:${context.packageName}", intent.dataString)
        assertTrue(intent.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
    }
}
