# Third-Party Source Information

Audio Toolbox 的发布构建通过 Swift Package Manager 使用以下锁定依赖：

- CXXTagLib 2.3.0
- Git revision: `b570acead5e27006cb41ab5ff7443c8797b3b8e5`
- Upstream repository: `https://github.com/sbooth/CXXTagLib.git`

CXXTagLib 包含本应用实际链接的 TagLib 2.3 源码。与本可执行文件对应的精确依赖状态记录在同目录的 `Package.resolved`。

本应用在同一 `Contents/Resources` 目录中直接随附完整源码归档：

- `CXXTagLib-b570acead5e27006cb41ab5ff7443c8797b3b8e5.tar.gz`

也可以从上游获取对应源码：

```bash
git clone https://github.com/sbooth/CXXTagLib.git
git -C CXXTagLib checkout b570acead5e27006cb41ab5ff7443c8797b3b8e5
```

许可证正文见同目录的：

- `CXXTagLib-LICENSE.txt`
- `Mozilla-Public-License-1.1.txt`

即使外部上游地址不可用，随应用提供的源码归档仍可独立解压和审阅。
