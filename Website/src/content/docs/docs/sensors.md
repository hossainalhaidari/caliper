---
title: Sensors and metrics
description: Every reading Caliper can show, its metric id, which ones are portable between Macs, and where the private ones come from.
---

A **metric** is one reading, named by an id such as `cpu.usage.total`. Ids are what widget files are
written in, so they never change. To see every metric *this* Mac offers, with a live value:

```bash
make sensors
```

The editor's metric picker lists the same set, grouped the same way — only what this Mac actually
has.

## Portable and machine-specific

Most ids mean the same thing on every Mac. A few are specific to one machine — a volume by its name,
an interface by its BSD name, a raw temperature sensor — and are marked *machine-specific* below. They
work fine in your own widgets; in one meant for others, prefer the portable spelling. The import sheet
warns about them either way.

## Processor

| Metric | |
|---|---|
| `cpu.usage.total` | Total load, % |
| `cpu.usage.user`, `cpu.usage.system` | User and system time, % |
| `cpu.cluster.efficiency.usage`, `cpu.cluster.performance.usage` | Load per cluster, % |
| `cpu.core.<n>.usage` | One core, %. Numbered efficiency cores first, as macOS numbers them |

The **Core Matrix** style draws every core at once, grouped by cluster.

## Memory

| Metric | |
|---|---|
| `memory.usage.percent` | Used, % |
| `memory.used.bytes`, `memory.free.bytes` | Used and free |
| `memory.app.bytes`, `memory.wired.bytes`, `memory.compressed.bytes`, `memory.cached.bytes` | What "used" is made of |
| `memory.swap.used.bytes`, `memory.swap.total.bytes` | Swap |
| `memory.pressure` | The kernel's memory pressure: 0 normal, 1 warning, 2 critical |

## Disk

| Metric | |
|---|---|
| `disk.boot.usage.percent` | The startup disk, % full |
| `disk.boot.free.bytes`, `disk.boot.used.bytes`, `disk.boot.total.bytes` | The same, in bytes |
| `disk.volume.<name>.usage.percent`, `disk.volume.<name>.free.bytes` | Any other volume — *machine-specific* |
| `disk.io.read.rate`, `disk.io.write.rate` | Disk activity, per second |
| `disk.io.session.read.bytes`, `disk.io.session.written.bytes` | Since Caliper started |

`disk.boot.*` always means the startup disk, whatever it is called.

## Network

| Metric | |
|---|---|
| `net.throughput.down`, `net.throughput.up` | All interfaces, per second |
| `net.session.received.bytes`, `net.session.sent.bytes` | Since Caliper started |
| `net.if.<interface>.throughput.down` / `.up` | One interface, such as `en0` — *machine-specific* |

## Graphics

| Metric | |
|---|---|
| `gpu.utilization` | GPU load, % |
| `gpu.renderer.utilization`, `gpu.tiler.utilization` | Its renderer and tiler stages, % |
| `gpu.memory.inuse.bytes`, `gpu.memory.allocated.bytes` | GPU memory |

## Temperature

| Metric | |
|---|---|
| `thermal.peak` | The hottest sensor |
| `thermal.average` | The average across real sensors |
| `thermal.battery` | The battery |
| `thermal.storage` | The SSD |
| `thermal.sensor.<name>` | Every individual sensor, in an *Advanced* group — *machine-specific* |

An M4 publishes 47 thermal sensors and **not one has a meaningful name**: `PMU tdie1` to `tdie14`,
`PMU2 tdev1` to `5`, `NAND CH0 temp`, six all called `gas gauge battery`. There is no "CPU" sensor to
find. So the four `thermal.*` aggregates are what a widget should normally use, and every raw sensor
is still there for anyone who wants it.

The aggregates leave out what is not a measurement: sensors that report about −22 °C (unpopulated
channels) and the `tcal` calibration references, which sit at a constant 51.82 °C and would otherwise
pin the peak.

## Fans

| Metric | |
|---|---|
| `fan.peak.rpm` | The fastest fan |
| `fan.<n>.rpm` | Each fan |
| `fan.count` | How many there are |

A fanless Mac, such as a MacBook Air, offers none of these.

## Power

| Metric | |
|---|---|
| `power.total.watts` | The whole chip |
| `power.cpu.watts`, `power.gpu.watts`, `power.ane.watts`, `power.dram.watts` | Processor, graphics, Neural Engine and memory |

## Battery

| Metric | |
|---|---|
| `battery.charge.percent` | Charge |
| `battery.charging` | 1 while charging, 0 otherwise |
| `battery.time.remaining.seconds` | Time remaining, as macOS estimates it; absent while it is still calculating |
| `battery.power.watts` | Power in or out, as a magnitude; `battery.charging` says which |
| `battery.health.percent`, `battery.cycles` | Health and cycle count |

## Time

| Metric | |
|---|---|
| `time.epoch` | The time — shown as a [clock](../clock/) |
| `system.uptime.seconds` | Time since the Mac started |

## Where the private ones come from

Temperatures, fans and power need more than public API, which is why Caliper cannot be on the App
Store:

| Readings | Interface | |
|---|---|---|
| GPU | the `IOAccelerator` registry property | Ordinary IOKit |
| Temperatures | `IOHIDEventSystemClient` | Private |
| Power | `IOReport` | Private |
| Battery | `IOPowerSources` and the registry | Public |
| Fans | the `AppleSMC` key table | Private, **read-only** |

Each of these sources **probes for its interface when Caliper starts**, and offers no metrics at all
when it is missing. A macOS update that moves one of them removes those readings from the picker; it
never fills your menu bar with permanent dashes.

The SMC is read and never written. Only the read commands are implemented — writing SMC keys can drive
fans past their rated speed or stop them, and no menu bar app has any business doing that.

A sensor that is missing or reads wrong after a macOS update is exactly what the
[sensor issue template](https://github.com/hossainalhaidari/caliper/issues/new/choose) is for. Include
the output of `make sensors`.
