import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/cloud_command_history.dart';
import 'app_context_menu.dart';
import 'app_popup_menu.dart';
import 'common.dart';

Future<CloudCommandHistoryEntry?> showCloudCommandHistory(
  BuildContext context,
  AppServices services,
) => showModalBottomSheet<CloudCommandHistoryEntry>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SizedBox(
      key: const Key('command-history-sheet'),
      height: MediaQuery.sizeOf(context).height * .7,
      child: AnimatedBuilder(
        animation: services.store,
        builder: (context, _) {
          final history = services.commandHistory.all;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '口令历史',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (history.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          if (await confirm(
                                context,
                                '清空口令历史',
                                '将删除本机保存的全部口令记录。',
                              ) &&
                              context.mounted) {
                            await busy(context, services.commandHistory.clear);
                          }
                        },
                        child: const Text('清空'),
                      ),
                    IconButton(
                      tooltip: '关闭历史',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(CupertinoIcons.xmark, size: 18),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: history.isEmpty
                    ? const Center(
                        child: EmptyPanel(
                          '暂无口令历史',
                          '成功解析的口令会保存在这里',
                          icon: CupertinoIcons.clock,
                        ),
                      )
                    : ListView.builder(
                        itemCount: history.length,
                        itemBuilder: (context, index) {
                          final item = history[index];
                          Future<void> copy({bool link = false}) async {
                            try {
                              await services.copyText(
                                link ? item.link.textForCopy : item.text,
                              );
                              if (context.mounted) {
                                message(context, link ? '分享链接已复制' : '口令已复制');
                              }
                            } catch (e) {
                              if (context.mounted) {
                                message(context, errorText(e));
                              }
                            }
                          }

                          Future<void> remove() async {
                            await busy(
                              context,
                              () => services.commandHistory.remove(item.id),
                            );
                          }

                          return AppContextMenu<String>(
                            key: ValueKey('command-history-${item.id}'),
                            identity: (item.id, item.createdAt),
                            actions: () =>
                                services.commandHistory.all.any(
                                  (entry) => entry.id == item.id,
                                )
                                ? const [
                                    AppMenuAction(
                                      value: 'use',
                                      label: '使用此口令',
                                      icon: CupertinoIcons.arrow_up_doc,
                                    ),
                                    AppMenuAction(
                                      value: 'copy',
                                      label: '复制口令',
                                      icon: CupertinoIcons.doc_on_doc,
                                    ),
                                    AppMenuAction(
                                      value: 'copy-link',
                                      label: '复制分享链接',
                                      icon: CupertinoIcons.link,
                                    ),
                                    AppMenuAction(
                                      value: 'remove',
                                      label: '删除这条口令',
                                      icon: CupertinoIcons.trash,
                                      destructive: true,
                                    ),
                                  ]
                                : [],
                            onSelected: (action) async {
                              switch (action) {
                                case 'use':
                                  Navigator.pop(context, item);
                                case 'copy':
                                  await copy();
                                case 'copy-link':
                                  await copy(link: true);
                                case 'remove':
                                  await remove();
                              }
                            },
                            child: ListTile(
                              contentPadding: const EdgeInsets.fromLTRB(
                                16,
                                4,
                                8,
                                4,
                              ),
                              leading: PlatformMark(
                                platform: item.platform,
                                size: 30,
                              ),
                              title: Text(
                                item.title.ifEmpty(
                                  '${item.platform.shortName}口令',
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.text,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${item.platform.shortName} · ${formatDate(item.createdAt)}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: secondary(context),
                                    ),
                                  ),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    key: ValueKey(
                                      'command-history-copy-${item.id}',
                                    ),
                                    tooltip: '复制口令',
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      CupertinoIcons.doc_on_doc,
                                      size: 19,
                                    ),
                                    onPressed: copy,
                                  ),
                                  IconButton(
                                    tooltip: '删除这条口令',
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      CupertinoIcons.xmark,
                                      size: 16,
                                    ),
                                    onPressed: remove,
                                  ),
                                ],
                              ),
                              onTap: () => Navigator.pop(context, item),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    ),
  ),
);
