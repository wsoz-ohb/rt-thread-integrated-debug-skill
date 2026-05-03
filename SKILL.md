---
name: rt-thread-integrated-debug
description: RT-Thread embedded project development and integrated debugging. Use when an RT-Thread project is detected through rtconfig.h, .config, Kconfig, SConstruct, SConscript, rtthread.h, BSP files, device drivers, board initialization, rtconfig settings, packages, components, threads, IPC, timers, build errors, firmware flashing, serial port logs, or runtime debug information.
---

# RT-Thread Integrated Debug

## Goal

Enable the agent to act as an RT-Thread embedded development assistant that can complete the full engineering verification workflow:

1. Understand the RT-Thread project structure, BSP, configuration files, drivers, components, packages, and build system.
2. Modify source code or configuration files according to the user's requirement.
3. Build the project and analyze compiler errors, linker errors, warnings, or configuration problems.
4. Iteratively fix problems until the project builds successfully or a clear blocking issue is identified.
5. Flash the generated firmware to the target board when the hardware and flashing configuration are available.
6. Open the serial port, read RT-Thread startup logs, debug messages, shell output, assert messages, or fault information.
7. Use the runtime logs to continue debugging and verify whether the expected behavior is achieved.
8. Report modified files, build result, flash result, serial test result, and remaining issues clearly.

## Inputs

The agent should use the following inputs when available:

| Input               | Description                                                  |
| ------------------- | ------------------------------------------------------------ |
| `project_root`      | Root directory of the RT-Thread project or BSP.              |
| `user_task`         | The user's requested development, debugging, build, flash, or runtime verification task. |
| `build_command`     | Command used to build the project, such as `scons -j8`, `make -j12 all`, `make -C Debug -j12 all`, or `cmake --build`. |
| `target_board`      | Target development board or RT-Thread BSP name.              |
| `mcu_model`         | Target MCU model.                                            |
| `toolchain`         | Compiler/toolchain used by the project, such as GCC ARM, ARMClang, Keil, or IAR. |
| `flash_command`     | Command or script used to flash firmware to the target board. |
| `firmware_path`     | Path to the generated firmware file, such as `.elf`, `.bin`, or `.hex`. |
| `serial_port`       | Serial port used for runtime logs, such as `COM3`, `/dev/ttyUSB0`, or `/dev/ttyACM0`. |
| `baudrate`          | Serial baud rate, usually `115200`.                          |
| `test_commands`     | Commands to send through FinSH/MSH or the serial console.    |
| `expected_behavior` | Expected startup logs, debug output, device behavior, or test result. |
| `constraints`       | Restrictions such as minimal changes, no flashing, protected files, or unavailable hardware. |

## Workflow

### Workflow Principle

The agent must not stop at code generation unless hardware access, flashing details, or serial access are unavailable and this limitation is explicitly reported.

For RT-Thread embedded projects, the agent should follow the real embedded engineering loop:

analyze → modify → build → fix → flash → serial test → runtime debug → iterate

Every meaningful code or configuration change should be verified by building the project.  
Firmware flashing should only be performed after the build succeeds.  
Serial testing should be used to verify runtime behavior when hardware and serial access are available.

If hardware, flash tools, or serial access are unavailable, the agent should still complete code analysis, modification, and build verification, then clearly report which hardware verification steps could not be performed.

### Mandatory Execution Gates

After this skill is loaded, follow these gates in order. Do not skip ahead silently.

### Execution Environment Rule

When running in a sandboxed agent environment, run build, flash, and serial helper scripts outside the sandbox by default, or request the required outside-sandbox permission before executing them.

This applies to:

- `scripts/Build_powershell.ps1`
- `scripts/FlashMCU_powershell.ps1`
- `scripts/FlashSTLink_powershell.ps1`
- `scripts/FlashJLink_powershell.ps1`
- `scripts/Open_serial_msh.py`

Reason: these steps may write generated files outside the current workspace, invoke externally installed toolchains, access USB debug probes, access COM ports, or use temporary directories controlled by vendor tools. If one of these commands fails inside a sandbox with permission, path, USB, serial-port, temporary-file, or runtime-extraction errors, treat it as an execution-environment limitation first. Retry outside the sandbox before diagnosing project source code, board wiring, firmware, or hardware.

Keep a running gate state while working:

```text
Build gate: pending
Flash gate: pending
Serial gate: pending
Runtime conclusion: not verified
```

Update the state after each gate. A gate may be `passed`, `failed`, `skipped`, or `blocked`, but `skipped` and `blocked` require a concrete reason.

1. Read the task, inspect the project, and identify the build, flash, and serial verification path before editing.
2. After edits, run `scripts/Build_powershell.ps1` when this skill is available and a build command can be determined. This is the single standard build entry. By default the script performs a stable rebuild by safely deleting generated artifacts inside the build directory, then running the build command. Do not run raw `make`, `scons`, `cmake --build`, or Makefile `clean` first unless the script is missing, cannot run after one focused repair attempt, or the user explicitly requested a raw command.
3. If a manual build command is used as a fallback, state that it is a fallback, capture the command/output, and explain why the skill build script was not used.
4. Treat build success as only the build gate. Do not report the task as complete for runtime or hardware behavior until flash and serial gates are also passed, or explicitly report them as skipped or blocked with evidence.
5. Before flashing, confirm the programmer/debugger type, firmware path, target MCU, exact flashing tool, and exact flashing target name accepted by that tool.
6. After flashing, open serial, send `reboot` when MSH/FinSH is available, collect logs, and run any task-specific shell commands needed for evidence.
7. In the final report, label each gate as passed, failed, skipped, or blocked and include the reason for any gate that did not pass.

### Post-Build Continuation Rule

A successful build is not a stopping point. After any successful build, continue to the flash gate unless one of these conditions is true:

- The user explicitly requested build-only or no hardware action.
- The build did not generate a usable firmware file.
- The programmer/debugger type, target name, firmware path, or flash tool cannot be confirmed after inspecting user input, project settings, logs, scripts, and connected-tool evidence.
- Flashing is unsafe or requires a dangerous operation such as mass erase, option-byte modification, read-protection changes, or bootloader overwrite.

If flashing cannot proceed, do not present the task as complete. Mark `Flash gate: blocked` and state the exact missing or unsafe item. If flashing succeeds, continue to the serial gate unless serial access is explicitly unavailable or blocked by missing port/baudrate evidence.

If a helper script fails before it starts the intended project operation, treat that as a skill helper or host environment problem first. Make one focused attempt to inspect and repair the helper script or invocation, then rerun it. Use a raw fallback only after that attempt fails or is impossible, and label the fallback evidence level.

Before sending a final response, run this final-answer guard:

```text
If Build gate passed and Flash gate is not passed/failed/blocked/skipped with a concrete reason, do not stop.
If Flash gate passed and Serial gate is not passed/failed/blocked/skipped with a concrete reason, do not stop.
If the task is runtime-related and only Build gate passed, the result is not verified.
```

---

### 1. Detect RT-Thread Project

First, identify whether the current project is an RT-Thread embedded project.

Treat the project as an RT-Thread project if any of the following files or directories are found:

- `rtconfig.h`
- `.config`
- `Kconfig`
- `SConstruct`
- `SConscript`
- `rtconfig.py`
- `rtthread.h`
- `applications/`
- `board/`
- `drivers/`
- `packages/`
- `components/`

If `rtconfig.h` or `.config` exists, enable this skill by default.

---

### 2. Understand the User Task

Determine the user's real task before modifying code.

The task may involve:

- Fixing build errors
- Modifying application logic
- Adding or debugging device drivers
- Modifying RT-Thread configuration
- Debugging threads, IPC, timers, components, or packages
- Fixing runtime crashes, asserts, hard faults, or abnormal logs
- Building the project
- Flashing firmware
- Opening a serial monitor and checking debug output

Prefer minimal, targeted changes.  
Do not rewrite unrelated code or change unrelated configuration.

---

### 3. Inspect Project Structure

Before editing files, inspect the project layout and identify:

- Project root directory
- BSP directory
- Board initialization files
- Application source files
- Driver source files
- RT-Thread configuration files
- Build files
- Existing build, flash, or serial scripts

Pay special attention to files such as:

- `rtconfig.h`
- `.config`
- `rtconfig.py`
- `Kconfig`
- `SConstruct`
- `SConscript`
- `applications/main.c`
- `board/board.c`
- `drivers/drv_*.c`

---

### 4. Analyze Task Complexity and Plan Verification Steps

After reading the user task, project structure, configuration files, and relevant source code, analyze the task before editing files.

Classify the task as simple or complex:

- Simple task: one focused code or configuration change can be verified by one build, and optionally one flash or serial test.
- Complex task: the change affects multiple modules, drivers, RT-Thread configuration files, BSP behavior, hardware initialization, build scripts, flashing, or runtime behavior.

For complex tasks, split the work into small verification stages before modifying code:

1. Define the first minimal change.
2. Define the expected build result.
3. Define whether flashing is needed for that stage.
4. Define what serial log, shell output, or board behavior should be checked.
5. Apply only the current stage change.
6. Build, flash when allowed, collect logs, and analyze the result.
7. Decide the next stage based on evidence.

Do not implement all planned changes before verifying the earlier stages. Prefer gradual improvement through repeated build, flash, serial-log, and runtime checks.

---

### 5. Determine Build, Flash, and Serial Commands

Infer the build command from project files when possible.

Common build commands include:

```bash
scons
scons -j8
make
make -j12 all
make -C Debug -j12 all
cmake --build build
```

For RT-Thread Studio, Eclipse, or generated Makefile projects, prefer the existing Makefile workflow. A typical build command is `make -j12 all`, usually from the generated build directory such as `Debug/`.

In GCC ARM embedded projects, the Makefile normally invokes the ARM cross toolchain:

```bash
arm-none-eabi-gcc
arm-none-eabi-objcopy
arm-none-eabi-size
```

Treat `arm-none-eabi-gcc` output as the compiler/linker evidence, `arm-none-eabi-objcopy` output as firmware binary generation evidence, and `arm-none-eabi-size` output as Flash/RAM usage evidence.

If this skill provides scripts, use them as the primary execution path for build, flash, and serial evidence. Project-provided scripts may also be used when they are the project's canonical workflow, but record why they were selected.

If the project provides scripts, inspect and prefer them when they are the canonical project workflow:

```
./build.sh
./flash.sh
python serial_test.py
```

Do not guess safety-critical commands.

The agent must not blindly guess:

- Target MCU
- Target board
- Programmer/debugger type, such as DAPLink/CMSIS-DAP, ST-LINK, J-Link, or UART bootloader
- Flash command
- Serial port
- Baud rate

Before flashing, explicitly determine the programming/debug probe method from user input, RT-Thread Studio project settings, generated download scripts, existing logs, or connected-tool evidence.

Also determine the target name syntax accepted by the selected flashing tool. Do not assume that the MCU model string from the chip datasheet is accepted by PyOCD, STM32CubeProgrammer, or J-Link. If needed, query the tool's target list or use the exact target string from RT-Thread Studio download logs or launch settings.

Use the correct flashing path for the confirmed method:

- DAPLink / CMSIS-DAP / DAP: use RT-Thread Studio PyOCD, usually `pyocd.exe flash`.
- ST-LINK: use ST tooling such as `STM32_Programmer_CLI.exe` when available.
- J-Link: use SEGGER tooling such as `JLink.exe` and a commander script.
- UART bootloader: use the board-specific serial bootloader tool and confirmed boot mode.

If the programming method or tool-specific target name cannot be confirmed, stop before flashing and ask the user to confirm it. Do not choose PyOCD, ST-LINK, or J-Link only because the tool exists on the PC.

If serial settings cannot be inferred safely, stop before serial testing and report the missing information.

------

### 6. Modify Code or Configuration

Modify only the files required by the user's task.

When working with RT-Thread code:

- Use standard RT-Thread APIs when possible
- Keep the existing project style
- Prefer small and focused changes
- Avoid changing startup files unless necessary
- Avoid changing linker scripts unless necessary
- Avoid changing clock configuration unless necessary
- Avoid changing board pin mappings unless necessary
- Avoid manually editing generated configuration files without understanding the configuration flow

Common RT-Thread APIs include:

```
rt_kprintf();
rt_thread_create();
rt_thread_startup();
rt_device_find();
rt_device_open();
rt_device_read();
rt_device_write();
rt_pin_mode();
rt_pin_write();
rt_sem_create();
rt_mutex_create();
rt_timer_create();
```

If RT-Thread configuration must be changed, keep related files consistent when possible:

- `.config`
- `rtconfig.h`
- `Kconfig`
- package configuration files

------

### 7. Build the Project

After each meaningful modification, build the project.

Capture and analyze the full compiler and linker output.

When `scripts/Build_powershell.ps1` is available, use it for the build gate so the command, output, compiler, generated firmware, warnings, errors, and log path are captured consistently.

Full rebuilds can take noticeably longer than incremental builds because RT-Thread Studio projects may compile RT-Thread, STM32 HAL, middleware, Bluetooth stacks, codecs, drivers, and applications together. Prefer the project's normal parallelism such as `make -j12 all`; only reduce parallelism when the host is unstable or the user requests it.

Use one standard build command shape:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Build_powershell.ps1 -ProjectRoot <project_root> -BuildDir Debug -BuildCommand "make -j12 all"
```

The build script is responsible for toolchain discovery, build-directory-safe artifact cleanup, invoking the Makefile build, and reporting JSON evidence. Do not manually run `make clean`, `make -B`, or raw `make` before this standard command.

After the build succeeds and a firmware file is available, immediately continue to firmware flashing according to the Post-Build Continuation Rule. Do not end the workflow with only a successful build unless the flash gate is explicitly blocked, skipped by user request, or unsafe.

For RT-Thread Studio projects, the command-line environment may not include the Studio-managed GNU Arm toolchain in `PATH`. If `arm-none-eabi-gcc`, `arm-none-eabi-objcopy`, or `arm-none-eabi-size` is missing, treat it as a build environment/toolchain PATH problem instead of a source-code error.

The agent should discover the GNU Arm toolchain automatically. `scripts/Build_powershell.ps1` searches `PATH`, RT-Thread-related environment variables, project files, `.settings`, generated Makefiles, RT-Thread Studio-style directory layouts, project-relative locations, and filesystem drives. Do not ask the user for toolchain paths as a normal step; the user usually provides only the task goal. Use `-ToolchainBinDir` or `-ToolchainSearchRoot` only as a fallback when automatic discovery fails and a concrete path is already known from local evidence or user confirmation.

Do not hard-code a local PC's RT-Thread Studio installation path into the skill or the project. Absolute toolchain paths in script output should be treated as discovered runtime evidence for the current machine.

Only add `-ToolchainBinDir <confirmed_gnu_arm_toolchain_bin>` or `-ToolchainSearchRoot <confirmed_search_root>` when automatic discovery fails and the path has been found from local evidence or user confirmation.

Only use raw commands such as `make -C Debug -j12 all` as a fallback when the script is missing, cannot run after one focused repair attempt, or the user explicitly asks for a manual command. If a fallback is used, report why and continue the same build -> flash -> serial gate sequence instead of stopping at the fallback build result.

Build evidence levels:

1. Standard stable rebuild: `scripts/Build_powershell.ps1` reports `cleanMethod: safe-clean`, `fullRebuild: true`, and a successful build. This is the preferred build gate evidence.
2. Forced rebuild fallback: raw Makefile build uses a confirmed toolchain and `make -B` or an equivalent force-rebuild option, then regenerates `.elf`, `.bin`, and size output. This can pass the build gate when the skill build script cannot run, but it must be reported as `fallback forced rebuild`, not as a clean full rebuild.
3. Incremental fallback: raw Makefile build without clean or force rebuild. This is only diagnostic evidence that the current dependency graph can compile/link; do not use it as final build gate evidence unless the user explicitly asked for a quick incremental check.

When the project uses a generated Makefile, record both the top-level build command and the underlying toolchain commands. For example, `make -j12 all` may compile and link through `arm-none-eabi-gcc`, generate `rtthread.bin` through `arm-none-eabi-objcopy`, and report memory usage through `arm-none-eabi-size`.

Analyze errors in this order:

1. First real compiler error
2. Missing header file
3. Missing source file
4. Undefined symbol
5. Type mismatch
6. Macro or configuration problem
7. Linker error
8. Memory overflow
9. Warnings that may affect runtime behavior

If the first failure is a missing tool such as `arm-none-eabi-gcc`, `arm-none-eabi-objcopy`, or `arm-none-eabi-size`, fix or report the toolchain PATH first. Do not modify project source code for a missing host-side compiler/toolchain executable.

If a linker error appears only after switching GNU Arm toolchain versions, especially symbols such as `__locale_ctype_ptr`, suspect a toolchain/newlib/object-file mismatch before changing source code. Prefer returning to the project's known-good RT-Thread Studio GNU Arm version and perform a standard stable rebuild through `Build_powershell.ps1`. If the helper script cannot run, use `make -B` only as a forced rebuild fallback and label it that way.

On Windows, generated Makefile `clean` rules may fail silently when they pass a very long file list to `rm -rf`; GNU Make may print errors such as `Error 87 (ignored)` because the clean recipe is prefixed with `-`. The standard build path avoids this by using the build script's internal safe clean directly instead of Makefile `clean`. Check `cleanMethod`, `cleanSuccess`, `cleanRemainingObjectCount`, `cleanRemainingDependencyCount`, `cleanRemainingOutputCount`, and `fullRebuild` before claiming a standard stable rebuild. Use `-UseMakeClean` only for diagnosing Makefile clean behavior, not as the normal build gate.

If `scripts/Build_powershell.ps1` fails before invoking the project build because of a script/runtime error, such as a PowerShell regex error, treat it as a skill helper script problem rather than a project source error. Inspect or fix the helper script and rerun it before falling back to raw `make`; if a raw build is used, report that it is only a fallback. Do not let a helper script failure downgrade the whole workflow to "build only" when flash and serial gates are otherwise available.

Do not blindly fix later errors before understanding the first meaningful error.

------

### 8. Fix Build Errors Iteratively

If the build fails:

1. Identify the root cause.
2. Modify the smallest necessary part.
3. Rebuild the project.
4. Check whether the error is resolved.
5. Repeat until the build succeeds or a clear blocking issue is identified.

When reporting a blocking issue, include:

- Exact error message
- Related file and line number
- Suspected cause
- What was already checked
- What information is still missing

------

### 9. Flash Firmware After Successful Build

Only flash firmware after the project builds successfully.

Build success creates a transition into the flash gate, not a final completion state. If the user asked for integrated debugging, board validation, runtime behavior, driver debugging, or hardware verification, the agent should attempt flashing after confirming the flashing method and target details from evidence.

Before flashing, confirm or safely infer:

- Firmware file path
- Target board
- Target MCU
- Tool-specific target name accepted by the selected flashing tool
- Programmer/debugger type
- Flash command
- Whether flashing is allowed

Select the flashing command only after the programmer/debugger type is confirmed. For example, use `pyocd.exe flash` for DAPLink/CMSIS-DAP/DAP, not for ST-LINK or J-Link unless the project explicitly routes those probes through PyOCD.

Flashing is a hardware USB/debug-probe operation. Follow the Execution Environment Rule: execute flashing outside the sandbox by default or request the required outside-sandbox permission before running the flash script. If a flash command fails inside a sandbox with permission, extraction, USB, probe-access, or temporary-file errors, treat it as an execution-environment limitation first; retry outside the sandbox before diagnosing the target board, firmware, or wiring.

For PyOCD, verify the target string accepted by that PyOCD installation before calling `scripts/FlashMCU_powershell.ps1`. If PyOCD reports that the target type is not recognized, do not retry blindly. Query available targets, inspect RT-Thread Studio logs/settings, or ask the user for the exact target name.

For RT-Thread Studio PyOCD packages, run PyOCD from the directory that contains `pyocd.exe` unless a project log proves another working directory. Some packaged PyOCD builds load their local `pyocd.yaml`, packs, or runtime files relative to that directory; running the same executable from the project directory may cause valid targets such as `STM32F407VG` to appear unrecognized. If PyOCD fails with runtime extraction messages such as `VCRUNTIME140.dll could not be extracted` or `fopen: Permission denied`, treat it as a host permission/sandbox/runtime extraction problem before diagnosing the board.

Do not perform dangerous flash operations unless explicitly requested by the user.

Avoid operations such as:

- Mass erase
- Unlocking read protection
- Modifying option bytes
- Overwriting bootloader
- Changing flash protection settings

------

### 10. Open Serial Monitor and Collect Logs

After flashing, open the configured serial port and collect runtime logs.

Flash success creates a transition into the serial gate, not a final completion state. If serial settings can be confirmed from project configuration, RT-Thread console settings, connected port evidence, user input, or previous successful logs, open the serial monitor and collect runtime evidence before reporting the task as verified.

When MSH/FinSH is available, first send `reboot` after opening the serial terminal, then collect the complete reboot startup log. This verifies both command input from PC to MCU and runtime output from MCU to PC, and usually gives a cleaner RT-Thread banner and initialization sequence for analysis.

After the reboot log is collected and the shell prompt is available, use custom MSH/FinSH shell commands when they help debug the current task. Prefer commands provided by the user or commands discovered from the project, such as device, thread, memory, driver, or application-specific debug commands. Record each command, its echo, and its output as runtime evidence.

Check for:

- RT-Thread startup banner
- Kernel version
- `msh >` prompt
- Device initialization logs
- Application debug output
- FinSH/MSH shell output
- Assert messages
- Hard fault logs
- Watchdog reset logs
- Reboot loops
- Missing output
- Abnormal output

If test commands are provided, send them through the serial console and observe the result. When using `scripts/Open_serial_msh.py`, pass repeated `--command` arguments to run multiple custom shell commands in order.

Example:

```powershell
python scripts/Open_serial_msh.py --port COM19 --baudrate 115200 --read-seconds 2 --command reboot --after-command-seconds 5 --log-path serial-reboot.log
```

Use `--after-command-seconds` to control how long to read after each command. Do not invent unsupported options such as `--command-read-seconds`; inspect `--help` or the script source when unsure.

On Windows, serial logs may contain invalid UTF-8 bytes or replacement characters before the RT-Thread banner. Do not treat a console encoding error such as `gbk codec can't encode character` as a serial-open failure if the log file was written. Use `Open_serial_msh.py`, which emits ASCII-safe JSON, or run Python with UTF-8 console output, then analyze the saved UTF-8 log file.

------

### 11. Analyze Runtime Behavior

Compare serial logs and board behavior with the expected result.

If runtime validation requires physical user assistance, tell the user immediately and give one concrete action at a time. Do not wait until the final report.

Examples of user-assisted actions:

- press or long-press a board key
- press reset
- power-cycle the board
- reconnect SWD, USB, UART, audio, sensor, or other cables
- change BOOT pin or jumper state
- pair or connect a Bluetooth device
- play audio or provide an external signal
- observe LED, display, motor, speaker, or other external behavior

When asking for assistance, state:

- what action the user should perform
- when to perform it
- what output or behavior you are watching for
- whether the agent will keep monitoring logs afterward

Possible runtime issue causes include:

- Application logic error
- Device not found
- Driver initialization failure
- Wrong pin configuration
- Wrong clock configuration
- Missing RT-Thread component
- Stack overflow
- Thread priority problem
- IPC deadlock
- Timer error
- Memory allocation failure
- Interrupt problem
- DMA problem
- Hardware connection problem

Use build output, serial logs, and observed behavior as evidence.
Do not guess without evidence.

------

### 12. Iterate Build, Flash, and Runtime Verification

If the runtime behavior is incorrect:

1. Analyze the serial log or observed behavior.
2. Modify code or configuration.
3. Rebuild the project.
4. Flash the firmware again.
5. Reopen the serial monitor.
6. Verify the behavior again.

Repeat this loop until one of the following conditions is met:

- The expected behavior is verified
- The bug is fixed
- The build cannot continue because of a clear blocking issue
- Flashing or serial testing is blocked by missing hardware/tool information
- The user-provided requirement is incomplete

------

### 13. Report Final Result

At the end of the workflow, report clearly:

- Modified files
- Main changes made
- Build command used
- Build result
- Flash command used, if flashing was performed
- Flash result, if available
- Serial port and baud rate used, if serial testing was performed
- Important serial logs
- Runtime verification result
- Remaining issues or risks
- Suggested next step if the issue is not fully solved

Use a gate report when the task involved code changes or hardware verification:

```text
Build gate: passed/failed/skipped/blocked
Flash gate: passed/failed/skipped/blocked
Serial gate: passed/failed/skipped/blocked
Runtime conclusion: verified/not verified
```

## Scripts

This skill provides helper scripts for build, flash, and serial evidence. Use them as the standard execution path unless the script is missing, fails after one focused repair attempt, or the user explicitly requests a raw command.

| Script                              | Purpose                                                      |
| ----------------------------------- | ------------------------------------------------------------ |
| `scripts/Build_powershell.ps1`      | Standard build entry. Discovers GNU Arm toolchains, safe-cleans generated artifacts, runs the build command, and captures compiler/linker evidence. |
| `scripts/FlashMCU_powershell.ps1`   | Flash firmware through DAPLink/CMSIS-DAP/DAP using PyOCD. Requires a confirmed PyOCD `-Target` value. |
| `scripts/FlashSTLink_powershell.ps1` | Flash firmware through ST-LINK using `STM32_Programmer_CLI.exe`. |
| `scripts/FlashJLink_powershell.ps1` | Flash firmware through J-Link using `JLink.exe` and a generated commander script. Requires a confirmed J-Link `-Device` value. |
| `scripts/Open_serial_msh.py`        | Open the serial port, read RT-Thread runtime logs, and optionally send FinSH/MSH commands. |

Script rules:

- Run build, flash, and serial helper scripts outside the sandbox by default, or request outside-sandbox permission before running them.
- After modifying code or configuration, run `Build_powershell.ps1` when a build command is available. Do not run raw `make`, `scons`, or `cmake --build` first unless using a stated fallback.
- If a raw build is used, report why and label the evidence as `fallback forced rebuild` or `incremental fallback`.
- Do not continue flash or runtime verification after a failed build.
- After a successful build, continue to flash and serial verification when those gates are available; do not stop at build success.
- Confirm programmer/debugger type and tool-specific target name before choosing a flash script. Use PyOCD only for DAPLink/CMSIS-DAP/DAP, STM32CubeProgrammer only for ST-LINK, and J-Link tools only for J-Link.
- Do not choose a flash script only because its tool exists on the PC.
- Do not guess serial port or baud rate. If serial access is unavailable, mark the serial gate as blocked or skipped with the reason.
- For `Open_serial_msh.py`, use repeated `--command` arguments and `--after-command-seconds`; inspect script help instead of inventing options.
- If runtime validation needs physical user assistance, ask immediately with one concrete action and expected observation.
- Helper scripts keep only the newest 10 matching logs by default. Build logs use `rt-thread-build-*.log`, DAP/PyOCD flash logs use `rt-thread-flash-*.log`, ST-LINK flash logs use `rt-thread-stlink-flash-*.log`, J-Link flash logs use `rt-thread-jlink-flash-*.log`, and serial logs use `rt-thread-serial-*.log`. Use `-KeepLogs` or `--keep-logs` only when a different retention count is needed.
- Capture and analyze script JSON output and log files as evidence.
- Prefer project-provided build commands when available. If the project uses `SConstruct`, the default build command is usually `scons -j8`.

## References

- `references/rt-thread-studio-make-build-log.md`
  - Read when analyzing RT-Thread Studio, Eclipse-generated Makefile, or ARM GCC build logs that contain `make`, `arm-none-eabi-gcc`, `arm-none-eabi-objcopy`, or `arm-none-eabi-size` output.
- `references/rt-thread-studio-pyocd-flash-log.md`
  - Read when analyzing RT-Thread Studio PyOCD flashing logs that contain `pyocd.exe flash`, `STM32F407VG`, `rtthread.bin`, `Unexpected ACK value`, `TransferError`, erased bytes, or programmed bytes.
- `references/rt-thread-serial-success-log.md`
  - Read when verifying runtime behavior through serial logs, RT-Thread startup banners, MSH prompts, or reboot-command validation.

## Output style

Use concise engineering reports supported by concrete evidence. Include:

- Task understanding and change scope.
- Modified files and main changes.
- Build evidence level, clean method/result, build command, visible compiler/linker evidence, pass/fail result, and first meaningful error if failed.
- Flash command and result when flashing was performed or attempted.
- Serial port, baud rate, key logs, shell output, or observed board behavior when available.
- Gate report:

```text
Build gate: passed/failed/skipped/blocked
Flash gate: passed/failed/skipped/blocked
Serial gate: passed/failed/skipped/blocked
Runtime conclusion: verified/not verified
```

Do not say the problem is fixed unless the relevant build, flash, serial, and runtime checks have passed, or every unverified gate is explicitly marked with a concrete reason. Log files are supporting evidence; summarize the key result and mention log paths briefly, especially for failures.

## Quality checks

Before delivering, verify that:

- The RT-Thread project was identified from project evidence such as `rtconfig.h`, `.config`, `Kconfig`, `SConstruct`, `SConscript`, `rtthread.h`, or BSP structure.
- The user task, relevant project structure, configuration, source files, and existing scripts were inspected before editing.
- Complex tasks were split into small verification stages.
- Changes were minimal and limited to the user's task.
- RT-Thread APIs, macros, device names, component settings, and related config files were checked against local evidence or reliable documentation instead of guessed.
- Meaningful code or configuration changes were followed by a full build when possible, or the report labels the build fallback level and reason.
- Build failures were analyzed from the first meaningful compiler or linker error.
- Firmware was flashed only after build success and confirmed flash details.
- Runtime conclusions were based on build output, serial logs, shell output, board behavior, or user-confirmed observations.
- Dangerous flash operations were not performed without explicit user confirmation.
- All unverified gates and remaining risks were reported honestly.

## Do not

- Do not make broad one-shot changes when a smaller targeted change can solve the current problem.
- Do not rewrite unrelated application logic, BSP code, driver code, startup files, linker scripts, clock configuration, or pin mappings unless required by evidence.
- Do not skip build verification after meaningful code or configuration changes.
- Do not present raw incremental builds as full build gate evidence or call `make -B` a clean full rebuild.
- Do not flash firmware before the project builds successfully.
- Do not end after a successful build when flash and serial gates are available or can be confirmed from evidence.
- Do not repeatedly flash blindly. Each attempt needs a purpose, expected observation, and follow-up decision.
- Do not use default script parameters as facts. Confirm project root, build directory, toolchain, firmware path, MCU, programmer type, flash target name, serial port, and baud rate from evidence or user input.
- Do not guess RT-Thread APIs, configuration macros, device names, serial ports, baud rates, target boards, MCU models, programmer/debugger type, or flash commands.
- Do not perform mass erase, option-byte modification, read-protection changes, bootloader overwrite, or flash protection changes unless the user explicitly requests and confirms them.
- Do not claim runtime issues are fixed only because the code compiles.
- Do not hide verification limits.

