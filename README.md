# rt-thread-integrated-debug.skill

[![RT-Thread](https://img.shields.io/badge/RT--Thread-Integrated_Debug-0ea5e9)](#功能)
[![Status](https://img.shields.io/badge/status-active_development-f59e0b)](#项目状态)
[![Platform](https://img.shields.io/badge/platform-Windows-2563eb)](#运行前提)
[![PowerShell](https://img.shields.io/badge/PowerShell-Helper_Scripts-5391FE)](#脚本)
[![Serial](https://img.shields.io/badge/Serial-MSH%2FFinSH-16a34a)](#串口验证)

**语言 / Language**：**中文**

`rt-thread-integrated-debug` 是一个面向 RT-Thread 嵌入式工程的集成调试 skill，目前仍处于开发和持续优化阶段。

它的目标不是让 AI 停留在“改一段代码”这一步，而是把嵌入式开发中真实需要的验证链路串起来：

1. 识别 RT-Thread 工程结构、BSP、配置和构建方式
2. 根据用户目标做最小必要修改
3. 构建工程并分析编译、链接和工具链问题
4. 构建通过后，在信息确认完整时烧录固件
5. 通过串口日志、MSH/FinSH 命令和板端现象验证运行结果
6. 对无法验证的硬件、烧录器、串口或工具链条件明确标注

## 项目状态

当前仓库是开发中版本，主要用于沉淀和完善 RT-Thread 嵌入式工程的 AI 辅助调试流程。

现阶段已经包含构建、烧录和串口验证相关脚本，但不同 BSP、工具链、烧录器、开发板和 RT-Thread Studio 工程配置之间差异较大，因此工作流和脚本参数仍会继续调整。

后续优化方向包括：

- 更稳的 RT-Thread 工程识别和构建命令推断
- 更完整的 ARM GCC / RT-Thread Studio 构建日志分析
- 更安全的烧录器类型、目标芯片名和固件路径确认流程
- 更可靠的串口日志采集、MSH/FinSH 命令验证和异常判断
- 更多真实工程案例、失败样例和排查参考
- 更清晰的最终报告格式和 gate 状态表达

在正式稳定前，不建议把当前脚本参数视为长期不变的公共接口。使用时应优先阅读 `SKILL.md` 和脚本帮助，并结合具体工程日志进行验证。

## 功能

- 识别 RT-Thread 工程、BSP、驱动、组件、包和配置文件
- 辅助修改应用逻辑、驱动代码、板级初始化和 RT-Thread 配置
- 分析 `make`、`arm-none-eabi-gcc`、链接器、`objcopy`、`size` 输出
- 区分源码问题、配置问题、工具链 PATH 问题和构建环境问题
- 通过标准脚本执行稳定重构建并保留日志证据
- 支持 DAPLink / CMSIS-DAP / DAP、ST-LINK、J-Link 三类烧录路径
- 打开串口读取 RT-Thread 启动日志、异常日志和 MSH/FinSH 输出
- 使用 Build / Flash / Serial 三个 gate 管理验证结论

适合处理的问题包括：

- RT-Thread 工程编译失败
- 新增或修复应用线程、定时器、IPC、设备访问逻辑
- 驱动初始化失败、设备找不到、组件配置不一致
- hard fault、assert、重启循环、串口无输出
- RT-Thread Studio / Makefile / ARM GCC 构建环境异常
- PyOCD、STM32CubeProgrammer、J-Link 烧录日志分析

## 运行前提

- 推荐环境：Windows + PowerShell
- 构建 RT-Thread Studio / ARM GCC 工程通常需要：
  - `make`
  - `arm-none-eabi-gcc`
  - `arm-none-eabi-objcopy`
  - `arm-none-eabi-size`
- 串口验证需要 Python 环境、`pyserial` 和可用串口权限
- 烧录验证按调试器类型准备对应工具：
  - DAPLink / CMSIS-DAP / DAP：PyOCD
  - ST-LINK：STM32CubeProgrammer
  - J-Link：SEGGER J-Link

当工程中存在以下文件或目录时，通常可以判定为 RT-Thread 工程：

```text
rtconfig.h
.config
Kconfig
SConstruct
SConscript
rtconfig.py
applications/
board/
drivers/
packages/
components/
```

## 快速开始

### 构建

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Build_powershell.ps1 -ProjectRoot . -BuildDir Debug -BuildCommand "make -j12 all"
```

`Build_powershell.ps1` 是标准构建入口。默认流程会安全清理构建目录中的生成产物，再执行构建命令，并输出包含构建结果、工具链路径、错误数量、告警数量和日志路径的证据。

### DAPLink / CMSIS-DAP / DAP 烧录

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/FlashMCU_powershell.ps1 -FirmwarePath .\Debug\rtthread.bin -ProgrammerType DAP -Target <confirmed-pyocd-target>
```

`-Target` 必须来自 PyOCD 目标列表、RT-Thread Studio 日志、工程配置或用户确认。不要直接把 MCU 型号当成 PyOCD 目标名。

### ST-LINK 烧录

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/FlashSTLink_powershell.ps1 -FirmwarePath .\Debug\rtthread.bin -ProgrammerType ST-LINK -Verify -ResetAfterFlash
```

### J-Link 烧录

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/FlashJLink_powershell.ps1 -FirmwarePath .\Debug\rtthread.bin -ProgrammerType J-Link -Device <confirmed-jlink-device>
```

`-Device` 必须使用当前 J-Link 工具支持的设备名。

### 串口验证

```powershell
pip install pyserial
python scripts/Open_serial_msh.py --port COM19 --baudrate 115200 --read-seconds 2 --command reboot --after-command-seconds 5 --log-path serial-reboot.log
```

`--command` 可以重复传入，用于依次发送多个 MSH/FinSH 命令。

## 工作流

```text
analyze -> modify -> build -> fix -> flash -> serial test -> runtime debug -> iterate
```

每个关键阶段都应有明确状态：

```text
Build gate: pending | passed | failed | skipped | blocked
Flash gate: pending | passed | failed | skipped | blocked
Serial gate: pending | passed | failed | skipped | blocked
Runtime conclusion: verified | not verified
```

构建通过只代表 Build gate 通过。对于运行行为、驱动问题、板端现象或外设功能，只有完成烧录和串口/硬件验证后，才应报告为已验证。

## 使用原则

- 以本地工程文件、脚本、日志和配置为准，不猜接口
- 优先复用 RT-Thread 标准 API、项目已有结构和已有构建方式
- 修改范围保持最小，不重写无关 BSP、驱动、启动文件或链接脚本
- 每次有意义的代码或配置修改后都执行构建验证
- 烧录前必须确认固件路径、烧录器类型、目标名和烧录工具
- 串口验证前必须确认串口号和波特率
- 不把构建成功等同于运行成功
- 不执行 mass erase、option bytes 修改、读保护变更、bootloader 覆盖等危险操作，除非用户明确要求并确认

## 仓库结构

```text
.
├── SKILL.md
├── scripts/
│   ├── Build_powershell.ps1
│   ├── FlashMCU_powershell.ps1
│   ├── FlashSTLink_powershell.ps1
│   ├── FlashJLink_powershell.ps1
│   └── Open_serial_msh.py
├── references/
│   ├── rt-thread-studio-make-build-log.md
│   ├── rt-thread-studio-pyocd-flash-log.md
│   └── rt-thread-serial-success-log.md
└── README.md
```

## 关键文件

- `SKILL.md`：skill 主说明，定义 RT-Thread 集成调试流程、gate 规则和输出要求
- `scripts/Build_powershell.ps1`：标准构建入口，自动发现 GNU Arm 工具链，安全清理构建产物并捕获构建日志
- `scripts/FlashMCU_powershell.ps1`：通过 DAPLink / CMSIS-DAP / DAP 使用 PyOCD 烧录固件
- `scripts/FlashSTLink_powershell.ps1`：通过 ST-LINK 使用 STM32CubeProgrammer 烧录固件
- `scripts/FlashJLink_powershell.ps1`：通过 J-Link 使用 SEGGER 工具烧录固件
- `scripts/Open_serial_msh.py`：打开串口、读取 RT-Thread 日志，并可发送 MSH/FinSH 命令
- `references/rt-thread-studio-make-build-log.md`：RT-Thread Studio / Makefile 构建日志分析参考
- `references/rt-thread-studio-pyocd-flash-log.md`：PyOCD 烧录日志分析参考
- `references/rt-thread-serial-success-log.md`：RT-Thread 串口启动成功日志参考

## 脚本

| 脚本 | 用途 |
| --- | --- |
| `scripts/Build_powershell.ps1` | 标准构建入口，负责工具链发现、安全清理、构建执行和日志捕获 |
| `scripts/FlashMCU_powershell.ps1` | 使用 PyOCD 通过 DAPLink / CMSIS-DAP / DAP 烧录 |
| `scripts/FlashSTLink_powershell.ps1` | 使用 STM32CubeProgrammer 通过 ST-LINK 烧录 |
| `scripts/FlashJLink_powershell.ps1` | 使用 SEGGER J-Link 工具烧录 |
| `scripts/Open_serial_msh.py` | 打开串口、读取日志、发送 MSH/FinSH 命令 |

脚本会尽量输出可用于判断 gate 状态的证据。失败时应优先查看首个有效错误行，而不是只看最后一行退出码。

## 输出要求

处理 RT-Thread 工程任务时，最终报告应包含：

- 任务理解和修改范围
- 修改过的文件
- 构建命令、构建结果和首个关键错误
- 烧录命令和烧录结果，如果执行过
- 串口号、波特率和关键日志，如果执行过
- Build / Flash / Serial gate 状态
- 运行结论是否已验证
- 剩余限制和下一步最小行动

## 安装

```powershell
git clone https://github.com/wsoz-ohb/rt-thread-integrated-debug-skill.git
```

保持仓库目录完整即可，不需要拆分 `SKILL.md`、`scripts/` 和 `references/`。

## Star History

<a href="https://www.star-history.com/?repos=wsoz-ohb%2Frt-thread-integrated-debug-skill&type=timeline&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=wsoz-ohb/rt-thread-integrated-debug-skill&type=timeline&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=wsoz-ohb/rt-thread-integrated-debug-skill&type=timeline&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=wsoz-ohb/rt-thread-integrated-debug-skill&type=timeline&legend=top-left" />
 </picture>
</a>

## License

当前仓库尚未附带 `LICENSE` 文件。正式开源前建议补充许可证文件。

## 社区

- [RT-Thread 官网](https://www.rt-thread.org/)
- [RT-Thread GitHub](https://github.com/RT-Thread/rt-thread)
