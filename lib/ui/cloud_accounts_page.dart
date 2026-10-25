import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../data/state_store.dart';
import '../domain/models.dart';
import 'app_popup_menu.dart';
import 'app_context_menu.dart';
import 'account_cookie.dart';
import 'account_info_page.dart';
import 'common.dart';
import 'login_page.dart';
import 'uc_tv_authorization_page.dart';

class CloudAccountsPage extends StatelessWidget {
  const CloudAccountsPage(this.services, {super.key, this.platform});
  final AppServices services;
  final CloudPlatform? platform;

  Future<void> _action(
    BuildContext context,
    CloudAccountProfile account,
    String action,
  ) async {
    switch (action) {
      case 'switch':
        await busy(
          context,
          () => services.switchCloudAccount(account.platform, account.id),
        );
      case 'copyLogin':
        await copyCloudAccountLoginInfo(
          context,
          services.vault,
          account.platform,
          account.id,
        );
      case 'info':
        await openCloudAccountInfo(
          context,
          services.vault,
          account.platform,
          account.id,
        );
      case 'rename':
        final name = await askText(
          context,
          '自定义账号名称',
          initial: account.customName,
          hint: '留空使用网盘昵称',
        );
        if (name != null && context.mounted) {
          await busy(
            context,
            () => services.vault.renameAccount(
              account.platform,
              account.id,
              name,
            ),
          );
        }
      case 'login':
        await openLogin(
          context,
          services,
          account.platform,
          accountId: account.id,
        );
      case 'tv':
        await openUcTvAuthorization(context, services, accountId: account.id);
      case 'remove':
        if (await confirm(
              context,
              '移除账号',
              '移除“${account.name}”及其本地收藏？网盘内的文件不会删除。该账号的下载和播放将无法再刷新链接。',
              action: '移除',
              destructive: true,
            ) &&
            context.mounted) {
          await busy(
            context,
            () => services.removeCloudAccount(account.platform, account.id),
          );
        }
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: platform == null ? '网盘账号管理' : '${platform!.shortName}账号管理',
    child: AnimatedBuilder(
      animation: services.store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '点击账号切换使用，下载、播放和收藏保留各自的账号归属。',
            style: TextStyle(fontSize: 13, color: secondary(context)),
          ),
          const SizedBox(height: 16),
          for (final p in CloudPlatform.values.where(
            (p) => p.requiresAccount && (platform == null || platform == p),
          )) ...[
            Row(
              children: [
                PlatformMark(platform: p, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    p.label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  key: ValueKey('account-add-${p.key}'),
                  onPressed: () =>
                      openLogin(context, services, p, addAccount: true),
                  icon: const Icon(CupertinoIcons.add, size: 16),
                  label: const Text('添加账号'),
                ),
              ],
            ),
            if (services.vault.profiles(p).isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(38, 4, 0, 16),
                child: Text(
                  '还没有保存的账号',
                  style: TextStyle(color: secondary(context), fontSize: 13),
                ),
              ),
            for (final account in services.vault.profiles(p))
              AppContextMenu<String>(
                key: ValueKey('account-context-${account.id}'),
                identity: (p, account.id),
                actions: () =>
                    services.vault.profiles(p).any((a) => a.id == account.id)
                    ? [
                        AppMenuAction(
                          value: 'switch',
                          label: account.active ? '当前使用的账号' : '切换到此账号',
                          icon: CupertinoIcons.person_crop_circle,
                          enabled: !account.active,
                        ),
                        const AppMenuAction(
                          value: 'info',
                          label: '账号配置',
                          icon: CupertinoIcons.slider_horizontal_3,
                        ),
                        AppMenuAction(
                          value: 'copyLogin',
                          label: savedAccountLoginInfo(
                            services.vault,
                            p,
                            account.id,
                          ).copyLabel,
                          icon: CupertinoIcons.doc_on_doc,
                        ),
                        const AppMenuAction(
                          value: 'rename',
                          label: '自定义账号名称',
                          icon: CupertinoIcons.pencil,
                        ),
                        const AppMenuAction(
                          value: 'login',
                          label: '重新登录',
                          icon: CupertinoIcons.arrow_clockwise,
                        ),
                        if (p == CloudPlatform.uc)
                          const AppMenuAction(
                            value: 'tv',
                            label: 'TV 播放授权',
                            icon: CupertinoIcons.tv,
                          ),
                        const AppMenuAction(
                          value: 'remove',
                          label: '移除账号',
                          icon: CupertinoIcons.trash,
                          destructive: true,
                        ),
                      ]
                    : [],
                onSelected: (action) => _action(context, account, action),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: account.active
                        ? themeAccent(context).withValues(alpha: .07)
                        : Theme.of(context).colorScheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: border(context)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ListTile(
                          key: ValueKey('account-${account.id}'),
                          leading: Icon(
                            account.active
                                ? CupertinoIcons.checkmark_circle_fill
                                : CupertinoIcons.person_crop_circle,
                            color: account.active
                                ? themeAccent(context)
                                : secondary(context),
                          ),
                          title: Text(
                            account.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              if (account.customName.isNotEmpty &&
                                  account.nickname.isNotEmpty)
                                '网盘昵称：${account.nickname}',
                              account.active ? '当前使用' : '点击切换到此账号',
                            ].join('\n'),
                          ),
                          onTap: account.active
                              ? null
                              : () async {
                                  await busy(
                                    context,
                                    () => services.switchCloudAccount(
                                      p,
                                      account.id,
                                    ),
                                  );
                                },
                          trailing: AppPopupMenuButton<String>(
                            tooltip: '${account.name}的账号操作',
                            icon: CupertinoIcons.ellipsis,
                            onSelected: (action) =>
                                _action(context, account, action),
                            actions: [
                              const AppMenuAction(
                                value: 'rename',
                                label: '自定义名称',
                                icon: CupertinoIcons.pencil,
                              ),
                              const AppMenuAction(
                                value: 'login',
                                label: '重新登录',
                                icon: CupertinoIcons.arrow_clockwise,
                              ),
                              if (p == CloudPlatform.uc)
                                const AppMenuAction(
                                  value: 'tv',
                                  label: 'TV 播放授权',
                                  icon: CupertinoIcons.tv,
                                ),
                              const AppMenuAction(
                                value: 'remove',
                                label: '移除账号',
                                icon: CupertinoIcons.trash,
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              FilledButton.tonalIcon(
                                key: ValueKey('account-copy-${account.id}'),
                                onPressed: () =>
                                    _action(context, account, 'copyLogin'),
                                icon: const Icon(
                                  CupertinoIcons.doc_on_doc,
                                  size: 16,
                                ),
                                label: Text(
                                  savedAccountLoginInfo(
                                    services.vault,
                                    p,
                                    account.id,
                                  ).copyLabel,
                                ),
                              ),
                              TextButton.icon(
                                key: ValueKey('account-info-${account.id}'),
                                onPressed: () =>
                                    _action(context, account, 'info'),
                                icon: const Icon(
                                  CupertinoIcons.slider_horizontal_3,
                                  size: 16,
                                ),
                                label: const Text('账号配置'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    ),
  );
}
