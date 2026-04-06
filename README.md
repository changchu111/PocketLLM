# PocketLLM

PocketLLM 是一个 iOS 端侧大模型聊天应用示例：在 iPhone 上通过 `GGUF + llama.cpp` 进行本地推理，实现离线对话（模型文件在 App 内下载到本地，不打包进 App）。

当前默认模型示例：`Qwen3.5-2B-Q4_K_M.gguf`。

## 特性

- 端侧推理：GGUF 模型 + `llama.cpp`
- 聊天 UI：流式输出、停止生成、清空上下文
- 模型管理：下载/选择/删除模型（默认下载到 `Application Support/Models`）
- 参数设置：context length、max tokens、temperature、top_k、top_p、presence/frequency penalty

## 环境要求

- macOS + Xcode（已安装并能连接真机）
- iPhone 真机（建议在真机上跑端侧推理）
- `llama.cpp`（用于构建 `llama.xcframework`）

## 快速开始

### 1) 获取代码

```bash
git clone <your-repo-url>
cd PocketLLM
```

### 2) 构建并引入 `llama.xcframework`

PocketLLM 依赖 `llama.xcframework`（由 `llama.cpp` 构建生成）。本仓库默认不会提交该二进制（体积大、更新频繁）。

步骤：

```bash
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
./build-xcframework.sh
```

生成路径一般为：`llama.cpp/build-apple/llama.xcframework`

把它复制到本项目：

```bash
cp -R llama.cpp/build-apple/llama.xcframework \
  /path/to/PocketLLM/Frameworks/llama.xcframework
```

然后在 Xcode 中确认：

- Target `PocketLLM` → General → Frameworks, Libraries, and Embedded Content
- `llama.xcframework` 为 `Embed & Sign`

### 3) 运行到真机

1. 用 Xcode 打开 `PocketLLM.xcodeproj`
2. `Signing & Capabilities` 里选择你的 Team
3. 选择 iPhone 真机 Run

### 4) 下载模型并开始对话

打开 App：

1. 进入 `Models` → 选择并下载模型（默认提供 Qwen3.5-2B 的下载链接）
2. 在 `Installed` 中点击模型以设为 Active
3. 回到 `Chat` 发送消息

## 模型与许可证

- 你下载/使用的模型权重（GGUF）不应提交到 Git 仓库。
- 请在使用/分发前查看对应模型仓库的许可证与使用条款。

## 隐私说明

- 推理在端侧进行；模型文件存放在本机 App 沙盒。
- 模型下载需要联网；下载 URL 可在 `Models` 页面自定义。

## 常见问题

### 运行后不出字 / 卡住

- 检查是否已选择 Active 模型
- 尝试降低 `Context length` 或 `Max tokens`

### 提示 Prompt too long

- 清空对话（右上角清空按钮），或提高 `Context length`。

## 致谢

- `llama.cpp`: https://github.com/ggml-org/llama.cpp

## License

MIT License. See `LICENSE`.
