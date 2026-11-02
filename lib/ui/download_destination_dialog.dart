import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

enum DownloadDestinationChoice { newTasks, unfinished }

Future<DownloadDestinationChoice?> chooseDownloadDestinationScope(
  BuildContext context, {
  required String? destination,
  required int unfinished,
  bool directDownloads = false,
}) => showDialog<DownloadDestinationChoice>(
  context: context,
  builder: (context) => SimpleDialog(
    title: const Text('更改下载目录'),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: Text(
          destination ?? '系统下载目录',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 24),
        leading: const Icon(CupertinoIcons.add_circled),
        title: const Text('仅新任务使用'),
        subtitle: const Text('已有任务继续保存到原目录'),
        onTap: () => Navigator.pop(context, DownloadDestinationChoice.newTasks),
      ),
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 24),
        leading: const Icon(CupertinoIcons.folder_badge_plus),
        title: const Text('同步未完成任务'),
        subtitle: Text(
          directDownloads ? '尚未创建目标文件的任务改用新目录' : '同时更改 $unfinished 个未完成任务的保存目录',
        ),
        onTap: () =>
            Navigator.pop(context, DownloadDestinationChoice.unfinished),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
        child: Text(
          directDownloads
              ? '已开始写入的文件继续保存在原目录。同步时会暂停未完成任务并保留断点，请在传输管理中继续。'
              : '同步时会暂停未完成任务并保留断点，请在传输管理中继续。已有缓存保留在原位置，完成后文件保存到新目录。',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
      ),
    ],
  ),
);
