# Third-Party Notices

Audio Toolbox 使用以下第三方软件。上游项目保留其各自版权；本文件不是对上游许可证文本的替代。

## CXXTagLib 2.3.0

- 上游仓库：https://github.com/sbooth/CXXTagLib
- 使用方式：作为 Swift Package Manager 依赖，提供 `taglib` C++ target。
- 许可证：Mozilla Public License 1.1（上游发行包中的 `LICENSE.txt`）。

## TagLib 2.3

- 上游仓库：https://github.com/taglib/taglib
- 使用方式：CXXTagLib 2.3.0 打包的 TagLib 2.3 源码，用于音频元数据读取与写入。
- 许可证：TagLib 主要源文件的文件头声明为 GNU Lesser General Public License version 2.1，或可选择 Mozilla Public License 1.1；此处不将其表述为“LGPL 2.1 或更高版本”。个别随附第三方源码保留其各自许可证声明。

完整许可证文本与对应源码可从上述上游仓库取得。SwiftPM 锁定的 CXXTagLib 版本和 revision 记录在 `Package.resolved`。
