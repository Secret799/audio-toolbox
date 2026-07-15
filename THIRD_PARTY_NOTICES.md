# Third-Party Notices

Audio Toolbox 使用以下第三方软件。上游项目保留其各自版权；本文件不是对上游许可证文本的替代。

## CXXTagLib 2.3.0

- 上游仓库：https://github.com/sbooth/CXXTagLib
- 使用方式：作为 Swift Package Manager 依赖，提供 `taglib` C++ target。
- 许可证：Mozilla Public License 1.1（上游发行包中的 `LICENSE.txt`）。

## TagLib 2.3

- 上游仓库：https://github.com/taglib/taglib
- 使用方式：CXXTagLib 2.3.0 打包的 TagLib 2.3 源码，用于音频元数据读取与写入。
- 许可证：GNU Lesser General Public License 2.1 或更高版本，或者 Mozilla Public License 1.1；TagLib 源文件声明可在这两种许可证中选择。

完整许可证文本与对应源码可从上述上游仓库取得。SwiftPM 锁定的 CXXTagLib 版本和 revision 记录在 `Package.resolved`。
