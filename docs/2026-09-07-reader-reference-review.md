# Reader 参考项目对照（2026-09-07）

结论：保留原生 Swift Reader，优先复用参考项目的能力诊断、账号显选、schema 检查和覆盖率表达方式；不直接替换实时扫描，不在本轮引入其 Python/SQLCipher 运行依赖。该项目有具体可学习的机制，但尚不能从源码推断为所有微信版本均成熟可用。

参考仓库：samwang0041-star/wechat-intelligence-hub。固定提交 **3afe33e0742ef4e92b4babe399bf471fdcd86a7b**。本次只 clone/read 源码，没有运行安装、接入、提权、取密钥或真实数据库脚本。以下链接均固定 SHA。本地工作区同时有其他 Agent 修改，当前问题是查阅时证据，修复状态应以整合后的测试为准。

## 能复用的机制与边界

| 领域 | 参考源码的实际行为 | 对 WeChatHUD 的建议 |
|---|---|---|
| 数据库发现 | 有界遍历数据库目录，跳过媒体目录；报告扫描数、未识别数、访问错误、truncated；按表结构分类数据库 | 用结构化报告替代“找到文件即就绪”；扫描截断和读取失败必须可见 |
| 多账号 | access_plan 遇到多个账号根目录返回 account_selection_required；多个核心库也报歧义，不自动合并 | 自动发现返回候选列表；设置明确保存所选账号，不能把目录枚举第一项称为当前登录账号 |
| 加密材料兼容 | 支持路径映射与 schema-2 salt-key；验证 key 格式与 SQLCipher 参数 | 以独立适配器兼容合法导入材料，避免在 UI/日志打印 key；现有 Swift AES 实现不应假设能直接消费所有 SQLCipher 参数 |
| 读取隔离 | 每次复制主库及 WAL/SHM 到临时目录，用 SQLCipher/SQLite mode=ro、query_only 查询，退出清理 | 借鉴“完整快照后查询”的边界；每次复制大库对常驻 HUD 成本较高，应实测后决定，不能声称参考实现有成熟增量解密缓存 |
| schema 兼容 | 检查必需消息列，可选列缺失时投影为 NULL，并识别压缩内容列 | 对微信版本差异输出明确 incompatible_schema，不把 SQL 失败解释为空聊天 |
| 历史查询 | since/before 在 SQL 中执行，然后按时间与 local_id 排序；遍历所有配置消息库合并 | 历史日期筛选必须前推到查询层；多个分片是否存在同名聊天表需实测，不能固定断言只在一个库 |
| 诊断 | access-plan/doctor 区分依赖、访问材料、权限、schema、部分覆盖及通知预览模式；诊断完成不等于读取就绪 | Settings 展示“可读范围、缺失项、下一步”；支持导出不含聊天/路径/密钥的诊断摘要 |

源码依据：[发现逻辑](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/projects/rion-wechat-reader/rion_wechat_reader.py#L1861-L1938)、[账号与接入状态](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/projects/rion-wechat-reader/rion_wechat_reader.py#L2021-L2124)、[材料映射与参数](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/projects/rion-wechat-reader/rion_wechat_reader.py#L276-L355)、[快照](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/projects/rion-wechat-reader/rion_wechat_reader.py#L221-L245)、[只读连接](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/projects/rion-wechat-reader/rion_wechat_reader.py#L357-L398)、[消息 schema](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/projects/rion-wechat-reader/rion_wechat_reader.py#L824-L846)、[历史查询](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/projects/rion-wechat-reader/rion_wechat_reader.py#L893-L943)、[诊断](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/projects/rion-wechat-reader/rion_wechat_reader.py#L2480-L2509)。

## 不应照搬的部分

参考 tail_messages 先取有限最新窗口，过滤 local_id 后返回最后 limit 条；stream_tail 随后将游标推进到这些行最大 local_id。**推论：积压超过 limit 时会跨过未返回行**，不能作为不丢消息实现。本轮 WeChatHUD 的最旧未处理批次 + 时间/local_id 水位更适合补积压，但仍需持久化下游分析工作队列补齐崩溃恢复。[tail 源码](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/projects/rion-wechat-reader/rion_wechat_reader.py#L1257-L1299)

参考 cache-status 明确为 snapshot_only、无持久内容缓存；其临时快照按顺序复制主库/WAL/SHM，没有显式冻结微信写入或复制前后一致性校验。**推论：它降低了原库写入副作用，但单凭这段代码不能保证复制过程完全原子，也不是常驻读取的性能优化答案。**[缓存声明](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/projects/rion-wechat-reader/rion_wechat_reader.py#L1644-L1664)、[复制顺序](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/projects/rion-wechat-reader/rion_wechat_reader.py#L227-L240)

## 查阅时发现的本项目优先修复项

1. **账号选择与缓存身份**：WeChatReader.autoDetectDBDir 返回首个 db_storage，不能据此检测哪个账号活跃；cacheDir 和 hash(relativePath) 不含账号根目录，manifest 也不记录账号。多 Reader/账号并存可能共享缓存路径，重启后仅比较 mtime 不足以证明身份。应将规范化账号根目录纳入缓存命名与 manifest 验证，候选多账号时显选。
2. **负缓存未失效**：chatDBNegativeCache 注释声称 refresh 时清空，但查阅时仅在 loadKeys 文件变化时清除，refreshIfChanged 没有清空实现。首次发现无表后，新建聊天表可能整次进程都不可见。变化刷新、密钥切换、分片集合变化均需失效策略。
3. **WAL 完整性**：WeChatDecryptor.applyWAL 查阅时仅比对 salt，没有 commit frame 或 checksum 校验；超过旧 dbLen 的新增页被跳过，page number 为 0 可导致无符号减法下溢。需要以官方 SQLite WAL 格式另行核验并建立损坏帧、未提交事务、扩容页测试；不能直接把参考项目读快照的设计当作本实现 WAL 正确性的证明。
4. **缓存可见范围**：persistent/temporary/memory 三种策略均落盘，memory 实际为进程临时目录，UI 必须如实说明；当前路径创建没有显式设置目录0700/文件0600，应核验实际权限及退出清理。

这些项已发送主 Agent；本研究任务没有改 Reader/Decryptor，以避免与日期查询工作并发冲突。

## 许可与依赖决策

仓库明确标注 **AGPL-3.0-only**，不是宽松许可。商业使用本身不自动要求另购授权；原作者列出闭源整合、免除 AGPL 源码义务、OEM 等场景适合另行商业协议。原文关键句：“Commercial terms are not granted by this document.” 以及 “Any commercial software license must be agreed separately in writing.” 本轮没有取得这种协议。[商业许可原文](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/COMMERCIAL-LICENSE.md#L3-L14)

NOTICE 保留作者身份与商标边界；不能把自己的产品包装为对方官方项目。AGPL 的复制、修改、分发与远程交互条件需根据最终集成形态遵守，不能因改为 subprocess 调用就推断所有义务自动消失。[NOTICE](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/NOTICE.md#L3-L13)、[LICENSE](https://github.com/samwang0041-star/wechat-intelligence-hub/blob/3afe33e0742ef4e92b4babe399bf471fdcd86a7b/LICENSE)

建议当前只将其作为固定版本设计与测试参考，以本项目已有接口独立实现能力诊断和可靠性修复。若之后决定引入原始代码或分发其 CLI，先明确 WeChatHUD 的发布许可及完整依赖来源、通知文件、对应源码交付方式；闭源路线则取得相应书面授权。无需为此次只读研究暂停当前功能开发。

## 后续独立实现（同日）

主线随后授权继续修复，以下实现均依据本项目代码及 SQLite 公开格式独立编写，没有复制参考库源码：

- `WeChatReader`：规范化账号根目录派生 SHA-256 缓存身份；manifest 核验身份/缓存所在目录；自我昵称学习按账号隔离；唯一候选才能自动选择；公开账号候选与不读取密钥内容的可用性状态；消息库刷新清除正负发现缓存；重新载入密钥后废弃旧解密映射。
- 会话临时缓存独立实例目录、目录0700，释放 Reader 时清除；数据库/manifest文件0600。主库解密与 WAL 发布都先完成临时副本，再原子替换。
- `WALReplay`：校验头、页尺寸、格式版本、两种checksum字节序、滚动帧校验、salt及页号；只返回最后一次commit之前的有效前缀。重放允许已提交页扩容/缩容，不重放未提交尾部。依据：[SQLite WAL 格式与校验算法](https://www.sqlite.org/fileformat2.html#wal_format)。
- 验证包括真实 SQLite 生成 WAL、独立合成损坏/截断/事务边界 fixture，以及真实 SQLite→测试专用AES加密→Reader读取的新表出现/空页恢复流程；不以这些测试代替当前微信加密 WAL 的实机兼容验证。

剩余边界：目录存在不证明当前登录身份；多文件源快照仍应增加并发写入/检查点实测；扫描到下游AI分析的崩溃恢复仍需持久化工作队列。AGPL运行依赖没有引入。

## 账号业务库隔离补充

后续新增 `AccountStoreCoordinator` 接入 AppDelegate 启动：`device-settings.json` 只承载 ai/sync/notification 与一次性旧库身份绑定，文件0600；其他数据和设置保留在账号库。已有 `hud.sqlite3` 不移动不删除，首次只按旧库明确持久化的有效根目录建立绑定；auto/空值不能根据当前候选推断历史归属，后续不会因新选择而改绑。新账号使用 `accounts/<root SHA-256>/hud.sqlite3`。没有明确目录或候选有歧义时使用空的 unconfigured 库，旧库不认领给后来账号。设备sync路由保留最新显式目录，重启可恢复。

专项测试验证旧白名单/草稿/托管设置/游标/记忆/承诺/分类队列不流入新账号，切回可恢复；AI设备设置可共享；未知旧库原数据仍保留；损坏设备配置时启动失败而非猜测另一个账号。

旧库未绑定时，恢复方式是先在本机备份 `hud.sqlite3` 及对应WAL/SHM，再由用户核实旧库所属账号的历史目录与身份；当前版本不自动迁移或提供一键认领。确认后可由明确的维护流程建立绑定，不能用“现在只剩一个候选账号”替代归属证据。原文件完整保留，新账号仍使用隔离空库。
