# RT-Thread Serial Success Log Reference

Use this reference when verifying RT-Thread runtime behavior through a serial terminal, FinSH, or MSH.

## Successful Startup Banner

A normal RT-Thread startup log commonly contains the RT-Thread banner:

```text
 \ | /
- RT -     Thread Operating System
 / | \     4.1.1 build Apr 27 2026 12:22:18
 2006 - 2022 Copyright by RT-Thread team
```

The exact version and build time may differ between projects. Treat the banner as evidence that:

- the MCU is running the flashed firmware
- the RT-Thread kernel started
- the serial baud rate is likely correct
- the serial RX path is working from MCU to PC

## MSH Prompt

For FinSH/MSH-enabled projects, a successful shell prompt may look like:

```text
msh >
```

Treat `msh >` as evidence that the RT-Thread shell is alive and ready to receive commands.

## Reboot Verification Pattern

After a successful flash, open the serial port and send:

```text
reboot
```

Then collect the startup log again. This helps verify both directions of the serial link:

- PC to MCU: the `reboot` command is accepted by MSH
- MCU to PC: the reboot banner and startup logs are received

The preferred evidence sequence is:

```text
reboot
<RT-Thread startup banner>
msh >
<application initialization logs>
```

If `reboot` does not work, do not assume the firmware is broken immediately. Check whether MSH is enabled, whether the shell prompt is active, and whether the serial newline setting should be CRLF, LF, or CR.

## Failure Signals

During serial verification, watch for:

- missing startup banner
- garbled text, usually baud rate mismatch
- no `msh >` prompt when MSH is expected
- `assert`
- `hard fault` or `hardfault`
- repeated reboot loops
- device or driver initialization failures

Report these as runtime evidence instead of guessing from code alone.
