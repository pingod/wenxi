import 'package:asterlink/domain/resource_search.dart';

/// Fictional shares for layout review; never sent to the production service.
List<ResourceSearchHit> resourceSearchSamples() {
  const titles = [
    'Python 编程：从入门到实践（第 3 版）',
    'Python 自动化办公 · 视频与实战项目',
    'Python 数据分析与可视化资料',
    'Python 开源工具与参考文档',
    '流畅的 Python · 第 2 版',
    'Python 爬虫开发与项目实战',
    'Python 核心编程 · 电子书合集',
    'Python 数据科学手册与示例代码',
    'Python 机器学习入门课程',
    'Python 算法与数据结构笔记',
    'Python 办公自动化练习资料',
    'Python Web 开发实战教程',
    'Python 设计模式与最佳实践',
    'Python 网络编程学习笔记',
    'Python 科学计算与数值分析',
    'Python 面试题与练习解析',
    'Python 图像处理与视觉入门',
    'Python 编程快速上手',
    'Python 数据清洗实战',
    'Python 中文文档与离线手册',
    'Python 测试与持续集成指南',
    'Python 项目源码与参考案例',
    'Python 开发环境配置资料',
    'Python 教学课件与实验资料',
  ];
  const hosts = [
    'https://pan.quark.cn/s/',
    'https://pan.baidu.com/s/1',
    'https://www.alipan.com/s/',
    'https://drive.uc.cn/s/',
    'https://pan.quark.cn/s/',
    'https://pan.baidu.com/s/1',
    'https://pan.quark.cn/s/',
    'https://www.alipan.com/s/',
  ];
  return [
    for (var i = 0; i < titles.length; i++)
      ResourceSearchHit.fromRaw({
        'title': titles[i],
        'url': '${hosts[i % hosts.length]}PreviewResource${i + 1}',
        if (i % 3 != 2) 'password': i == 0 ? 'aB12' : '1234',
        'description': '示例资料，包含电子书、配套练习与参考代码。此链接仅用于界面展示。',
        'source_name': ['学习资料分享', '课程资源', '开发者资料库', '软件与文档'][i % 4],
        'datetime': '2026-10-${22 - i % 5} 10:00:00',
      }),
  ];
}
