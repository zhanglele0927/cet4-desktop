# 四级背词小窗

Windows 桌面背词工具。支持每日新词、系统语音朗读、错词本、到期复习和本地学习进度。

在仓库页面点 **Code → Download ZIP**，解压完整目录，运行 `CET4Desktop.exe`。请把文件夹放在当前账号可写的位置。点击「认识」直接通过。英文和中文都输对后按回车，会把当前词加入错词本并切换到下一词。

公开版附带 100 个核心词。完整高频词表、第三方音标和频次数据请按其来源许可自行配置。小窗可以读取同目录下的 `cet4-source.json`、`phonetics.json` 和 `priority-words.json`。替换主词库时，需同时提供覆盖所有主词条的 `frequency-order.json`。

`AppHost.cs` 是启动器源码，`Widget-v2.ps1` 和 `Learning.ps1` 实现界面和学习逻辑。要重建启动器，可在 Windows PowerShell 5.1 中运行 `Build-Host.ps1`。如果已有可执行文件，请先备份并移开。

项目代码采用 MIT 许可。第三方词库的 BSD 3-Clause 声明单独保留，见 `VOCAB-LICENSE.txt`。个人学习记录保存在本地 `learning-v2.json`。
