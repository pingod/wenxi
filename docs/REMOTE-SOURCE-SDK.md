# 远程来源 SDK：协议 1

适用于当前 `source/javascript/http/html/crypto/codec = 1` 的客户端与后台测试 CLI。实现以 `lib/data/sources/` 和 `vendor_plugins/asterlink_js/` 为准。

## 一个可直接录入后台的示例

在后台“来源接入包”中新建来源。清单框填写下面的 JSON；模块编辑器创建 `main.js`，填写下一段代码。编辑器保存时会把模块组合为 `modules: {"main.js": "源码"}`，完整接入包包含清单与全部模块。

```json
{
  "schema": 1,
  "id": "public_html_example",
  "name": "公开 HTML 示例",
  "requires": {
    "source": 1,
    "javascript": 1,
    "http": 1,
    "html": 1,
    "codec": 1
  },
  "entry": "main.js",
  "match": [
    {"host": "www.rfc-editor.org", "pathPrefix": "/rfc/"}
  ],
  "permissions": {
    "hosts": ["www.rfc-editor.org", "rfc-editor.org"],
    "downloadHosts": ["www.rfc-editor.org", "rfc-editor.org"],
    "methods": ["GET"],
    "headers": []
  },
  "operations": {
    "resolve": "resolve",
    "download": "download"
  }
}
```

```javascript
export async function resolve(input, api) {
  const response = await api.request({
    url: input.url,
    redirects: true
  });
  const page = await api.html(response.text, {
    links: {
      selector: 'a[href="./rfc20"]',
      attributes: ["href"],
      limit: 1
    }
  });
  const items = [];
  for (const row of page.links) {
    items.push({
      id: "rfc20",
      name: "rfc20.txt",
      kind: "file",
      url: await api.codec("urlResolve", [input.url, row.href + ".txt"])
    });
  }
  return {title: "RFC 20", items};
}

export function download(input) {
  return {urls: [input.resource.url]};
}
```

测试链接：[RFC 20](https://www.rfc-editor.org/rfc/rfc20.html)。该示例只演示 RFC 20 的页面提取，未实现通用 RFC 搜索。完整可机器读取的三类实网示例位于 `test/fixtures/sources/live-examples.json`，另有 JSON API 和包内模块签名示例。

## 清单

| 字段 | 约束或默认值 |
| --- | --- |
| `schema` | 固定为整数 1 |
| `id` | 稳定来源身份，2–64 个字符；匹配 `^[a-z][a-z0-9_.-]{1,63}$` |
| `name` | 非空，最多 60 个 Unicode 字符 |
| `requires` | 能力名到最低整数版本；至少声明 `source` 和 `javascript`；最多 24 项 |
| `entry` | 入口模块名，必须存在于 `modules` |
| `modules` | 模块名到源码字符串，1–16 个模块；整个包最多 256 KiB |
| `operations` | 操作名到入口模块导出函数名；必须有 `resolve` 和 `download`，最多 16 项 |
| `match` | 1–16 项匹配条件；每项为 `host`，可选 `pathPrefix`、`queryKey` |
| `permissions` | 请求与下载权限，见下表 |
| `timeout` | 每次操作总时限，单位秒；默认 120，范围 1–300 |

发布版本由后台管理，不通过在清单内填写 `version` 指定。修改站名或域名时保持 `id`，避免破坏已有任务的来源身份。

`match.host` 使用小写域名，可写 `*.example.com`，但此通配不包含根域。`pathPrefix` 默认为 `/`；`queryKey` 仅检查参数是否存在，不比较值。清单匹配不授予网络权限，请求仍需通过 `permissions` 检查。

| 权限 | 用途 |
| --- | --- |
| `hosts` | API/HTML 请求域名；必填，1–32 项 |
| `downloadHosts` | 返回的下载地址以及后续跳转域名；必填，1–32 项 |
| `methods` | 默认 `["GET","POST"]`；可声明 GET、POST、PUT、PATCH、DELETE、HEAD、OPTIONS |
| `schemes` | 默认 `["https"]`；可声明 HTTP，但仍拒绝从 HTTPS 跳转降级 |
| `ports` | 默认 `[80,443]`；1–16 个端口 |
| `headers` | 脚本自行设置的请求头及下载头白名单；默认空，最多 32 项 |

域名声明不接受 IP、localhost、内网名称或 URL。最终 DNS 结果还必须全部为允许的公网地址。URL 不能包含用户名密码、空白、控制字符或反斜杠，最多 16,384 字符。

禁止自行设置 `Host/Connection/Content-Length/Transfer-Encoding/Proxy-Authorization/Proxy-Connection/Upgrade`。请求头名忽略大小写；同名头不能重复。需要发送 Cookie、Authorization、Referer 或自定义头时，必须显式声明，并提供具体值。脚本无法读取 App 中其他网盘的凭据。

## 模块、操作与状态

使用标准 ES module 导出函数：

```javascript
import {makeValue} from "./shared.js";

export async function resolve(input, api) {
  const value = makeValue(input.url);
  return {title: value, items: []};
}
```

模块名可以包含子目录，例如 `helpers/sign.js`；通过相对路径导入包内模块。没有网络模块加载、npm、Node.js 或浏览器接口。BigInt 可参与计算，但跨宿主边界和操作返回值必须转为字符串等可 JSON 序列化的数据。

每次操作创建新 VM。模块全局变量不会跨操作保留。通过返回页的 `state` 保存下一步需要的 JSON 数据；后续列表返回时也应带上仍需保留的 `state`。

| 操作 | 主要输入 | 返回值 |
| --- | --- | --- |
| `resolve` | `url/text/passcode` | 资源页 |
| `list` | 原始输入、`state`，可带 `directory/cursor/query` | 资源页 |
| `search` | 原始输入、`state/query`，可带当前目录 | 资源页 |
| `detail` | 原始输入、`state/resource` | `{title, description}`；当前 UI 显示文字描述，最多展示 10,000 字符 |
| `download` | 原始输入、`state/resource` | 下载候选地址 |

`directory/resource` 是此前返回的完整资源对象，包括来源自定义字段。`cursor` 可以是有界 JSON 值。搜索的后续分页也由 `list` 处理，因此 `list` 应识别输入中的 `query`。

这五种操作由当前界面驱动。清单接受其他操作名，仅用于协议扩展预留，不会自动生成登录、上传或任意新操作按钮。

### 资源页

```json
{
  "title": "示例目录",
  "items": [
    {"id": "folder-1", "name": "文件夹", "kind": "directory"},
    {"id": "file-1", "name": "示例.txt", "kind": "file", "size": 128}
  ],
  "state": {"folderId": "root"},
  "cursor": "next-page",
  "hasMore": true
}
```

- `items` 必填，最多 10,000 项；ID 在该列表中必须唯一。客户端合并分页后仍检查数量和重复 ID。
- 资源 `id/name` 必填，分别最多 1,024/512 字符；`kind` 缺省为 `file`，仅支持 `file/directory`；`size` 可省略，提供时为非负整数。
- 单资源 JSON 最多 16 KiB；`state` 必须是对象，最多 16 KiB；`cursor` 最多 4 KiB。整个返回仍受桥接消息大小限制。
- 返回目录必须声明 `list`。`hasMore: true` 必须同时提供 `list` 与非空游标；后续仍有更多数据时游标必须推进。
- `state` 是任务恢复上下文，不是专用账号秘密存储。

### 下载结果

```json
{
  "urls": [
    "https://cdn.example.com/file.bin",
    {
      "url": "https://mirror.example.com/file.bin",
      "headers": {"User-Agent": "AsterLink"}
    }
  ],
  "headers": {"User-Agent": "AsterLink"}
}
```

返回 1–16 个候选。全部 URL 必须符合 `downloadHosts/schemes/ports`，全部脚本提供的头必须在 `headers` 声明中。

候选对象的 `headers` **整份替换**顶层 `headers`，不做合并；写 `{}` 表示该候选没有脚本请求头。可在顶层或候选对象添加非负整数 `expiresAt`；当前仅校验并解析此字段，未写入 DownloadSpec，也不触发到期前刷新。

下载系统需要重新取链时，使用任务保留的原签名包、资源和上下文，再执行 `download` 并轮换候选。不要假设它会自动改用后台最新脚本。来源被停用或原任务包缓存不可读取时，需要重新处理来源配置或重新解析。

当前来源只接入普通 HTTP 文件下载，明确拒绝 HLS；没有媒体分片合并和上传操作。

## 宿主接口

所有 `api.*` 方法返回 Promise；使用 `await`。宿主按队列处理调用，不能假设 `Promise.all` 会并行发起网络连接。

### api.request(options)

```javascript
const response = await api.request({
  url: "https://api.example.com/list",
  method: "POST",
  headers: {"Accept": "application/json"},
  encoding: "json",
  body: {page: 1},
  timeout: 30,
  redirects: false
});
if (response.status !== 200) throw new Error("Unexpected status");
const data = JSON.parse(response.text);
```

`method` 默认 GET，`encoding` 默认 json。`timeout` 单位秒，默认 30，范围 1–60；`redirects` 默认 false，启用时最多跟随 5 次跳转。`charset` 可覆盖响应字符集；`binary: true` 跳过文本解码。

| encoding | body 形式 |
| --- | --- |
| `json` | 可 JSON 序列化的数据 |
| `form` | 表单键值对象 |
| `text` | UTF-8 文本字符串 |
| `base64` | Base64 字符串，解码后作为二进制请求体 |
| `multipart` | `{fields: {字段: 字符串}, files: [{name, fileName, base64, contentType?}]}` |

multipart 最多 64 个字段、16 个文件项，文件内容来自内存中的 Base64 数据。请求体总上限仍是 1 MiB；没有读取用户本地文件的宿主接口。编码对应的 Content-Type 由宿主生成；multipart 的 boundary 由宿主统一设置。GET/HEAD 不能携带 body。

普通响应：

```javascript
{
  status: 200,
  url: "https://api.example.com/list",
  headers: {"content-type": ["application/json"]},
  text: "..."
}
```

二进制响应为 `{status, url, headers, base64}`，不含 `text`；普通响应不含 `base64`。`headers` 使用小写键，值为字符串数组。HTTP 4xx/5xx 也返回状态码，由脚本判断；网络异常和权限问题会拒绝 Promise。

文本支持 UTF-8/UTF8、GBK/GB2312、Latin1/ISO-8859-1；GB18030 等未实现编码会报错，不静默使用错误编码。

重定向继续验证域名、协议、端口和方法；跨 origin 只保留 Accept、Accept-Language、User-Agent。303（HEAD 除外）及 POST 的 301/302 会转换为 GET，转换后仍需有 GET 权限。需要重发请求体的跳转由脚本显式处理。没有自动 Cookie jar；必要的短期会话值可从响应中提取并显式传递。

### api.html(text, selectors)

```javascript
const values = await api.html(response.text, {
  files: {
    selector: "a.download",
    attributes: ["href", "data-id"],
    limit: 100
  }
});
// values.files: [{text: "显示文本", href: "...", "data-id": "..."}]
```

使用 HTML 解析器与 CSS 选择器，不执行网页 JavaScript。每组返回数组；`text` 为去除首尾空白的节点文字，缺失属性返回空字符串。最多 32 组选择器，每组最多 16 个属性；`limit` 默认 1,000，范围 1–2,000。选择器最多 512 字符，提取结果和运算输入仍受总大小限制。

### api.crypto(op, args)

```javascript
const digest = await api.crypto("hash", ["sha256", "要计算的文本"]);
const signature = await api.crypto("hmac", ["sha256", "待签名文本", "协议密钥"]);
```

示例密钥是接口占位文字，实际来源不得把长期秘密硬编码到公开模块。

| op | args 与结果 |
| --- | --- |
| `hash` | `[algorithm, data]` → 小写十六进制 |
| `hmac` | `[algorithm, data, key]` → 小写十六进制；注意参数顺序 |
| `aesCbc` | `["encrypt"或"decrypt", dataBytes, keyBytes, ivBytes]` → 字节数组；PKCS7，密钥 16/24/32 字节，IV 16 字节 |
| `rsaEncrypt` | `[text, publicKeyPEM]` → Base64；RSA PKCS1 v1.5，1024–4096 位 |
| `randomHex` | `[byteCount]` → 随机十六进制；1–64 字节 |

摘要算法为 md5、sha1、sha224、sha256、sha384、sha512。运算参数沿用 [v4 运算文档](WORKFLOWS-V4.md) 与 `workflow_expression.dart`，宿主只开放本表列出的操作。

### api.codec(op, args)

开放 `bytes/utf8/base64/unbase64/hex/unhex/urlEncode/urlDecode/jsonEncode/jsonDecode/urlResolve/urlParse`。

```javascript
const bytes = await api.codec("bytes", ["文本", "utf8"]);
const encoded = await api.codec("base64", [bytes]);
const absolute = await api.codec("urlResolve", [
  "https://example.com/folder/page.html", "../file.bin"
]);
const parts = await api.codec("urlParse", [absolute]);
// {scheme, host, path, query: {参数名: 参数值}, fragment}
```

编码接口传递普通 JSON 字节数组；BigInt、循环对象和函数不能跨宿主边界传递。`urlResolve/urlParse` 只解析数据，真正请求时仍检查网络权限。

### api.sleep(ms)

`await api.sleep(500)`，允许整数 0–10,000 毫秒，可取消。它不延长清单声明的操作总时限，无需在 `requires` 中另加 sleep 能力。

## 执行预算

| 项目 | 上限 |
| --- | --- |
| 完整包 / 模块数 | 256 KiB / 16 |
| 单操作输入 / 桥接 JSON 消息 | 64 KiB / 1 MiB |
| JS 堆 / JS 栈 | 32 MiB / 512 KiB |
| 每次进入引擎 / 累计执行 | 250 ms / 5 秒 |
| 操作总时限 | 默认 120 秒，最多 300 秒 |
| API 调用次数 | 每操作 120 次 `api.request`；一次调用内部的物理跳转不另计此计数 |
| HTTP 请求体 / 响应 | 1 MiB / 512 KiB |
| HTML、crypto、codec 宿主计算 | 单次最多 10 秒；输入和结果另受大小限制 |

32 MiB 不包含 Dart、宿主计算和下载引擎的总内存。后台 CLI 一次测试复用同一个宿主，因此列表、取链阶段合计也受 120 次请求限制。为避免大输入占满桥接消息，不应把文件本体放在资源字段或 state 中。

## 测试与发布

1. 保存草稿。后台用哈希检查并发编辑，保存后旧测试资格失效。
2. 填写测试链接、可选提取码和可选文件路径 ID 数组，例如 `["folder-id","file-id"]`。
3. 点击“测试列表与下载”。独立 worker 用相同执行器完成 resolve、必要的目录 list、download，并读取下载结果最多 4 KiB。未指定路径时优先选择当前页的文件，再尝试目录，最多 8 层。
4. 当前草稿测试成功后，在 24 小时内发布；首次发布还需“启用”才能进入目录。测试不穷举搜索、所有分页或全部下载候选，复杂来源需补充各分支用例。
5. 回退选择历史版本并发布成更高版本。停用停止下发；归档保留历史且不再允许复用该来源 ID。

测试输入在后台队列加密保存，测试结束/取消后清除；结果只保留脱敏摘要。普通脚本错误不会把异常正文或签名下载地址输出到后台日志。

常见错误：

| 错误码 | 处理方向 |
| --- | --- |
| `SOURCE_PACKAGE / SOURCE_INPUT` | 检查包格式、参数类型和大小 |
| `SOURCE_CAPABILITY` | 检查 requires、操作声明及客户端能力版本 |
| `SOURCE_HOST / SOURCE_HEADER / SOURCE_METHOD` | 检查域名、下载域名、请求头和方法声明 |
| `SOURCE_REDIRECT` | 检查跳转次数、降级或需显式处理的请求体跳转 |
| `SOURCE_NETWORK / SOURCE_TIMEOUT` | 检查原站连接和处理时限 |
| `SOURCE_BODY / SOURCE_RESPONSE / SOURCE_CHARSET` | 检查请求编码、响应大小或字符集 |
| `SOURCE_COMPUTE` | 检查选择器、编码或密码学参数 |
| `SOURCE_RESULT / SOURCE_DOWNLOAD` | 检查资源页、分页或下载返回结构 |
| `SCRIPT_BUDGET / SOURCE_BUDGET` | 减少计算、请求或数据规模 |
| `SCRIPT_EXECUTION / SCRIPT_OPERATION` | 检查脚本和入口模块导出函数 |
| `SCRIPT_UNAVAILABLE / SOURCE_RUNTIME` | 检查客户端或后台原生运行时安装 |
| `SOURCE_SIGNATURE / SOURCE_ROLLBACK` | 检查签名配置、目录有效期及版本 |
| `SOURCE_DISABLED / SOURCE_ARCHIVE / SOURCE_CACHE` | 检查当前目录、原任务包版本和缓存空间 |
| `SOURCE_CHANGED / SOURCE_TEST_REQUIRED` | 重新打开当前草稿，保存并完成对应测试 |
