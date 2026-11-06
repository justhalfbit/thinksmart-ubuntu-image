# ThinkSmart View 语音终端系统镜像

中文 | [English](README.en.md)

把联想 **ThinkSmart View（型号 CD-18781Y）** 刷成一台本地语音助手：开机直接进语音界面，说「小麦小麦」唤醒，背后可以接 Claude、DeepSeek 等多种大模型。

镜像基于 [rickx/ubuntu-thinksmart](https://github.com/rickx/ubuntu-thinksmart)（Ubuntu 24.04 + postmarketOS 内核 6.19），去掉了 Plasma 桌面，预装：

- 语音客户端 [xiaozhi-thinksmart-client](https://github.com/justhalfbit/xiaozhi-thinksmart-client)：唤醒、对话界面、睡眠时段、亮度、在线更新；
- 小智网关 [xiaozhi-hub-server](https://github.com/justhalfbit/xiaozhi-hub-server)：本机语音识别，接各家大模型和语音合成，带网页管理后台；
- 设备修复：两颗麦克风、扬声器、屏幕熄屏和接近唤醒、WiFi 稳定性、GPU 白屏/卡死补丁等；
- 前置摄像头：作为普通摄像头 `/dev/video10` 使用，浏览器、视频会议软件可以直接选它，也能用 libcamera 拍照（最高 2600×1960）。

目前界面和唤醒词都是中文。

> ⚠️ 刷机会清掉原来的 Teams / Android 系统。第一次刷之前**一定先整盘备份 eMMC**（[A2](#a2-整盘备份原厂-emmc必做)），这是以后回到原厂的唯一办法。

本文就是完整的刷机教程，写成了人和 AI 助手都能照着一步步做的样子。

---

## 目录

- [给 AI 助手的说明（先读这一节）](#给-ai-助手的说明先读这一节)
- [0. 准备](#0-准备)
- [1. 进入 EDL 模式，判断走哪条路线](#1-进入-edl-模式判断走哪条路线)
- [路线 A：第一次刷（设备还是原厂系统）](#路线-a第一次刷设备还是原厂系统)
- [路线 B：已经刷过本镜像或上游 Ubuntu 镜像](#路线-b已经刷过本镜像或上游-ubuntu-镜像)
- [2. 首次开机和设置](#2-首次开机和设置)
- [3. 常见问题排查](#3-常见问题排查)
- [4. 备份和还原用户数据](#4-备份和还原用户数据)
- [5. 以后的更新](#5-以后的更新)
- [附录：分区和镜像结构](#附录分区和镜像结构)
- [致谢和声明](#致谢和声明)

---

## 给 AI 助手的说明（先读这一节）

如果你是被用户叫来帮忙刷机的 AI 助手（Agent），请先读完这一节，再从第 0 步开始。

### 目标

把本仓库 Release 里的镜像写进用户这台 ThinkSmart View 的 `system` 分区，让它开机进入语音助手界面，然后陪用户完成首次设置（WiFi、网关管理员密码、API Key、改默认密码）。

### 整体流程

```
第 0 步  准备：确认型号 → 装 edl → 下载并校验文件
第 1 步  进 EDL 模式 → edl printgpt → 按 system 分区大小选路线
  路线 A（原厂系统）：整盘备份 → 刷 lk2nd 到 boot → 刷 bootstrap 到 system → 开机
                      → SSH 进 bootstrap 改分区表 → 关机 → 再进 EDL → 刷本镜像到 system
  路线 B（刷过 Ubuntu）：（可选）备份用户数据 → 进 EDL → 刷本镜像到 system
第 2 步  首次开机：屏幕配 WiFi → 找 IP → 网关后台设密码、填 API Key → 改两个账号的密码 → 试语音
```

### 必须先停下来、得到用户明确同意才能做的操作

下面每一项都不可逆，或者会清掉数据。执行前把**要执行的完整命令**和**后果**告诉用户，等用户明确回答「同意 / 可以 / 执行」之类的话再做。一次同意只管这一步，下一步要重新问。

| 步骤 | 操作 | 后果 |
| --- | --- | --- |
| A2 | 整盘备份时，目标文件已经存在 | 覆盖旧备份，旧备份就没了。默认换个文件名，不要覆盖 |
| A3 | `edl w boot lk2nd.img` | 原厂 bootloader 链被换成 lk2nd，Android/Teams 从此起不来 |
| A4 | `edl w system bootstrap…img` | 原厂 `system` 分区被覆盖 |
| A6 | 在 bootstrap 里运行 `apply-ubuntu-gpt.sh` | 改写整张分区表，原厂的 vendor、cache、userdata 等分区被删掉 |
| A8 / B3 | `edl w system thinksmart-ubuntu-…img` | `system` 分区原有内容全部被覆盖（包括旧系统里的聊天记录、API Key、WiFi 配置） |
| — | 任何 `edl wf`（整盘写回） | 整个 eMMC 被覆盖。只有用户明确要求回原厂时才用 |

另外两种情况也要停下来问：

- 任何一步的输出和本文写的「期望输出」对不上；
- 同一条写入命令失败了一次。可以说明情况后建议重试一次，再失败就停下来，别反复重试。

### 需要用户本人动手的操作

AI 助手做不了这些，到这一步要明确告诉用户做什么，等用户说「好了」再继续：

- 插拔 USB 线和电源线、换线、换电脑上的 USB 口；
- 按键组合进 EDL 模式（拔电源线 → 插 USB 线 → 按住音量 + 和音量 − → 插电源线 → 3～5 秒后松开音量键，见 1.1）；
- 关机和开机：这台设备**没有电源键**，插上电源线就开机。系统开着时要先关机再拔电：在语音界面的设置页最底下点「关机」，或者 SSH 运行 `sudo systemctl halt`，屏幕变黑后等 10 秒再拔（黑屏后系统还要几秒才收尾）。拔掉后要等 30 秒左右再插上才会开机，马上插回去可能开不了机。「关机」按钮从客户端 0.1.2 起才有，镜像自带的是 0.1.0，先在设置页「软件更新」里更新。不要用 `sudo poweroff`：插着电时它会马上重新开机。关不了机（比如停在紧急模式、lk2nd 界面）才直接拔；
- 看设备屏幕，告诉你上面显示什么（黑屏、lk2nd 界面、欢迎页、语音界面……）；
- 在设备触摸屏上选 WiFi、输入 WiFi 密码；
- 在浏览器里打开网关管理后台，设置管理员密码、填 API Key；
- 对着设备说「小麦小麦」，确认语音能用；
- macOS 弹出「允许配件连接？」时点「允许」，Windows 弹出 UAC 时点「是」。

### 绝对不能自作主张做的事

- 不能用 `edl w` 写 `boot`、`system` 以外的任何分区；不能用 `edl e`（擦除）、`edl wl`、`edl qfp` 等批量写入命令。
- 不能用 fastboot 刷写或擦除：`fastboot flash`、`fastboot erase`、`fastboot oem unlock` 都不要用。这台机器的 bootloader 是锁的，fastboot 写不进去，乱试只会出问题。
- 不能在已经改过分区表的设备上再运行 `apply-ubuntu-gpt.sh`，也不能自己对 `/dev/mmcblk0` 运行 `sfdisk`、`dd`、`parted`。
- 不能删除、移动、覆盖原厂整盘备份 `stock-full-emmc.bin`，也不能把它上传到任何地方。里面有这台设备独有的数据（序列号、校准数据、原厂系统里的账号信息）。
- 不能把用户的 WiFi 密码、API Key、设备密码写进日志、提交到仓库，或发给任何第三方服务。
- 不能修改下载来的镜像文件。校验和对不上就重新下载。
- 写入过程中不要叫用户拔线或断电。

### 执行约定

- 每一步先执行「命令」，再对照「期望输出」和「怎么判断成功」。对上了才进下一步；对不上就看「失败了怎么办」，还解决不了就停下来问用户。
- 把每条 `edl` 命令的完整输出保存下来（`2>&1 | tee 日志文件`），出问题时给用户看。
- 设备的 IP **自己找，不要问用户**：先从本机 IP 算出网段，用 `nmap -p 22,16688 --open <网段，比如 192.168.1.0/24>` 扫局域网，再打开 `http://<IP>:16688/admin` 确认标题是「小智 Hub 管理后台」。具体命令和没有 nmap 时的办法见[2.3](#23-找到设备的-ip)。
- 本文的命令默认在 macOS / Linux 的终端里运行。Windows 用 PowerShell，按 [0.2 Windows](#windows-1011未实测) 设好 `edl` 之后，`edl` 命令照抄；其他命令换成下表的写法：

  | macOS / Linux | Windows PowerShell |
  | --- | --- |
  | `shasum -a 256 文件` | `Get-FileHash 文件 -Algorithm SHA256` |
  | `ls -l 文件` | `(Get-Item 文件).Length` |
  | `grep 内容 文件` | `Select-String 内容 文件` |
  | `python3` | `python` |
  | `ping -c 3 地址` | `ping -n 3 地址` |
  | `xz -dk 文件.xz` | 用 7-Zip 解压 |
  | `… 2>&1 \| tee 日志` | 照抄（PowerShell 里 `tee` 就是 `Tee-Object`） |

- Windows 部分本项目**没有实测**，是按 edl 和上游的资料写的，标着「Windows 未实测」。遇到对不上的情况，最省事的办法是换一台 macOS 或 Linux 电脑来刷。
- 用户已经刷过本镜像，只是想升级？直接看[路线 B](#路线-b已经刷过本镜像或上游-ubuntu-镜像)，但仍要先做第 0、1 步。

---

## 0. 准备

### 0.1 确认设备型号

只支持 **Lenovo ThinkSmart View CD-18781Y**：8 英寸竖屏，高通 APQ8053，2 GB 内存，8 GB eMMC。

- 看设备背面或底部的标签，型号写的是 **CD-18781Y**。
- 进 EDL 后（第 1 步）`edl printgpt` 的输出里会有 `CPU detected: "APQ8053"` 和 `total_blocks:15269888`，这两项对不上就**不是这台机器，停止**。
- 型号不是 CD-18781Y 的机器（包括 ThinkSmart View Plus）没有测过，不要刷。

### 0.2 电脑和工具

需要：

- 一台 macOS、Linux 或 Windows 电脑，**剩余空间 20 GB 以上**（原厂整盘备份约 7.3 GB，bootstrap 镜像约 1 GB，本镜像压缩包约 0.7 GB、解压后约 3.5 GB）；
- 一根**能传数据**的 USB 线（设备端是 USB-C）。最好直接插电脑本体的口，别经过扩展坞或 USB Hub；
- [bkerler/edl](https://github.com/bkerler/edl)：高通 EDL 刷机工具，下面按系统给安装命令；
- 解压 `.xz` 的工具和 SSH 客户端（macOS、Linux、Windows 10/11 都自带 SSH）。

#### macOS

```bash
brew install libusb xz git
python3 -m venv ~/edl-venv
source ~/edl-venv/bin/activate
git clone https://github.com/bkerler/edl.git ~/edl-src
cd ~/edl-src && git submodule update --init --recursive
pip install .
```

以后每开一个新终端，先运行 `source ~/edl-venv/bin/activate`，`edl` 命令才可用。

`pip install .` 如果在最新版 Python 上报错，改用 Python 3.12：`brew install python@3.12`，把上面的 `python3 -m venv` 换成 `python3.12 -m venv`，重新做一遍。

#### Linux（Debian / Ubuntu）

```bash
sudo apt install git xz-utils python3-venv python3-dev liblzma-dev libusb-1.0-0
sudo systemctl disable --now ModemManager    # ModemManager 会抢占 EDL 设备
git clone https://github.com/bkerler/edl.git ~/edl-src
cd ~/edl-src && git submodule update --init --recursive
sudo bash ./install-linux-edl-drivers.sh     # 装 udev 规则，普通用户也能访问 EDL 设备
python3 -m venv ~/edl-venv
source ~/edl-venv/bin/activate
pip install .
```

装完 udev 规则后拔插一次 USB 线。仍然提示没权限的话，在 `edl` 前面加 `sudo`，并写成 venv 里的完整路径：`sudo ~/edl-venv/bin/edl …`。

#### Windows 10/11（未实测）

上游作者就是在 Windows 上刷的（上游 FLASHING.md 的命令是 PowerShell 写法）。本项目没有在 Windows 上实测，下面是按 edl 源码和资料整理的做法。

不建议直接用 edl 自带的一键脚本 `install_edl_win10_win11.ps1`。它装的是 Python 3.9，而 edl 要求 3.10 以上；它放进 PATH 的 `edl.bat` 调用的文件在 edl 3.62 里已经不存在，直接敲 `edl` 会报找不到文件。改用下面的手动步骤，在 PowerShell（不是 CMD）里运行：

```powershell
winget install -e --id Python.Python.3.12
winget install -e --id Git.Git
winget install -e --id akeo.ie.Zadig
winget install -e --id 7zip.7zip
```

装完关掉 PowerShell 再重新打开，然后：

```powershell
git clone https://github.com/bkerler/edl.git $env:USERPROFILE\edl-src
cd $env:USERPROFILE\edl-src
git submodule update --init --recursive
py -3.12 -m venv $env:USERPROFILE\edl-venv
& $env:USERPROFILE\edl-venv\Scripts\python.exe -m pip install -r requirements.txt
```

以后每开一个新的 PowerShell，先运行下面两行。之后本文里的 `edl …` 命令就能照抄：

```powershell
& $env:USERPROFILE\edl-venv\Scripts\Activate.ps1
function edl { python "$env:USERPROFILE\edl-src\edl.py" @args }
```

`Activate.ps1` 报「禁止运行脚本」的话，先运行 `Set-ExecutionPolicy -Scope Process Bypass`（只对当前窗口有效）。

USB 驱动：第一次进 EDL 后（第 1.1 步）要用 Zadig 给设备装 WinUSB 驱动，edl 才能访问它。edl 自带了 Windows 版的 libusb 库，不用另外装。

为什么不用 WSL：WSL2 默认看不到 USB 设备，要另装 usbipd-win 转接；EDL 设备在刷写过程中会重新连接，转接容易断。edl 直接在 Windows 上跑更稳。

#### 检查 edl 装好了

```bash
edl --help
```

期望输出开头有 `Qualcomm Sahara / Firehose Client`，后面是一长串用法说明。提示找不到 `edl`：macOS / Linux 先运行 `source ~/edl-venv/bin/activate`；Windows 先运行上面「每开一个新的 PowerShell」那两行。

### 0.3 下载文件

建一个工作目录，比如 `~/thinksmart`，把下面的文件都放进去。后面的命令都在这个目录里运行。

| 文件 | 从哪下载 | 什么时候用 |
| --- | --- | --- |
| `thinksmart-ubuntu-<日期>.img.xz`、`SHA256SUMS` | 本仓库 [Releases](https://github.com/justhalfbit/thinksmart-ubuntu-image/releases) 最新版 | 两条路线都要 |
| `lk2nd.img` | 上游仓库 [prebuilt/lk2nd.img](https://github.com/rickx/ubuntu-thinksmart/raw/main/prebuilt/lk2nd.img) | 只有路线 A |
| `bootstrap-pmos-ssh-generic-qcom-msm8953.img` 和同名 `.sha256` | 上游 Release [bootstrap-2026-05-22](https://github.com/rickx/ubuntu-thinksmart/releases/tag/bootstrap-2026-05-22) | 只有路线 A |

不用另外下载上游的分区表文件：bootstrap 镜像里已经带了改分区表的脚本 `/usr/local/sbin/apply-ubuntu-gpt.sh` 和布局文件。

```bash
mkdir -p ~/thinksmart && cd ~/thinksmart
curl -L -O https://github.com/rickx/ubuntu-thinksmart/raw/main/prebuilt/lk2nd.img
curl -L -O https://github.com/rickx/ubuntu-thinksmart/releases/download/bootstrap-2026-05-22/bootstrap-pmos-ssh-generic-qcom-msm8953.img
curl -L -O https://github.com/rickx/ubuntu-thinksmart/releases/download/bootstrap-2026-05-22/bootstrap-pmos-ssh-generic-qcom-msm8953.img.sha256
# 本镜像：到 Releases 页面复制最新版两个文件的下载地址，同样用 curl -L -O 下载
```

Windows PowerShell 里把 `curl` 写成 `curl.exe`，其余照抄。GitHub 在国内打不开或很慢时，给 curl 加代理参数 `-x http://代理地址:端口`，或者用浏览器下载后放进这个目录。

### 0.4 校验文件

```bash
cd ~/thinksmart
shasum -a 256 -c --ignore-missing SHA256SUMS          # Linux 也可以用 sha256sum
shasum -a 256 bootstrap-pmos-ssh-generic-qcom-msm8953.img lk2nd.img
cat bootstrap-pmos-ssh-generic-qcom-msm8953.img.sha256
```

期望输出：

- 第一条打印 `thinksmart-ubuntu-<日期>.img.xz: OK`；
- bootstrap 镜像的 SHA256 和 `.sha256` 文件里的值一样：`7d79db19b0911647bf6ab0a9a2924ef5cf83b4674798a54acdcbd41cdf07921b`；
- `lk2nd.img` 的 SHA256 是 `c81b036c75028c3d5aa915c72c89e075bc044360fe964c2ec0afb1d4a6f5209b`。这是写这份教程时上游的版本，上游以后更新了 lk2nd，以上游为准。

Windows 用 `Get-FileHash .\文件名 -Algorithm SHA256` 逐个算，和上面的值对比。

任何一个对不上：重新下载那个文件，别用。

### 0.5 解压本镜像

```bash
xz -dk thinksmart-ubuntu-<日期>.img.xz
shasum -a 256 -c --ignore-missing SHA256SUMS
```

期望输出：`.img.xz: OK` 和 `.img: OK` 两行。解压后的 `.img` 约 3.5 GB（20261101 版是 `3466592256` 字节，压缩包 `711307968` 字节；以后的版本见 Release 说明）。Windows 用 7-Zip 解压，再用 `Get-FileHash` 和 `SHA256SUMS` 里 `.img` 那一行对比。

`.img` 是整个 `system` 分区的内容，里面有启动分区和根分区两个小分区。首次开机会自动把根分区扩满整个 `system` 分区。

---

## 1. 进入 EDL 模式，判断走哪条路线

### 1.1 进 EDL（用户动手）

这台设备没有电源键，插上电源就开机，拔掉电源就断电。

1. 拔掉电源线。系统开着的话先关机（设置页「关机」或 `sudo systemctl halt`），屏幕全黑后等 10 秒再拔。USB 线如果插着，也先拔掉。拔掉后等 30 秒再做下面几步，刚关机马上插电可能不通电，进不了 EDL。
2. 用 USB 线把设备连到电脑。
3. **同时按住音量 + 和音量 −** 不放。
4. 按着不放，插上电源线。
5. 3～5 秒后松开音量键。

**屏幕保持黑屏是正常的**，EDL 模式没有任何显示。

检查电脑认到了设备：

- macOS：`ioreg -p IOUSB | grep -i -E "qhsusb|qusb|9008"`，期望看到 `QUSB__BULK` 或 `QHSUSB__BULK`。Apple Silicon 的 Mac 弹出「允许配件连接？」要点「允许」。
- Linux：`lsusb | grep -i 9008`，期望看到 `Qualcomm ... (QDL mode)` 或 `05c6:9008`。
- Windows（未实测）：设备管理器里出现 `QUSB__BULK`（多半带黄色感叹号）或 `Qualcomm HS-USB QDLoader 9008`。**第一次**要装 WinUSB 驱动：打开 Zadig → 菜单 Options 勾选 List All Devices → 下拉框选 `QUSB__BULK`（USB ID 是 `05C6 9008`）→ 右边驱动选 `WinUSB` → 点 Install Driver（已装过别的驱动时按钮叫 Replace Driver）。装一次以后就不用再装。

看不到：按[3.1 edl 找不到设备](#31-edl-找不到设备或者连上后马上断开)处理。

### 1.2 读分区表

```bash
cd ~/thinksmart
edl printgpt 2>&1 | tee gpt-before.txt
```

期望输出（节选）：

```
main - Device detected :)
...
CPU detected:      "APQ8053"
...
firehose - TargetName=MSM8953
firehose - total_blocks:15269888
...
boot:                Offset 0x0000000018200000, Length 0x0000000002000000, ...
system:              Offset 0x000000001c300000, Length 0x…, ...
```

怎么判断成功：有 `Device detected :)`，并且打印出了分区列表。`CPU detected` 不是 `APQ8053` 或 `total_blocks` 不是 `15269888`：**停止，这不是支持的设备**。

### 1.3 选路线

看 `system:` 那一行的 `Length`：

| `system` 的 Length | 有没有 `userdata:` 一行 | 说明 | 走哪条路线 |
| --- | --- | --- | --- |
| `0x0000000060000000`（1.5 GB） | 有 | 原厂分区表 | [路线 A](#路线-a第一次刷设备还是原厂系统) |
| `0x00000001b3cfbe00`（约 6.8 GB） | 没有 | 已经改成 Ubuntu 分区表 | [路线 B](#路线-b已经刷过本镜像或上游-ubuntu-镜像) |
| 其他值 | — | 不认识的分区表 | **停止**，把输出给用户看，不要继续 |

---

## 路线 A：第一次刷（设备还是原厂系统）

顺序和上游完全一致：

```
整盘备份 → 刷 lk2nd 到 boot → 刷 bootstrap 到 system → 开机进 bootstrap
→ SSH 进去改分区表 → 关机 → 再进 EDL → 刷本镜像到 system
```

为什么要绕一圈：原厂 `system` 分区只有 1.5 GB，装不下 Ubuntu。要先刷一个临时的小系统（bootstrap，postmarketOS），在设备上把分区表改成 `system` 约 6.8 GB 的布局，再刷正式镜像。

### A1. 进 EDL

同[1.1](#11-进-edl用户动手)。如果刚做完第 1 步、设备还连着、中间没拔线，可以直接继续。

### A2. 整盘备份原厂 eMMC（必做）

这是以后回到原厂系统的**唯一办法**。

```bash
cd ~/thinksmart
ls -l stock-full-emmc.bin 2>/dev/null && echo "已有备份文件，换个名字，别覆盖"
edl rf stock-full-emmc.bin 2>&1 | tee backup.log
```

- 大约 10～20 分钟，期间别动线。
- 期望输出最后有一行：`Dumped flash with sector count 15269888 as stock-full-emmc.bin.`

验证备份完整，三项都要对：

```bash
ls -l stock-full-emmc.bin
python3 -c "f=open('stock-full-emmc.bin','rb'); f.seek(512); print(f.read(8))"
shasum -a 256 stock-full-emmc.bin | tee stock-full-emmc.bin.sha256
```

1. 文件大小正好是 `7818182656` 字节，也就是 `15269888 × 512`；
2. 第二条打印 `b'EFI PART'`，说明开头是完整的 GPT 分区表；
3. 第三条把校验和存进 `stock-full-emmc.bin.sha256`，以后用它确认备份没坏。

（Windows：`(Get-Item .\stock-full-emmc.bin).Length` 看大小，`python -c …` 那条照用，`Get-FileHash` 算校验和。）

备份放哪：

- 和 `gpt-before.txt` 一起放在 `~/thinksmart`，**再拷一份到移动硬盘或另一台电脑**；
- 不要上传到网盘或公开的地方：里面有这台设备独有的数据。

以后要回原厂：进 EDL 后运行 `edl wf stock-full-emmc.bin`，整盘写回，要先得到用户同意。

失败了怎么办：

- 中途报错或断开：拔线，重新进 EDL，换线或换口，再跑一次（换个文件名）。
- 大小不对或不是 `EFI PART`：备份不完整，删掉这个文件重做。**备份没做成之前，不要往下走。**

### A3. 刷 lk2nd 到 boot 分区（先问用户）

lk2nd 是一个二级 bootloader，负责从 `system` 分区启动 Linux。

```bash
edl w boot lk2nd.img 2>&1 | tee flash-lk2nd.log
```

期望输出最后：`Wrote lk2nd.img to sector 790528.`

失败了怎么办：

- `Couldn't detect partition: boot`：分区表没读对，先重跑 `edl printgpt` 看看。
- 其他报错：重新进 EDL 后重试一次，仍失败就停下来。

### A4. 刷 bootstrap 到 system 分区（先问用户）

```bash
edl w system bootstrap-pmos-ssh-generic-qcom-msm8953.img 2>&1 | tee flash-bootstrap.log
edl reset
```

期望输出：

- 第一条最后：`Wrote bootstrap-pmos-ssh-generic-qcom-msm8953.img to sector 923648.`
- `edl reset` 输出 `Reset succeeded.`

设备会自己重启：先短暂出现 lk2nd 的界面，再启动 postmarketOS。**USB 线不要拔**，下一步要用它连 SSH。

### A5. SSH 登录 bootstrap

bootstrap 开机后会通过 USB 线提供一个网络：设备是 `172.16.42.1`，电脑通常会自动拿到 `172.16.42.2`。

1. 等 1～2 分钟，让设备开完机。
2. 检查电脑上多了一个网络接口：
   - macOS：「系统设置 → 网络」里多出一个有线接口；
   - Linux：`ip -br addr` 里多出一个 `usb0` 或 `enx…` 接口；
   - Windows（未实测）：「网络连接」里多出一个以太网适配器。bootstrap 用的是 USB NCM 网卡，Windows 11 自带 NCM 驱动，一般能直接识别；Windows 10 自带的 NCM 驱动和部分设备不兼容，可能认不出来。认不出来的话见下面「Windows 连不上 USB 网络」。
3. 没有自动拿到 `172.16.42.x` 的地址，就手动设置这个接口：IP `172.16.42.2`，子网掩码 `255.255.0.0`，路由器留空。
4. 登录（密码 `thinksmart`）：

```bash
ping -c 3 172.16.42.1
ssh -o StrictHostKeyChecking=accept-new pmos@172.16.42.1
```

登录后先确认进对了系统：

```bash
cat /etc/hostname
ls /usr/local/sbin/apply-ubuntu-gpt.sh
```

期望输出：`thinksmarter`，以及脚本路径本身。

失败了怎么办：

- ping 不通：确认屏幕上 postmarketOS 已经起来了；换个 USB 口；macOS 上按第 3 点手动设 IP；拔插一次 USB 线。
- 屏幕停在 lk2nd 的界面（写着 fastboot）：bootstrap 没刷好，回到 A1 重新进 EDL，重做 A4。
- Windows 连不上 USB 网络（未实测）：改走 WiFi。照上游的 Windows 做法，在 WSL 里用上游脚本 `sources/scripts/prepare-pmos-ssh-bootstrap-image.sh` 把 WiFi 名和密码写进 bootstrap 镜像（用法见上游 [FLASHING.md](https://github.com/rickx/ubuntu-thinksmart/blob/main/FLASHING.md) 的 Stage 0），回到 A1 重刷 A4 用这个新镜像，开机后在路由器里找主机名 `thinksmarter` 的 IP，`ssh pmos@<IP>`。也可以只在这一步借一台 macOS 或 Linux 电脑。

### A6. 改分区表（先问用户，不可逆）

在 bootstrap 的 SSH 里运行：

```bash
sudo /usr/local/sbin/apply-ubuntu-gpt.sh
```

`sudo` 要密码的话也是 `thinksmart`。期望输出最后：

```
GPT rewrite complete.
Next steps:
1. Power off or reboot the device.
...
```

脚本打印的第 3 步提到上游镜像的文件名，**不用管**，下一步刷的是本镜像。

然后马上关机：

```bash
sudo poweroff
```

这一步把 `system` 分区扩到约 6.8 GB，删掉原厂的 vendor、cache、userdata 等分区，`persist` 移到磁盘末尾。

失败了怎么办：脚本报错就**不要关机、不要重试**，把完整输出给用户，停下来。

### A7. 再进 EDL，确认新分区表

等屏幕黑下来（插着电的话它可能会自己重新亮起，没关系），再按[1.1](#11-进-edl用户动手)拔掉电源进 EDL，然后：

```bash
edl printgpt 2>&1 | tee gpt-after.txt
grep -E "^(system|userdata):" gpt-after.txt
```

期望输出：只有一行 `system:`，`Length 0x00000001b3cfbe00`，没有 `userdata:`。

如果 `system` 仍然是 `0x0000000060000000`：分区表没改成功，回到 A4 重来（lk2nd 已经刷过，A3 不用重做）。

### A8. 刷本镜像（先问用户）

```bash
edl w system thinksmart-ubuntu-<日期>.img 2>&1 | tee flash-system.log
edl reset
```

- 写入要几分钟到二十分钟，期间别动线。
- 期望输出：最后有 `Wrote thinksmart-ubuntu-<日期>.img to sector 923648.`，然后是 `Reset succeeded.`

失败了怎么办：

- `Error: … has N sectors but partition only has 3145728.`：分区表还是原厂的，回 A7 检查。
- 写到一半报错：重新进 EDL 重试一次；仍失败就停下来，把 `flash-system.log` 给用户。

写完后拔掉 USB 线，进入[第 2 步：首次开机](#2-首次开机和设置)。

---

## 路线 B：已经刷过本镜像或上游 Ubuntu 镜像

分区表和 lk2nd 都已经就位，只需要重写 `system` 分区。

> 这会清掉旧系统里的所有东西：聊天记录、网关里的 API Key 和管理员密码、WiFi 配置、SSH 授权。只是想升级语音客户端或网关的话，**不用重刷**，见[第 5 节](#5-以后的更新)。

### B1. （推荐）先备份用户数据

旧系统是本镜像、还想保留聊天记录和设置的话，先按[4.1](#41-刷机前备份)备份，刷完再还原。旧系统是上游的 Plasma 镜像就跳过这一步，里面没有这些数据。

### B2. 进 EDL 并确认分区表

按[1.1](#11-进-edl用户动手)、[1.2](#12-读分区表)做，确认 `system` 的 Length 是 `0x00000001b3cfbe00`。

### B3. 刷本镜像（先问用户）

和 [A8](#a8-刷本镜像先问用户) 完全一样：

```bash
edl w system thinksmart-ubuntu-<日期>.img 2>&1 | tee flash-system.log
edl reset
```

拔掉 USB 线，进入第 2 步。

---

## 2. 首次开机和设置

### 2.1 首次开机

- 第一次开机比平时慢，大约 1～2 分钟：系统会自动把根分区扩满整个 `system` 分区，并生成这台设备自己的 SSH 主机密钥。之后每次开机大约 20 秒。
- 屏幕上会出现**欢迎页**（深色背景，有设备地址和 WiFi 状态）。

### 2.2 屏幕上连 WiFi（用户动手）

1. 在欢迎页点「连接 Wi‑Fi」按钮，在「选择 Wi‑Fi」列表里点你的网络。
2. 用屏幕键盘输入密码，点「连接」。看到「已连接 …」就成功了。
3. 连上后欢迎页底部会显示「设备地址」，几秒后界面自动切到语音助手。

连不上：见[3.3](#33-没有-wifi屏幕配网不成功)。

### 2.3 找到设备的 IP

后面用浏览器和 SSH 都要用到。刷完的系统目前**不能用 USB 线登录**（见[附录](#刷完后的-usb-网络)），只能连上 WiFi 后用 WiFi 的地址。

AI 助手：**自己找，不要问用户**。

1. 看电脑在哪个网段（电脑要和设备连同一个路由器）：

   ```bash
   # macOS：打印本机 IP
   ipconfig getifaddr $(route -n get default | awk '/interface:/{print $2}')
   # Linux：输出里 src 后面是本机 IP
   ip -4 route get 1.1.1.1
   ```

   本机 IP 是 `192.168.1.23` 的话，网段一般就是 `192.168.1.0/24`。

2. 扫局域网里同时开着 22（SSH）和 16688（网关后台）端口的机器：

   ```bash
   nmap -p 22,16688 --open 192.168.1.0/24
   ```

   没装 nmap：macOS `brew install nmap`，Linux `sudo apt install nmap`。16688 没扫到的话，可能是网关还在加载语音识别模型，等 1 分钟再扫。

3. 确认候选地址：打开 `http://<IP>:16688/admin`，页面标题是「小智 Hub 管理后台」就对了。命令行：

   ```bash
   curl -s http://<IP>:16688/admin | grep -o '<title>[^<]*'
   ```

macOS 上 nmap 什么都扫不到、`curl` 或 `ssh` 报 `No route to host`：终端程序没有「本地网络」权限，见[3.8](#38-macos-上-ssh-报-no-route-to-host)。

不用 nmap 的办法（Windows 也能用，Windows 上用 `ipconfig` 看本机 IP）：

- 路由器管理页的 DHCP 客户端列表（设备列表），主机名是 `thinksmarter`；
- 设备屏幕：欢迎页上的「设备地址」（连上 WiFi 后界面很快切到语音助手，这个地址只闪一下），或者语音界面设置页里的「本机 IP」。这一项要请用户看屏幕告诉你。

下面用 `<设备IP>` 代表这个地址。

第一次 SSH 前：如果这个 IP 以前连过别的设备或旧系统，先清掉旧记录，否则会报主机密钥变了：

```bash
ssh-keygen -R <设备IP>
```

用 4.2 节专用记录文件的，再清一次：`ssh-keygen -R <设备IP> -f ~/.ssh/known_hosts_thinksmart`。

### 2.4 网关管理后台：设管理员密码、填 API Key（用户动手）

1. 用电脑浏览器打开 `http://<设备IP>:16688/admin`。开机后网关要大约 1 分钟加载语音识别模型，打不开就等一会儿再刷新。
2. **先设管理员密码**。没设之前，同一局域网里任何人都能打开这个后台。
3. 填大模型的 API Key。默认用 Claude API；也可以换成 DeepSeek 等其他厂商，在后台里选。
4. 保存。

没填 Key 之前，语音助手能唤醒，但答不上来。

AI 助手注意：API Key 由用户自己在浏览器里填，不要替用户填，也不要把 Key 写进任何文件或日志。

### 2.5 改默认密码（为了安全，刷完马上改）

和上游一样，镜像里有两个能登录的账号，**默认密码都是 `thinksmart`，而且 SSH 都开着**：

| 账号 | 默认密码 | 说明 |
| --- | --- | --- |
| `ubuntu` | `thinksmart` | 日常用的账号，可以免密 sudo |
| `root` | `thinksmart` | 管理员账号，**SSH 也允许 root 用密码登录** |

同一个局域网里的人知道默认密码就能登录这台设备，所以两个账号的密码都要改，只改 `ubuntu` 不够：

```bash
ssh ubuntu@<设备IP>
passwd               # 改 ubuntu 的密码
sudo passwd root     # 改 root 的密码
```

不需要用 root 远程登录的话，也可以直接锁住它的密码登录（`sudo passwd -l root`），以后需要管理员权限就用 `ubuntu` 加 `sudo`。

以前 SSH 过这台设备（包括 bootstrap 阶段的 `172.16.42.1`）的话，主机密钥变了，先清掉旧记录：

```bash
ssh-keygen -R <设备IP>
ssh-keygen -R 172.16.42.1
```

AI 助手注意：新密码由用户自己输入，不要替用户想密码，也不要记录下来。

### 2.6 确认语音能用（用户动手）

1. 对着设备说「**小麦小麦**」（也认「哈喽小麦」「小麦同学」），屏幕会切到聆听状态，并响一声提示音。
2. 问一句，比如「今天星期几」，等它回答。

不灵的话，在 SSH 里查服务状态：

```bash
systemctl status thinksmart-client --no-pager | head -5    # 语音客户端，应为 active (running)
systemctl --user status xiaozhi-hub --no-pager | head -5   # 网关，应为 active (running)
journalctl -u thinksmart-client -b --no-pager | tail -30
```

能唤醒、答不上来：多半是 API Key 没填或填错，回 2.4 检查。不能唤醒或没声音：见[3.4](#34-没有声音或者喊了没反应)。

---

## 3. 常见问题排查

### 3.1 edl 找不到设备，或者连上后马上断开

表现：一直停在 `Waiting for the device`，或者报 `Couldn't detect the device`。

按顺序试：

1. 确认设备真在 EDL：屏幕全黑，电脑上能看到 `9008` / `QUSB__BULK`（见 1.1）。
2. 换一根**能传数据**的线。很多充电线只能充电。
3. 直接插电脑本体，别经过扩展坞、Hub、显示器上的口。
4. 拔掉 USB 线和电源线让设备断电，再按 1.1 重新进 EDL。EDL 闲置一段时间或某条命令失败后，常常要重进一次。
5. Linux：确认 ModemManager 已停（`systemctl status ModemManager`），udev 规则已装；还不行就用 `sudo`。
6. Windows（未实测）：设备管理器里设备还带感叹号，就按 1.1 用 Zadig 装 WinUSB。装过高通官方 9008 驱动的，edl 也可以加 `--serial` 走串口方式（`edl --serial printgpt`）。
7. Apple Silicon 的 Mac：确认点了「允许配件连接」。

### 3.2 开机停在 lk2nd 的 Fastboot 界面

表现：屏幕上是 lk2nd 的文字菜单，写着 `Fastboot mode`，不往下启动。

原因：lk2nd 在 `system` 分区里没找到能启动的系统。常见于刷写中断、刷错了文件，或者分区表没改成功就刷了镜像。

处理：

1. 拔掉电源线（停在 lk2nd 界面时登录不了，直接拔），再按 1.1 进 EDL。
2. `edl printgpt` 确认 `system` 是 `0x00000001b3cfbe00`。
3. 重新校验 `.img`（0.5 节），然后重做 A8 / B3。

**别用 fastboot 刷任何东西。**

### 3.3 没有 WiFi，屏幕配网不成功

- 欢迎页会显示附近的网络。看不到你的网络：确认路由器在 2.4 GHz 或 5 GHz 正常广播（隐藏 SSID 要手动输入名字）。
- 密码对了但一直「正在获取网络地址」：等 1 分钟；仍然不行就重启一次设备。
- 刷完的系统目前不能用 USB 线登录（见[附录](#刷完后的-usb-网络)）。屏幕配网一直不成功：重启设备再试；还不行就重刷（A8 / B3）后重新配网。
- 已经能通过 WiFi SSH 登录、想换到另一个网络时，可以用命令连：

  ```bash
  nmcli dev wifi list
  sudo nmcli dev wifi connect "WiFi名" password "WiFi密码"
  ip -4 -br addr show wlan0
  ```

  也可以用文字界面 `sudo nmtui`。
- 连上后屏幕还停在欢迎页：`sudo kiosk-mode restart` 重开展示界面。

### 3.4 没有声音，或者喊了没反应

```bash
systemctl --user status pipewire wireplumber thinksmart-mic --no-pager | grep -E "●|Active"
wpctl status | sed -n '/Audio/,/Video/p'
wpctl get-volume @DEFAULT_AUDIO_SINK@
```

- 三个服务都应是 `active (running)`。`wpctl status` 的 Sinks 里应该有 `Built-in Audio Speaker`，Sources 里应该有 `Microphone` 和 `Microphones (both)`。
- 音量太小：`wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.5`，或者按设备上的音量键。
- 设备上的麦克风开关（隐私开关）要打开，关着的时候语音助手听不到。
- 服务都正常但还是没声音：重启设备。这台机器的音频 DSP 偶尔会卡住，只有重启能恢复。
- **不要直接操作声卡硬件**（`speaker-test -D hw:…`、`aplay -D hw:…` 等），会让音频 DSP 卡死。所有声音都走 PipeWire。

### 3.5 开机进不了界面（黑屏、白屏、一直停在欢迎页）

```bash
systemctl status thinksmart-kiosk thinksmart-client --no-pager | grep -E "●|Active"
journalctl -u thinksmart-kiosk -b --no-pager | tail -30
```

- `thinksmart-kiosk` 是屏幕上的展示界面，`thinksmart-client` 是语音客户端（提供界面内容）。
- 重开展示界面：`sudo kiosk-mode restart`。
- 一直停在欢迎页：说明设备没联网，或者语音客户端没起来，先看 3.3 和上面 `thinksmart-client` 的状态。
- 屏幕全黑但能 SSH：可能是熄屏了，碰一下屏幕或在设备前挥挥手。
- SSH 也连不上：刷完的系统不能用 USB 线登录，先确认设备连上了 WiFi（3.3）、IP 找对了（2.3）；macOS 上报 `No route to host` 见 3.8；都不行就重刷（A8 / B3）。

### 3.6 SSH 提示主机密钥变了

```
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
```

每次刷机都会生成新的主机密钥，这是正常的：

```bash
ssh-keygen -R <设备IP>
ssh-keygen -R 172.16.42.1
```

如果你**没有**重刷过却看到这条警告，先别连，确认是不是 IP 被别的设备占了。

### 3.7 写入时提示分区太小

`Error: … has N sectors but partition only has 3145728.`：分区表还是原厂的，要走路线 A，先改分区表。

### 3.8 macOS 上 ssh 报 No route to host

```
ssh: connect to host <设备IP> port 22: No route to host
```

设备在线、IP 也对，Mac 上却连不上局域网地址：多半是终端程序没有「本地网络」权限。打开「系统设置 → 隐私与安全性 → 本地网络」，把你用的终端程序（终端、iTerm、VS Code 等）的开关打开，然后重开终端再试。浏览器打不开 `http://<设备IP>:16688/admin` 也可能是同样的原因，给浏览器打开这个权限。

### 3.9 开机停在紧急模式（emergency mode）

现象：屏幕上是一屏英文，最后几行是 `You are in emergency mode`，前面有 `Failed to start systemd-fsck…`、`Dependency failed for boot.mount - /boot`，往上还能看到 `I/O error, dev mmcblk0 … (WRITE)`。

原因：没关机就直接拔了电，下次开机要修复启动分区 `/boot`，修复时往存储里写入失败，系统就停在这里。你的数据在另一个分区（根分区），一般没事。以后拔电前先关机（见[需要用户本人动手的操作](#需要用户本人动手的操作)），就能避免。

处理（只重写启动分区，不动你的数据）：

1. 按 1.1 进 EDL。
2. 先把整个 `system` 分区读出来留底（约 6.8 GB，实测约 4 分钟，慢的电脑可能要十几分钟，期间别动线）：

   ```bash
   edl r system system-backup.img
   ```

3. 从**你刷的那个版本**的镜像里取出启动分区（镜像里从第 2048 扇区开始，共 509952 个扇区）：

   ```bash
   dd if=thinksmart-ubuntu-<日期>.img of=boot-part.img bs=512 skip=2048 count=509952
   ```

   Windows 在 WSL 里运行这条命令。
4. 算写入位置：`edl printgpt` 输出里 `system` 那一行的 Offset（比如 `0x000000001c300000`）除以 512，再加 2048。按本教程改过分区表的设备是 `923648 + 2048 = 925696`。
5. 写入（**先问用户**），再重启：

   ```bash
   edl ws 925696 boot-part.img
   edl reset
   ```

   正常的话会进语音界面。还是停在紧急模式，把屏幕照片和 `system-backup.img` 留好，按路线 B 重刷，再用 4.2 还原数据（之前没有备份的话，可以从 `system-backup.img` 里取回数据）。

---

## 4. 备份和还原用户数据

本镜像不带任何个人数据。从旧版本镜像重刷到新版本时，可以把下面这些先备份、刷完再还原：

- 网关的数据目录：API Key、管理员密码、Grok 登录、聊天记录 `chat.db`；
- Claude Code 的登录（如果装过）；
- 语音客户端设置：设备 ID、睡眠时段、亮度、熄屏；
- 展示界面的浏览器存储；
- `~/.ssh/authorized_keys`；
- WiFi 配置、主机名、`/etc/thinksmart-kiosk.conf`；
- SSH 主机密钥（可选，还原后电脑就不会提示主机密钥变了）。

这些文件里有 API Key 和密码，备份文件只放在自己电脑上，别上传。

### 4.1 刷机前备份

在电脑上运行（旧系统还在、能 SSH 时）：

```bash
ssh ubuntu@<设备IP> 'systemctl --user stop xiaozhi-hub; cd / && sudo tar --numeric-owner --ignore-failed-read -cpf - \
  home/ubuntu/xiaozhi-hub-server/main/xiaozhi-server/data home/ubuntu/.claude home/ubuntu/.claude.json \
  home/ubuntu/.config/thinksmart-client home/ubuntu/.local/share/thinksmart-kiosk home/ubuntu/.ssh \
  etc/NetworkManager/system-connections etc/netplan etc/thinksmart-kiosk.conf etc/hostname \
  etc/ssh/ssh_host_ecdsa_key etc/ssh/ssh_host_ecdsa_key.pub etc/ssh/ssh_host_ed25519_key \
  etc/ssh/ssh_host_ed25519_key.pub etc/ssh/ssh_host_rsa_key etc/ssh/ssh_host_rsa_key.pub; \
  systemctl --user start xiaozhi-hub' > userdata.tar
chmod 600 userdata.tar
tar tf userdata.tar | head -20
```

- 打包前先停网关，聊天记录数据库不会写到一半；打包完自动重新启动。
- 不存在的路径会跳过并打印一行提示，不影响结果。
- 最后一条应该能列出 `home/ubuntu/xiaozhi-hub-server/...`、`etc/NetworkManager/...` 等路径。

### 4.2 刷机后还原

前提：刷完、屏幕上连好 WiFi、知道 `<设备IP>`。还原脚本在本仓库的 `image/restore-userdata.sh`，要在 macOS / Linux 上跑（Windows 用 WSL）。

1. 准备一把专用的 SSH 密钥，并授权给设备（会问一次 `ubuntu` 的密码，刚刷完是 `thinksmart`）：

   ```bash
   [ -f ~/.ssh/thinksmart_ed25519 ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/thinksmart_ed25519
   ssh-copy-id -i ~/.ssh/thinksmart_ed25519 -o UserKnownHostsFile=~/.ssh/known_hosts_thinksmart ubuntu@<设备IP>
   ```

2. 还原：

   ```bash
   TS_HOST=<设备IP> image/restore-userdata.sh userdata.tar --host-keys
   ```

   - `--host-keys` 会把旧的 SSH 主机密钥也还原回去，不想要就去掉。用了它之后，第 1 步记下的是新密钥，要清掉：`ssh-keygen -R <设备IP> -f ~/.ssh/known_hosts_thinksmart`。
   - 第 1 步提示主机密钥变了（以前连过这个 IP），先运行上面这条 `ssh-keygen -R`，再重做第 1 步。
   - 期望输出：先列出 `restoring: …`，最后是 `restored on the device` 和 `done; the hub needs about a minute to load its speech model`。
   - 脚本会先把整个备份解到设备上的临时目录，全部成功才停服务、替换文件；任何一步失败都会报错退出，设备保持原样，服务也会重新启动。

3. 还原后网关里的管理员密码、API Key 都回到备份时的样子。设备密码不在备份里，记得按 2.5 再改一次。

---

## 5. 以后的更新

- **语音客户端**：设置页「软件更新」里检查，有新版本时点「更新」。更新包只从 HTTPS 下载，装之前逐个文件核对大小和 sha256，装坏了自动退回旧版本。

  想自己发布客户端更新（比如用自己改过的客户端）：用本仓库的 `update/make-release.py` 生成更新清单和安装包，把生成的文件传到自己 GitHub 仓库的 Release，再把设备上 `/etc/thinksmart-update.conf` 里 `SOURCES` 的地址改成自己仓库的 Release 地址。不需要任何密钥。更新没有签名，更新地址上放什么，设备就会以 root 身份装什么：`SOURCES` 只填你自己的、或你信任的地址，**不要填公共的 GitHub 加速镜像或代理站**。用法见 `update/README.md`。
- **网关**：在网关管理后台（`http://<设备IP>:16688/admin`）侧边栏点「更新网关」。页面显示当前版本的时间和短提交号，可以检查有没有新版本；只有你点了更新才会装，装失败会自动退回旧版本。

  也可以用命令行，SSH 进设备后运行：

  ```bash
  cd ~/xiaozhi-hub-server && bash scripts/update.sh
  ```

  它会拉新代码、补装依赖、重启网关。
- **系统软件包**：`sudo apt update && sudo apt upgrade` 可以照常用。屏幕、声音、网络依赖的 41 个包（补丁版 Mesa、WebKitGTK、Weston、PipeWire、NetworkManager 等，清单在 `image/held-packages.txt`）锁在测过的版本上，不会被升级。内核和驱动不归 apt 管，也不会变。
- **系统镜像本身**：有新版镜像时按[路线 B](#路线-b已经刷过本镜像或上游-ubuntu-镜像)重刷，记得先做[4.1 备份](#41-刷机前备份)。

---

## 附录：分区和镜像结构

给想弄明白原理的人和 AI 助手参考。

| 分区 | 作用 | 本教程会不会写 |
| --- | --- | --- |
| `boot` | lk2nd 二级 bootloader | 路线 A 写一次 |
| `system` | 整个 Linux 系统，改分区表后约 6.8 GB（扇区 923648 起，14280671 个扇区） | 每次刷机都写 |
| `modem`、`dsp`、`persist` 等 | 高通固件和设备数据 | 从不写 |

本镜像（`.img`）是 `system` 分区的内容，里面又是一张 MBR 小分区表：

- 第 1 个分区：`pmOS_boot`（ext2），内核、initramfs、设备树、启动配置；
- 第 2 个分区：`pmOS_root`（ext4），Ubuntu 24.04 根文件系统。首次开机时 initramfs 会把它扩到 `system` 分区末尾。

启动顺序：高通 PBL → 原厂 SBL/aboot → `boot` 分区里的 lk2nd → 读 `system` 里 `pmOS_boot` 的 extlinux 配置 → Linux。

### 刷完后的 USB 网络

**已知问题：刷完后的系统目前不能用 USB 线登录。** 镜像里的 USB 网络已经设成 NCM（设备 `172.16.42.1`，上游设备包默认是 macOS 不支持的 RNDIS），但系统起来后设备的 USB 口不会被电脑识别（电脑的 USB 设备列表里看不到它），改回 RNDIS 也一样，问题在 USB 口没切到设备模式，还没修。

所以刷完后只能连上 WiFi 再用 WiFi 的地址登录。bootstrap 阶段（[A5](#a5-ssh-登录-bootstrap)）的 USB 网络不受影响，照常能用。

### 镜像里的系统调整

和上游镜像相比，除了去掉 Plasma 桌面、开机直接进语音界面，还做了这些调整（都有意为之）：

- 屏幕上不能双指缩放：展示界面只接收第一根手指，免得误触把页面放大。
- USB 网络设成 NCM 而不是上游的 RNDIS（不过目前刷完后的系统 USB 口不被电脑识别，见上一节）。
- WiFi 省电关闭：这块 QCA9379 网卡省电时会漏收 DHCP 回复，开机后要等 1～3 分钟才拿到 IP。
- 41 个关键软件包锁定版本（见[第 5 节](#5-以后的更新)）。
- 接近传感器直接读 `/dev/i2c-0`（`ubuntu` 在 `i2c` 组里），不再每秒调用 sudo 刷满日志。
- 时间同步用国内也能连上的 NTP 服务器：`ntp.aliyun.com`、`ntp.tencent.com`、`cn.pool.ntp.org`，备用 `ntp.ubuntu.com`。时区是北京时间，不在中国的话改成自己的时区，比如 `sudo timedatectl set-timezone Europe/Berlin`。
- 日志只存在 systemd 日志里（持久保存，最多 64 MB、一个月），关掉了重复写一份到 `/var/log` 的 rsyslog。查日志用 `journalctl`。
- 不生成程序崩溃转储（core dump），省磁盘；开了 zram 压缩内存。
- 停用了用不上的 ModemManager、avahi、udisks2。
- 前置摄像头（上游还不能用）：自写的 S5KC505A 驱动加设备树，libcamera 0.8 的 GPU 软件 ISP 做自动曝光、白平衡和色彩，`thinksmart-camera` 服务把它变成普通摄像头 `/dev/video10`（1280×720，30 fps），只在有程序读取时才打开摄像头。`ubuntu` 在 `video` 组里，可以直接用 `cam -l`、`cam` 拍照。原理和参数见 [camera/README.md](camera/README.md)。

已知限制：

- 首次开机不连网也能用屏幕配网；语音识别在本机，大模型和语音合成（默认 Edge TTS）要联网。
- 摄像头从程序打开到出画面要 1～2 秒（平时摄像头是关着的）；颜色用原厂标定的一组色彩矩阵，不分光源，也没做镜头暗角校正。
- 刷完后的系统不能用 USB 线登录，只能走 WiFi（见[刷完后的 USB 网络](#刷完后的-usb-网络)）。
- 为了禁止双指缩放，屏幕只接收第一根手指。用屏幕键盘两指交替快速打字时，第一根手指还没抬起、第二根就按下，第二下会丢掉，少一个字。输 WiFi 密码时慢一点，一次一指。
- 镜像里带的 GPU 固件、WiFi/蓝牙固件来源和上游相同（照上游做法）。

---

## 致谢和声明

- 设备移植、lk2nd、bootstrap 镜像和分区方案来自 [rickx/ubuntu-thinksmart](https://github.com/rickx/ubuntu-thinksmart)，没有它就没有这个项目。上游也感谢了 FelixKa 的 postmarketOS 设备包和 TAS5782M 驱动，以及 postmarketOS 项目的内核。
- 刷机工具是 [bkerler/edl](https://github.com/bkerler/edl)。
- 镜像由 Ubuntu 24.04 的软件包构建。本项目是个人项目，与 Canonical、联想（Lenovo）、高通（Qualcomm）没有任何关系。「Ubuntu」「ThinkSmart」是各自所有者的商标。
- 刷机有风险，可能让设备无法启动。请先做好整盘备份，风险自负。

## 仓库里有什么

| 目录 | 内容 |
| --- | --- |
| `image/` | 出镜像（从设备抓取、清理、打包）、备份还原用户数据的脚本 |
| `kiosk/` | 展示屏外壳（Weston + WebKitGTK 全屏页面）、欢迎页、屏幕键盘、GPU 看门狗、WiFi 省电和 NTP 设置 |
| `screen/` | 自动熄屏、接近传感器和加速度唤醒 |
| `xiaozhi/` | 麦克风服务和音频配置（ALSA、PipeWire、WirePlumber） |
| `update/` | 语音客户端的在线更新 |
| `mesa/` | 补丁版 Mesa（GPU 白屏、卡死修复）的构建脚本和补丁 |
| `codec-dmic/`、`kernel/` | 第二颗麦克风的驱动和设备树补丁，以及构建它用的内核环境 |
| `camera/` | 前置摄像头：传感器驱动、设备树、libcamera 补丁和调校文件、`/dev/video10` 桥接服务，以及从原厂固件重新提取参数的工具 |
| `zram/` | zram 压缩内存 |

本仓库以 MIT 许可发布，见 [LICENSE](LICENSE)。例外：`camera/` 里的内核驱动 `s5kc505a/` 是 GPL-2.0，设备树片段和内核里的 dts 一样是 BSD-3-Clause，`tscam-bridge.cpp` 是 GPL-2.0+（源文件开头有 SPDX 标识）；`libcamera-s5kc505a.patch` 跟随 libcamera 的 LGPL-2.1+。
