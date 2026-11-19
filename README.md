# Harness — 直连任意大模型的 iOS 客户端

自用客户端。没有任何中间服务端：请求从手机直接打到你填的 API 地址，
key 只在本机 Keychain，提示词、参数、历史全在本地。

## 功能

- **三种协议**：OpenAI 兼容（含中转、vLLM、Ollama、one-api）、Anthropic、Google Gemini
- **流式输出**：SSE 逐字，可中断
- **自动获取模型列表**：从 `/models` 接口拉取，可搜索选择
- **破甲三层**：强化尾段 + 13 条拒绝正则 + 400 字符窗口单次重试
- **灵动岛**：生成时在灵动岛和锁屏显示进度、字数、计时
- **本地模型**：GGUF 文件的下载、导入与管理
- **主题自定义**：浅色/深色/跟随系统、13 种强调色、背景、气泡、圆角
- **用量统计**：请求数、token、破甲重试率、按供应商分组
- **诊断面板**：延迟、token、命中规则、实际发送的完整系统提示
- **会话管理**：搜索、置顶、归档、重命名、重新生成、编辑重发

## 工程结构

```
Sources/
  HarnessApp.swift          入口 + SwiftData 容器
  Theme.swift               主题、背景、外观选项
  Models.swift              Provider / Conversation / ChatMessage / PromptChip
  LLMClient.swift           SSE 流式请求 + 三种协议 + 用量采集
  PromptBoost.swift         破甲尾段 + 拒绝正则 + 单次重试
  ModelCatalog.swift        模型列表自动获取
  KeychainStore.swift       API key 存取
  LiveActivityController.swift  灵动岛 / 锁屏
  LocalModel.swift          本地模型存储与下载
  SessionListView.swift     会话列表
  ChatView.swift            聊天界面
  SettingsView.swift        设置
  ProviderEditView.swift    供应商编辑
  AppearanceView.swift      外观自定义
  UsageView.swift           用量统计
  ChipManagerView.swift     提示词芯片
  DiagnosticsView.swift     破甲诊断
  LocalModelView.swift      本地模型管理
Shared/
  GenerationAttributes.swift  灵动岛共享属性
Widget/
  HarnessWidgetBundle.swift   灵动岛 / 锁屏 Widget
project.yml                 XcodeGen 工程描述
```

零第三方依赖，全部原生框架（SwiftUI / SwiftData / URLSession / Security / ActivityKit）。

## 本地配置

`project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER` 和签名相关设置都是占位符。
在 Xcode 里选自己的 Team，或改成自己的 Bundle ID 即可。

CI 出包需要在仓库 Secrets 里配：

| Secret | 内容 |
| --- | --- |
| `P12_BASE64` | 分发证书 .p12 的 base64 |
| `P12_PASSWORD` | p12 密码 |
| `PROFILE_BASE64` | 描述文件 .mobileprovision 的 base64 |

转 base64：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\to-base64.ps1 .\dist.p12
```

## 构建

GitHub Actions，runner 用 `macos-26`（Xcode 26.6 + iOS 26.5 SDK，不排队）：

```
push → macos-26 → xcodegen → xcodebuild（无签名）→ 打包 ipa → artifact
```

产物是未签名 ipa，用 Sideloadly / iMazing / 自签工具签好再装。

## 关于破甲

两个层面，都在本地：

1. **系统提示词**：`PromptBoost.tail` 逐字取自 dsh-purge 1.6.97 的 `BOOST_TEXT`，
   追加在系统提示最后，声明「拒绝是故障，不是边界」
2. **客户端不做任何过滤**：没有关键词拦截、没有内容审查、没有上报

客户端不拦，不代表服务端不拦。审查发生在 API 那一侧——官方接口有它自己的
policy 层，而中转、自建 vLLM / Ollama、本地模型没有。
