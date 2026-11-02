# v4 远程流程规则

v4 将接口流程和签名组合放入后台签名的 JSON，App 获取后在本机执行。后台日常负责草稿、测试、发布和回退；文件列表、取链与下载由 App 直接访问规则声明的原站域名。后台 PHP 执行器用于管理员测试，v4 客户端不能调用后台解析任务接口代执行。

需要先安装一次包含 v4 引擎的客户端。以后接口路径、参数、响应字段、会话请求头、轮询、分页及可用运算组成的签名变化，都可以修改规则解决。现有 v1–v3 规则继续兼容；已有后台任务通道保留各自执行方式，升级引擎不会自动迁移所有站点。

## 发布流程

1. 后台「解析规则」选择站点，载入 v4 预设或编辑 JSON，保存草稿。
2. 填写分享链接及提取码，运行「测试列表与取链」。测试通过队列异步执行，支持取消；只为一个选中文件取链，避免对整个分享逐个消耗额度。
3. 当前草稿在 24 小时内测试成功后发布，并启用站点。测试记录包含步骤编号、HTTP 状态、耗时，不包含完整响应或会话凭据。
4. App 启动及运行中每 15 分钟检查签名清单。新解析使用新规则，旧任务保留原规则；疑似接口变化会触发一次额外刷新。
5. 配置了备用地址时，重新导出并上传 `parser-rules.json`。导出中 `engines["4"]` 和 `engines["3"]` 各自独立签名；不把 v4 规则发送给旧引擎。

回退通过历史版本发布新的递增版本，仍遵守客户端的防回退验证。

## 结构和步骤

顶层继续使用 `schema: 1`，新增规则设置 `engine: 4`。`siteId`、`platform`、`authMode`、域名限制、密码阶段及最终文件格式沿用 v3。v4 不能设置 `execution.type: server`。

`operations.list` 和 `operations.download` 各包含 `steps`、`result`，可设置 `timeout`（默认 120 秒）及 `maxRequests`（默认 80）。列表界面的总等待时间随规则时限加上 30 秒收尾余量，不会在旧的 90 秒限制处提前退出。

| 步骤配置 | 用法 |
| --- | --- |
| `id` | 当前操作内唯一的小写编号，供后续步骤引用 |
| `type: request` | 默认类型；`method` 为 GET/POST，`url` 可为固定地址或表达式 |
| `type: value` | 计算 `value` 并存入 `steps.<id>` |
| `type: delay` | 等待表达式 `milliseconds` 指定的毫秒数，支持取消 |
| `when` | 结果严格为 `true` 时执行；分页跳过的步骤保留之前结果，便于只创建一次会话 |
| `headers/query/body/options` | 使用表达式构造请求参数；POST 默认为 JSON 对象 |
| `codec` | `json`、`form`，或已有 `checkrand/kdown_csrf/kdown_download` 编码 |
| `decode` | `json`、`text`、`sse` 或原有 `kdown` 解码 |
| `success` | 必须满足的响应表达式；同时要求 HTTP 2xx |
| `errors` | `[{"when":表达式,"code":"upstream_unavailable"}]` 等显式错误映射 |
| `poll` | 仅 GET；`until`、`intervalMs`（默认 1500）、`maxAttempts`（默认 60） |
| `onError` | 显式允许进入后续备用步骤的错误代码列表；失败结果为 `{failed:true,code:...}` |

HTTP 429 映射额度或频率限制，5xx 映射原站不可用，3xx 提示接口跳转。POST 不会因为配置了轮询而重复提交；取消、计算预算及非法域名错误不能被 `onError` 吞掉。

例如任务提交后查询动态路径：

```json
{
  "id": "status",
  "method": "GET",
  "url": {"$op":"concat","args":[
    "https://api.example.com/tasks/",
    {"$op":"urlEncode","args":[{"$ref":"steps.submit.token"}]}
  ]},
  "poll": {
    "until": {"$op":"eq","args":[{"$ref":"last.done"},true]},
    "intervalMs": 1500,
    "maxAttempts": 80
  }
}
```

`decode: sse` 处理有限长度事件流，合并同一事件的多行 `data:`，忽略 `[DONE]`，返回 `{events:[...],last:...}`。它等待响应结束；无限持续连接或浏览器流式交互需要其他能力支持。

列表分页使用 `pagination.initialCursor/hasMore/nextCursor/maxPages`。每页按同一 `steps` 顺序执行，依文件 ID 去重；可用 `when: page.number == 1` 限制提交或会话步骤。游标停滞、没有新增文件但仍声称有下一页、达到上限却未完成时会报错，避免悄悄丢文件。

## 表达式与函数

表达式仍使用 `{"$ref":"路径"}` 和 `{"$op":"操作","args":[...]}`。新增引用包括 `args.0`、`acc`、`index`、`attempt`、`clock.nowMs/elapsedMs`、`response.status/headers`、`responses.<步骤编号>.status/headers`。响应头名称为小写，值为数组，例如 `responses.session.headers.x-session-token.0`。原有 `input/steps/secret/device/item/last/page` 保留。

顶层 `functions` 定义最多 32 个纯表达式函数。使用 `call` 调用，通过 `args.0` 等读取参数；函数可组合、调用其他函数，但受深度和运算预算限制。规则不能读取 App 账号、文件系统或执行任意主机代码。

```json
{
  "functions": {
    "signature": {"$op":"hmac","args":[
      "sha256", {"$ref":"args.0"}, {"$ref":"args.1"}
    ]}
  }
}
```

调用形式：`{"$op":"call","args":["signature",待签名文本,密钥表达式]}`。原站临时密钥应从会话响应中取得，不写入公开规则；长期秘密也不能靠下发到客户端来保密。

| 能力 | 操作与参数 |
| --- | --- |
| 条件和数据 | 旧版操作；新增 `get(value,key,default)`、`merge(...)`、`length`、`isList/isMap`；v4 的 `and/or/coalesce` 短路执行 |
| 遍历 | `map`；`filter(list,条件)`；`reduce(list,初值,表达式)`，可引用 `item/index/acc` |
| 整数 | `add/sub/mul/div/mod`、`bitAnd/bitOr/bitXor/shl/shr`、`lt/le/gt/ge/min/max`、`toRadix(value,base,width)` |
| 编码 | `bytes(text,"utf8"或"utf16")`、`utf8(bytes)`、`base64/unbase64`、`hex/unhex`、`urlEncode/urlDecode`、`jsonEncode/jsonDecode` |
| 摘要 | `hash(algorithm,data)`、`hmac(algorithm,data,key)`；算法为 md5、sha1、sha224、sha256、sha384、sha512，结果为小写十六进制 |
| 对称加密 | `aesCbc("encrypt"或"decrypt",dataBytes,keyBytes,ivBytes)`；PKCS7，密钥 16/24/32 字节，IV 16 字节，输出字节数组 |
| 公钥加密 | `rsaEncrypt(text,PEM)`；RSA PKCS1 v1.5，1024–4096 位，输出 Base64 |
| 文本 | `trim/lower/upper/split/join/replace`、`slice(value,start,count)`、`match(text,pattern,group)` |
| 随机 | `randomHex(byteCount)`，1–64 字节；用于协议随机数 |

超过 `2^53−1` 的整数结果用十进制字符串保存，继续参与整数运算时不丢精度。整数最多 512 位；大常量应直接写字符串。`bytes(...,"utf16")` 返回 UTF-16 码元，可组合网页按字符计算的算法；`length` 与文本 `slice` 按 Unicode 码点计算。

## 域名、预算与边界

- 动态 URL 在真正请求前再次检查 `allowedHosts`，只允许声明域名的 HTTPS，不自动跟随跳转。
- 原站会话需要 Cookie/Authorization 时，用 `requestHeaders` 声明，并通过 `requestCredentialHosts` 限定完整域名。仅发送规则计算出的会话值，不读取 App 的账号 Cookie。下载 Cookie 仍由 `downloadHeaders/downloadCredentialHosts` 限域。
- 每操作最多 24 步、300 秒、120 次请求；单次请求最多 60 秒；GET 轮询最多 100 次，间隔 250–10000ms；单次等待最多 10 秒。
- 列表最多 50 页、10000 个文件；单个响应最多 1MiB；JSON 最多 47 层容器；SSE 最多 2000 个事件。
- 规则最多 60000 字节、12000 个表达式节点；执行最多 500000 次求值，求值深度不超过 24。字符串和列表中间值分别有限额。这些限制不等于可随时抢占所有同步计算。
- 正则模式限 512 字符、输入限 16384 字符；采用 Dart/PHP 都支持的简单模式，避免复杂回溯。两端正则实现不同，发布前应验证真实样本。

后台管理员测试需要 PHP GMP、OpenSSL 等现有运行依赖。跨语言测试覆盖签名、整数精度、HMAC、AES、RSA、JSON、分页、轮询、取消和凭据域名限制。

原站新增必须人工完成的验证码、浏览器环境验证、App 没有的加密原语、系统权限或新的用户交互时，仍可能需要升级客户端。原站停服、额度不足、账号池故障不能靠规则修复。

## file.mdx.wang 接入结果

2026-10-17 已发布并启用 `mdx_convert`（百度）和 `mdx_quark`（夸克）的 v4 直连规则。百度的 FNV64/DJB32 组合签名写在下发的 `functions` 中；App 引擎没有 MDX 专用签名分支。夸克规则负责提交、排队、文件列表和选中文件取链。

后台正式测试和 App 签名清单读取均通过：百度样本 1 个文件、夸克样本 14 个文件，两边各实际读取 65536 字节，HTTP 206。App 记录中后台解析任务请求数为 0。这是本次样本与时间点的实测结果，不代表原站长期可用性。
