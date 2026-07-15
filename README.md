# Audio Toolbox

Audio Toolbox 是一个面向 macOS 13 及更高版本的本地音频元数据整理工具。它扫描用户明确选择的目录，按作者或专辑浏览音频文件，并可批量修改作者和专辑标签。

## 系统要求

- macOS 13.0 或更高版本
- Apple Swift 6 工具链与 Swift Package Manager
- 可用的 `codesign`（Xcode Command Line Tools 提供）

## 支持格式与保守降级

首版自动化夹具已经完成以下读写回归；“写入”包括只改作者、只改专辑、同时修改作者和专辑，并验证标题保留及音频时长仍大于 0：

| 格式 | 扩展名 | 读取 | 写入 | 首版说明 |
| --- | --- | --- | --- | --- |
| MP3 | `.mp3` | 已验证 | 已验证 | 带 ID3v2.4 footer 的 MP3 保守拒绝 |
| MPEG-4 Audio | `.m4a` | 已验证 | 已验证 | 仅承诺已测试的 M4A 夹具 |
| FLAC | `.flac` | 已验证 | 已验证 | 包含前置 ID3v2 探测回归 |
| WAVE | `.wav` | 已验证 | 已验证 | 仅承诺已测试的 WAV 夹具 |
| Ogg Vorbis | `.ogg` | 已验证 | 已验证 | 仅承诺已测试的 OGG 夹具 |
| raw AAC/ADTS | `.aac` | 明确降级 | 明确降级 | 无受支持标签时不可读取、不可编辑 |
| 其他候选扩展名 | `.mp4`、`.oga` | 未做首版夹具验收 | 未承诺 | 扫描器会发现候选文件，但仍须通过内容探测 |

实际读取或写入还取决于 TagLib 能否确认文件内容及标签结构。为避免破坏文件，应用采用保守策略：

- **raw AAC**：无受支持标签的原始 AAC/ADTS 文件会降级为不可读取、不可编辑，并作为扫描失败显示；不会把其他格式仅凭扩展名当作 AAC 处理。
- **带 ID3v2.4 footer 的 MP3**：当前版本保守拒绝读取和写入这类 MP3，即使 footer 结构有效也不会修改原始字节。
- 扩展名与实际内容不匹配、伪造或截断的文件会被拒绝写入。

## 数据安全

Audio Toolbox **不会创建永久备份**。每次写入都会先在原文件同目录的私有临时工作目录中创建事务恢复副本，在副本上写入并重新读取验证，再通过协调交换提交。正常成功、失败或取消后会清理应用拥有的临时副本；如果提交状态不确定或安全清理无法确认，应用会保守保留恢复副本，并在结果消息中给出路径。请仍然对重要音频保留独立备份。

## 构建与测试

构建 SwiftPM release 可执行文件：

```bash
swift build -c release --product AudioToolbox
```

运行全部测试：

```bash
Scripts/test.sh
```

只运行 ViewModel 测试：

```bash
Scripts/test.sh --filter LibraryViewModelTests
```

### SDK 与 compiler 版本不匹配

如果构建出现 `compiled with ... cannot be imported by the Swift ... compiler`、Swift interface compiler version 不一致或宏插件无法加载，先核对当前工具链与 SDK：

```bash
swift --version
xcode-select -p
xcrun --sdk macosx --show-sdk-path
xcrun --sdk macosx --show-sdk-version
```

优先通过 `xcode-select` 选择与 Swift compiler 匹配的 Xcode 或 Command Line Tools。切换工具链后执行 `swift package clean` 再重试。若机器同时安装了多个 macOS SDK，也可以只对当前命令临时指定一个与 compiler 匹配的 SDK，不要写入项目配置：

```bash
SDKROOT=/path/to/compatible/MacOSX.sdk CODEX_CI=1 Scripts/test.sh
SDKROOT=/path/to/compatible/MacOSX.sdk CODEX_CI=1 Scripts/build-app.sh
```

不要用不匹配的 SDK 结果宣称发布验收通过；最终报告应记录实际 compiler、SDK 及 Mach-O minimum macOS 版本。

组装、ad-hoc 签名并验证沙盒 `.app`：

```bash
Scripts/build-app.sh
```

产物位于：

```text
dist/AudioToolbox.app
```

也可以单独检查签名和权限：

```bash
codesign --verify --deep --strict dist/AudioToolbox.app
codesign -d --entitlements :- dist/AudioToolbox.app
```

## 运行与目录授权

运行已打包应用：

```bash
open dist/AudioToolbox.app
```

应用启用 App Sandbox。首次使用时请选择一个包含音频的目录；只有用户明确选择的目录获得读写授权。授权通过 app-scoped security-scoped bookmark 保存，以便重启后恢复最近目录；如果 bookmark 失效，应用会要求重新选择目录。

若音频位于只读目录、只读介质，或当前用户没有写权限，应用仍可能扫描可读取文件，但不会执行元数据写入。测试和验证请优先使用临时目录中的副本，不要直接操作唯一的用户音频文件。

## 第三方软件

第三方组件及许可证见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
