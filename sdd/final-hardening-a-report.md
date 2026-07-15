# Final Hardening A：批量目标身份绑定与事务耐久性

## 修复结论

本轮修复关闭了最终审查中的两项问题：

1. **Critical：批量编辑只绑定 URL**
   - 新增 `BatchEditTarget`，冻结扫描时的 URL、`FileIdentity`、文件大小和修改时间。
   - `LibraryViewModel` 在打开批量编辑时冻结 `AudioTrack` 快照，执行时映射为 targets；`BatchEditor` 和 `SafeMetadataWriting` 全程传递 target，不再仅传 URL。
   - 抽取 `StableFileIdentityResolver`，统一复用 volume identifier + file resource identifier 的安全归档算法，并在资源标识不可用时使用 POSIX device/inode 作为实时回退。
   - resolver 每次重新构造文件 URL，避免 `NSURL` 资源值缓存让已被替换的路径继续返回扫描时旧指纹。
   - `SafeMetadataWriter` 在创建工作副本前以及文件协调提交窗口内分别重新解析并严格比较 identity、size、mtime。任一字段不匹配均逐文件失败，返回：`文件已变化，请重新扫描确认`，且执行前不创建副本、不调用元数据写入。

2. **Important：原子交换缺少耐久屏障**
   - `CSafeFileBridge` 新增 `ATSFFullSyncFD`：优先 `F_FULLFSYNC`，文件系统不支持时回退 `fsync`，并处理 `EINTR`。
   - `SafeMetadataFileOperations` 增加可注入的工作文件、工作目录、原文件和父目录同步操作；同步前后检查 fd/path 身份。
   - 提交顺序固定为：工作文件同步 → workspace 目录同步 → 原子 swap → 原文件同步 → 父目录同步 → 再次核验 original/recovery 快照 → 删除 recovery。
   - 任一 pre-swap 同步失败都不会执行 swap。
   - post-swap 同步或耐久后核验失败时执行反向 swap，并同步恢复后的 original、work file、workspace directory 和 parent directory。只有回滚状态和同步均确认后才清理工作区；否则返回 uncertain 并保留恢复副本路径。

## 数据模型与扫描

- `AudioTrack` 新增 `modificationDate`。
- `DirectoryScanner` detail keys 新增 `contentModificationDateKey`，正常扫描写入真实 mtime；detail 读取失败时沿用保守回退值 `.distantPast`。
- 所有模型 fixture 和 UI/Core 测试 fixture 已更新。

## 回归覆盖

新增或加强的回归包括：

- 扫描/预览后将原路径替换为另一可读取的 `.mp3` 目标：执行被拒绝，替换文件字节和标签保持不变，copy/write 调用次数为零。
- 同 inode 原地修改，且 size/mtime 指纹变化：执行被拒绝，copy/write 调用次数为零。
- 未变化的扫描 target 正常提交。
- ViewModel 冻结快照并完整映射 `BatchEditTarget`。
- 成功提交的同步调用顺序断言。
- 工作文件 pre-swap 同步故障：不 swap、不改原文件、清理工作区。
- post-swap 原文件同步故障：反向 swap、同步回滚状态、确认后清理。
- post-swap 同步与回滚同步同时失败：返回 uncertain，保留 recovery。
- 耐久同步后再次进行 original/recovery 内容与文件系统元数据核验。

## 测试结果

测试命令均使用仓库隔离脚本，未访问或修改用户音频目录：

- `CODEX_CI=1 Scripts/test.sh --filter BatchEditorTests`：7 tests passed。
- `CODEX_CI=1 Scripts/test.sh --filter DirectoryScannerTests`：12 tests passed。
- `CODEX_CI=1 Scripts/test.sh --filter LibraryViewModelTests`：25 tests passed。
- `CODEX_CI=1 Scripts/test.sh --filter SafeMetadataWriterTests`：46 tests passed。
- `CODEX_CI=1 Scripts/test.sh`：128 tests / 10 suites passed。

测试仅在系统临时目录和仓库自带 integration fixtures 上运行；未对用户音频目录执行写操作。
