package com.asterlink.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings

/** The component state is the persisted preference and the system's actual routing state. */
class LinkOpening(private val context: Context) {
    fun status(): List<Map<String, Any>> = targets.map { target ->
        val state = context.packageManager.getComponentEnabledSetting(component(target))
        mapOf("id" to target.id, "label" to target.label, "sample" to target.sample,
            "enabled" to (state != PackageManager.COMPONENT_ENABLED_STATE_DISABLED &&
                state != PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER &&
                state != PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED))
    }

    fun setEnabled(id: String, enabled: Boolean) {
        val target = targets.firstOrNull { it.id == id } ?: throw IllegalArgumentException("Unknown link target")
        val desired = if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        if (context.packageManager.getComponentEnabledSetting(component(target)) != desired) {
            context.packageManager.setComponentEnabledSetting(component(target), desired, PackageManager.DONT_KILL_APP)
        }
    }

    fun openSettings(activity: android.app.Activity?) {
        val owner = activity ?: context
        fun launch(action: String) {
            owner.startActivity(Intent(action, Uri.parse("package:${context.packageName}")).apply {
                if (activity == null) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try { launch(Settings.ACTION_APP_OPEN_BY_DEFAULT_SETTINGS); return } catch (_: Exception) { }
        }
        launch(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
    }

    private fun component(target: Target) = ComponentName(context.packageName, target.alias)

    data class Target(val id: String, val label: String, val sample: String, val entry: String) {
        val alias get() = "com.asterlink.app.link.$entry"
    }

    companion object {
        val targets = listOf(
            Target("quark", "夸克网盘", "pan.quark.cn/s/…", "QuarkEntry"),
            Target("uc", "UC 网盘", "drive.uc.cn/s/…", "UcEntry"),
            Target("baidu", "百度网盘", "pan.baidu.com/s/…", "BaiduEntry"),
            Target("aliyun", "阿里云盘", "alipan.com/s/…", "AliyunEntry"),
            Target("tianyi", "天翼云盘", "cloud.189.cn/t/…", "TianyiEntry"),
            Target("c139", "中国移动云盘", "yun.139.com/shareweb/…", "C139Entry"),
            Target("wopan", "中国联通云盘", "pan.wo.cn/s/…", "WopanEntry"),
            Target("guangya", "光鸭云盘", "guangyapan.com/s/…", "GuangyaEntry"),
            Target("xunlei", "迅雷网盘", "pan.xunlei.com/s/…", "XunleiEntry"),
            Target("pan115", "115 网盘", "115.com/s/…", "Pan115Entry"),
            Target("pan123", "123 云盘", "123pan.com/s/…", "Pan123Entry"),
            Target("lanzou", "蓝奏云", "lanzou*.com/…", "LanzouEntry"),
            Target("ctfile", "城通网盘", "ctfile.com/f/…", "CtfileEntry"),
            Target("feijipan", "小飞机网盘", "feijipan.com/s/…", "FeijipanEntry"),
            Target("pikpak", "PikPak", "mypikpak.com/s/…", "PikpakEntry"),
            Target("share", "分享菜单解析", "其他应用 → 分享 → 文析助手解析", "ShareEntry"),
            Target("selection", "选中文字解析", "长按选中文字 → 用文析助手解析", "SelectionEntry"),
            Target("protocol", "网页唤起", "网页上的“用文析助手打开”按钮", "ProtocolEntry"),
        )

        fun isShareEntry(className: String?): Boolean =
            targets.any { it.id !in setOf("share", "selection", "protocol") && it.alias == className }
    }
}
