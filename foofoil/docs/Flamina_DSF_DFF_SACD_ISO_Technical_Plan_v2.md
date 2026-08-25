# 浮箔（Flamina）DSF / DFF / SACD ISO 音频支持技术方案

> 目标：在浮箔现有“以文件为中心”的轻量查看/播放模型中，增加 DSF、DFF（DSDIFF）与 SACD ISO 支持；在输出设备满足条件时优先以 DoP（DSD over PCM）保持 DSD bitstream 输出，在设备或链路不满足条件时自动降级为 PCM。
>
> 本方案不把浮箔扩展成 iTunes / Audirvāna 式音乐资料库。音频与图片、PDF、视频一致，仍然是“打开一个文件并立即使用”。

## 1. 设计目标

### 1.1 第一阶段支持

- `.dsf`
- `.dff` / DSDIFF
  - raw DSD
  - DST 压缩 DSD
- DoP 输出
- DSD → PCM 自动降级
- 输出设备能力检测
- 播放 / 暂停 / Seek
- 当前打开文件或文件组的轻量列表
- 基本 metadata / 封面
- 设备插拔与播放恢复

### 1.2 第二阶段支持

- SACD `.iso`
- SACD Stereo / 2CH Area
- ISO 内 Track 枚举与播放
- ISO 中 raw DSD
- ISO 中 DST → DSD
- Track 内 Seek
- Track 间 gapless

### 1.3 后续可扩展

- SACD Multichannel Area
- 更高质量、可配置的 DSD → PCM 滤波
- Native DSD（仅在 macOS 与具体设备确实暴露可靠通路时考虑）
- APE / WavPack 等其他非系统原生格式

### 1.4 非目标

第一版明确不做：

- 音乐曲库扫描
- Artist / Album / Genre 数据库
- 自动整理音乐文件
- 在线音乐服务
- EQ / DSP / VST / AU
- DSD 升频
- PCM → DSD
- HQPlayer 式复杂滤波
- SACD 抓轨/制作工具

浮箔中的“列表”仅表示：

1. 用户一次打开的一组文件；
2. SACD ISO 自身包含的 Track。

它不是持久化音乐资料库。

---

## 2. 核心原则

### 2.1 DSD 优先保持 DSD

对 DSF、DFF、SACD ISO 中最终得到的 DSD 音频，优先链路为：

```text
DSF / DFF / SACD ISO
          ↓
       DSDStream
          ↓
       DoPEncoder
          ↓
    CoreAudio HAL
          ↓
      USB Audio
          ↓
  支持 DoP 的 DAC
```

DoP 不执行 DSD → PCM 转换，只把 DSD payload 封装进符合 PCM 传输形式的数据帧中，使其能够通过 CoreAudio / USB Audio 送达 DAC。

只要中间没有 SRC、混音、音量缩放或 DSP 修改，并且 DAC 最终识别为 DSD，即可视为 DSD bitstream passthrough。

### 2.2 DoP 不可用时自动降级 PCM

```text
DSDStream
    ↓
DSDPCMDecoder
    ↓
PCM
    ↓
CoreAudio
    ↓
当前输出设备
```

典型场景：

- Mac 内置扬声器
- AirPods / 蓝牙设备
- 普通 PCM DAC
- DAC 不支持对应 DoP carrier sample rate
- CoreAudio 无法设置满足 DoP 要求的 physical format
- Hog / Exclusive 初始化失败
- 用户主动选择 PCM 输出

原则：

> 能保持 DSD 就保持 DSD；不能保持时自动播放 PCM，而不是简单报“不支持”。

---

## 3. 总体架构

```text
                    ┌────────────────────────┐
                    │     Audio Viewer       │
                    │ SwiftUI / existing UI  │
                    └───────────┬────────────┘
                                │
                      PlaybackController
                                │
              ┌─────────────────┴─────────────────┐
              │                                   │
         AudioSource                         OutputRouter
              │                                   │
   ┌──────────┼──────────┐              DeviceCapabilityProbe
   │          │          │                       │
DSFSource  DFFSource  SACDSource                 │
   │          │          │                       │
   │       raw DSD    raw DSD                    │
   │          │       / DST                      │
   │          │          │                       │
   │          └─DST?─────┘                       │
   │               │                            │
   └───────────────┴──────→ DSDStream ←─────────┘
                            │
                 ┌──────────┴──────────┐
                 │                     │
             DoPEncoder           DSDPCMDecoder
                 │                     │
                 └──────────┬──────────┘
                            │
                       AudioOutput
                            │
                      CoreAudio HAL
                            │
                         Device
```

关键设计是：**所有 DSD 来源最终统一收敛到 `DSDStream`**。

这样 DSF、DFF、SACD ISO 的差异只存在于输入层；DoP、PCM fallback、HAL 输出、设备探测、播放状态等全部复用。

---

## 4. 核心抽象

### 4.1 `AudioSource`

```swift
protocol AudioSource {
    var metadata: AudioMetadata { get }
    var duration: TimeInterval { get }
    var tracks: [AudioTrack] { get }

    func open(track: AudioTrack?) throws -> AudioStream
}
```

普通 DSF / DFF 通常只有一个 Track；SACD ISO 可以有多个 Track。

### 4.2 `DSDStream`

```swift
struct DSDFormat {
    let sampleRate: Int
    let channels: Int
    let bitOrder: DSDBitOrder
}

protocol DSDStream {
    var format: DSDFormat { get }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    func seek(to sample: UInt64) throws
}
```

DSF、DFF、SACD ISO 都不能把自己的文件布局泄漏到 DoP / PCM 层。

---

## 5. DSF Reader

DSF Reader 负责：

- 读取 `DSD ` chunk
- 读取 `fmt ` chunk
- 读取 `data` chunk
- 获取：
  - channel count
  - DSD sample rate
  - sample count
  - block size
- 读取 ID3 metadata
- 将文件中的 DSD 数据规范化为 `DSDStream`

第一版至少覆盖：

- DSD64
- DSD128
- DSD256
- Stereo

DSF 不需要 FFmpeg 才能解析，格式本身足够简单，可以自行实现或参考现有开源实现。

---

## 6. DFF / DSDIFF Reader

DFF（DSDIFF）与 DSF 一样，本质上是 DSD 音频容器，而不是另一种音频编码。

DFF 可能包含：

```text
.dff
  ↓
DSDIFF chunks
  ↓
┌───────────────┐
│ raw DSD       │──────────────┐
└───────────────┘              │
                               ├→ DSDStream
┌───────────────┐              │
│ DST compressed│ → DSTDecoder┘
└───────────────┘
```

需要处理：

- `FRM8`
- `FVER`
- `PROP`
- `FS  `
- channel layout
- raw `DSD ` chunk
- DST 相关 chunk / frame
- marker / comment 等可用 metadata

DFF 的 metadata 能力通常弱于 DSF，因此 UI 不应假设一定能得到完整 Artist / Album / Cover。

### 6.1 为什么 DFF 应与 DSF 同阶段实现

因为它对后续 SACD ISO 有直接价值：

1. DFF 与 SACD 都可能遇到 DST；
2. `DSTDecoder` 可由 DFF 与 SACD ISO 共用；
3. DFF 可以先验证 `DST → DSDStream`；
4. SACD ISO 阶段就只需增加 Scarlet Book / Area / Track / sector 层。

因此第一阶段目标应明确为：

```text
DSF ───────┐
           ├→ DSDStream → DoP / PCM
DFF ───────┘
```

---

## 7. SACD ISO Reader

SACD ISO 不是简单音频容器，而是完整 SACD 光盘镜像。

需要处理：

```text
SACD ISO
   ↓
Scarlet Book / TOC
   ↓
Area
 ├── Stereo / 2CH
 └── Multichannel
   ↓
Track
   ↓
Audio Frames
   ↓
raw DSD / DST
   ↓
DSTDecoder（如需要）
   ↓
DSDStream
```

第二阶段先支持 Stereo / 2CH Area。

### 7.1 DST 的性质

DST（Direct Stream Transfer）是 SACD 使用的无损 DSD 压缩。

```text
DST → DSD
```

是无损解压，不是：

```text
DSD → PCM
```

所以 DST 解压后仍然可以走 DoP。

### 7.2 实现策略

不建议从零重新实现 Scarlet Book ISO + DST。

优先评估并复用 `sacd_extract` / sacd-ripper 体系中的：

- SACD ISO / Scarlet Book 解析
- Area / Track 枚举
- frame 读取
- DST decoder

最终应包装成内部 library，而不是运行外部 CLI。

理想链路：

```text
SACD ISO
   ↓
SACDReader
   ↓
Track / Frame
   ↓
DSTDecoder（可选）
   ↓
DSDStream
```

不建议最终实现采用：

```text
ISO → 临时 DSF → 再播放
```

因为会带来：

- 首次播放等待
- 临时磁盘占用
- 无意义 SSD 写入
- Seek / Track 切换复杂
- gapless 难处理
- 生命周期复杂

开发 spike 阶段可以用临时提取验证数据正确性，但不作为正式架构。

---

## 8. DoP 实现

### 8.1 DoP 数据结构

概念上：

```text
24-bit PCM slot

┌────────┬────────┬────────┐
│ DSD    │ DSD    │ Marker │
│ 8 bit  │ 8 bit  │ 8 bit  │
└────────┴────────┴────────┘
```

Marker 按 DoP 规范交替变化，使 DAC 能识别出其中的 DSD payload。

`DoPEncoder` 应是纯流式转换器：

```text
DSDStream → DoPFrameStream
```

它不做：

- SRC
- 音量处理
- EQ
- mixer
- 浮点转换

### 8.2 DSD 与 DoP carrier sample rate

| DSD | DSD Rate | DoP Carrier |
|---|---:|---:|
| DSD64 | 2.8224 MHz | 176.4 kHz |
| DSD128 | 5.6448 MHz | 352.8 kHz |
| DSD256 | 11.2896 MHz | 705.6 kHz |

因此设备规格写“支持 DSD256”并不等于 macOS 下 DoP256 一定可用。

还必须确认：

> CoreAudio 是否允许把该设备设置到对应 carrier sample rate 与可承载 DoP 的 physical format。

---

## 9. CoreAudio 输出

### 9.1 普通音频保持现有链路

浮箔已经支持 macOS 原生音频格式，因此 MP3 / AAC / ALAC / FLAC / WAV / AIFF 等仍然使用现有实现。

不要为了加入 DSD 改造全部普通音频路径。

### 9.2 DoP 使用专用 HAL 输出

DoP 不建议经过普通 AVAudioEngine processing graph。

建议新增：

```text
HALAudioOutput
```

链路：

```text
DoP Buffer
    ↓
CoreAudio HAL
    ↓
AudioDevice
```

因为 DoP bitstream 不能被修改。

以下操作都可能破坏 DoP：

- sample rate conversion
- mixer
- volume scaling
- EQ
- DSP
- PCM format conversion

### 9.3 Hog / Exclusive Mode

DoP 模式优先取得设备独占控制。

目标：

- 防止其他应用同时混音
- 防止系统改变设备采样率
- 保证 physical format 在播放期间稳定

需要处理：

- 无法取得独占权限
- 设备被其他应用占用
- 用户拔出 DAC
- 睡眠 / 唤醒
- 默认设备变化
- App 退出后恢复设备状态

---

## 10. 设备能力探测

不要通过 DAC 名称或厂商白名单判断。

建议：

```swift
struct DSDOutputCapability {
    let supportsDoP64: Bool
    let supportsDoP128: Bool
    let supportsDoP256: Bool
}
```

例如播放 DSD128：

1. 目标 carrier = 352.8 kHz；
2. 查询目标 `AudioDevice` 的 stream physical formats；
3. 查找满足：
   - sample rate = 352800
   - channels >= source channels
   - bit depth / packing 可承载 DoP
4. 尝试设置 physical format；
5. 尝试建立 HAL output；
6. 成功后才进入 DoP。

不要只因为 DAC 参数写着 DSD512 就推断 DoP 一定可用。

---

## 11. 自动输出策略

默认策略：

```text
打开 DSD
   ↓
Probe 当前设备
   ↓
支持当前 DSD rate 的 DoP？
   │
   ├── Yes
   │     ↓
   │   尝试 Hog / Exclusive
   │     ↓
   │   初始化 DoP
   │     │
   │     ├── Success → DoP
   │     └── Failure → PCM fallback
   │
   └── No
         ↓
      PCM fallback
```

用户默认不需要理解这些细节。

UI 只需要显示最终状态，例如：

```text
DSD64 · DoP · SMSL USB AUDIO
```

或：

```text
DSD64 → PCM 176.4 kHz · Mac Speakers
```

高级选项可提供：

```text
DSD Output

● Automatic
○ Prefer DoP
○ Always convert to PCM
```

默认 `Automatic`。

---

## 12. DSD → PCM fallback

这是整个方案中真正涉及“DSD 解码”的部分。

第一阶段优先保证：

- 正确
- 稳定
- CPU 成本合理
- 不爆音
- 不削波

### 12.1 输出采样率策略

优先保持 44.1 kHz family：

```text
352.8
176.4
88.2
44.1
```

例如：

```text
DSD64  → 176.4 kHz PCM（设备允许时）
DSD128 → 176.4 / 352.8 kHz PCM
DSD256 → 176.4 / 352.8 kHz PCM
```

如果目标设备不支持高采样率，就继续降级。

不要机械追求最高 PCM sample rate；应优先选择质量、CPU 与设备兼容性之间合理的档位。

---

## 13. Ring Buffer 与实时线程

HAL callback 中不能做：

- 文件 IO
- malloc/free
- Swift async/await
- 长时间锁等待
- DST 解码
- DSD → PCM 重计算

建议：

```text
DSF / DFF / ISO Reader
          ↓
     Decode Thread
          ↓
Lock-free / bounded Ring Buffer
          ↓
    HAL realtime callback
```

HAL callback 只负责：

> 从已经准备好的 buffer 向设备 buffer 搬运数据。

DoP 与 PCM fallback 共用这一模型。

---

## 14. Seek

### 14.1 DSF

根据：

- block size
- channel count
- sample rate

建立 sample → file offset 映射。

Seek 后要正确重建 DoP marker phase。

### 14.2 DFF raw DSD

根据 DSD chunk 与 sample layout 建立对应 seek 映射。

### 14.3 DFF DST

DST 需要按可解码 frame 边界恢复，不能假设能从任意压缩字节位置开始。

建议为 DST stream 建立轻量 seek index。

### 14.4 SACD ISO

Track 内 Seek：

```text
time
 ↓
SACD frame
 ↓
sector / packet
 ↓
raw DSD / DST frame
```

SACD reader 自己维护 `TrackSeekIndex`，不要让 UI / PlaybackController 理解 ISO sector。

---

## 15. Gapless 与 Track 切换

SACD 很常见连续 Track，不能简单：

```text
Track A stop
→ teardown device
→ Track B open
→ restart device
```

建议：

```text
Decoder A ──┐
            ├→ shared ring buffer → HAL
Decoder B ──┘
```

下一 Track 提前 prepare。

如果相邻 Track：

- DSD rate 相同
- channel layout 相同
- 输出模式相同

就不要重新初始化 AudioDevice。

对用户一次打开的多文件 DSF / DFF 列表，也可以复用同一 gapless 机制。

---

## 16. 音量策略

### 16.1 DoP

DoP 下禁止软件音量修改 bitstream。

建议：

- 如果 CoreAudio 暴露设备硬件音量，则控制硬件音量；
- 如果设备没有硬件音量，则禁用软件音量；
- UI 显示 `Bit-perfect / Fixed Volume`。

不能为了保留音量滑块而修改 DoP frame。

### 16.2 PCM fallback

可以继续使用正常的软件音量策略。

---

## 17. 设备切换

例如：

```text
D6s (DoP)
   ↓
Mac Speakers
```

应自动：

```text
stop HAL
↓
release hog
↓
probe Mac Speakers
↓
DoP unavailable
↓
prepare DSD → PCM
↓
resume
```

反向：

```text
Mac Speakers (PCM)
   ↓
D6s
```

重新 probe 后可升级到 DoP。

默认策略：

> 设备切换后重新建立当前设备的最佳输出链路。

---

## 18. UI 设计

### 18.1 DSF / DFF

保持浮箔现有“文件查看器”逻辑：

```text
┌────────────────────────────────┐
│              Cover             │
│                                │
│        Beethoven ...           │
│        Track title             │
│                                │
│  ━━━━━━━━━●━━━━━━━━━━━━        │
│  01:24                06:32    │
│                                │
│        ◀︎     ▶︎     ▶︎|        │
│                                │
│ DSD64 · DoP · SMSL USB AUDIO   │
└────────────────────────────────┘
```

### 18.2 SACD ISO

ISO 天然包含多个 Track：

```text
SACD.iso

01  Allegro con brio       15:22
02  Andante                10:31
03  Scherzo                 5:18
04  Allegro                11:02
```

这个列表与 PDF 页列表、EPUB 章节列表属于同一种抽象：

> 当前文件内部导航，而不是音乐资料库。

第一版只支持 Stereo Area 时，可以不显示 Area 选择；后续加入 Multichannel 后再提供：

```text
Area
● Stereo
○ Multichannel
```

---

## 19. 状态与错误处理

建议状态机：

```text
idle
 ↓
opening
 ↓
probingDevice
 ↓
preparingDoP / preparingPCM
 ↓
playing
 ↕
paused
 ↓
stopped
```

错误类型至少包括：

```text
deviceDisconnected
deviceBusy
unsupportedDoPRate
invalidDSF
invalidDFF
invalidSACDISO
DSTDecodeFailure
decoderFailure
outputInitializationFailure
```

DoP 初始化失败默认不是致命错误：

```text
DoP failed
   ↓
PCM fallback
```

UI 可提示：

> 当前设备无法使用 DSD64 DoP，已切换为 PCM 176.4 kHz。

---

## 20. 可复用开源实现评估

### 20.1 SFBAudioEngine

可用于参考或 spike：

- DSF
- DSDIFF
- DoP
- DSD → PCM
- Swift / Objective-C API

建议重点验证：

```text
DSF raw DSD → DoP
DSF → PCM
DFF raw DSD → DoP
DFF DST → DSD → DoP
DFF DST → DSD → PCM
```

同时测量：

- Release App size 增量
- 启动影响
- CPU / 内存
- D6s 实机表现
- 许可证与打包影响

如果整体成本很低，直接复用可能比自行维护 DSD pipeline 更划算。

### 20.2 sacd_extract / sacd-ripper

适合复用：

- SACD ISO
- Scarlet Book
- Area / Track
- DST → DSD

重点不是调用 CLI，而是把核心代码包装成可流式读取的 library。

---

## 21. 依赖策略

优先使用 macOS 系统能力：

```text
SwiftUI
AppKit
AVFoundation
AudioToolbox
CoreAudio
```

普通音频继续走系统链路。

DSD / SACD 只补充必要能力：

```text
DSF parser
DFF / DSDIFF parser
DoP encoder
DSD → PCM
DST decoder
SACD ISO / Scarlet Book parser
```

原则上避免因为这项功能默认引入：

```text
Qt
完整 FFmpeg
大型跨平台播放器框架
媒体库框架
完整 DSP framework
```

不是因为这些方案技术上不好，而是与浮箔“极轻量文件查看器”的定位不匹配。

如果实测完整 FFmpeg 或某个现成库的 Release size 增量很小，也应以实际工程成本为准，而不是教条地拒绝依赖。

---

## 22. 测试方案

### 22.1 文件矩阵

至少准备：

```text
DSF
├── DSD64 Stereo
├── DSD128 Stereo
└── DSD256 Stereo

DFF
├── raw DSD64 Stereo
├── raw DSD128 Stereo
├── DST DSD64 Stereo
└── DST DSD128 Stereo

SACD ISO
├── Stereo raw DSD
├── Stereo DST
├── Stereo + Multichannel
└── 多 Track / gapless
```

还需要：

- 有 metadata
- 无 metadata
- 大封面
- 损坏 DSF
- 损坏 DFF
- 损坏 ISO
- 非典型 block / frame 边界

### 22.2 设备矩阵

第一开发参考设备：

```text
SMSL D6s
```

同时测试：

```text
Mac internal speakers
Bluetooth / AirPods
普通 USB PCM DAC
另一台 DoP DAC
```

D6s 只能作为 reference device，代码不能硬编码设备名。

### 22.3 DoP 验证

不能只验证“有声音”。

必须确认 DAC 显示：

```text
DSD64
DSD128
DSD256
```

而不是仅显示：

```text
PCM 176.4
PCM 352.8
PCM 705.6
```

同时测试：

- pause / resume
- seek
- 单文件循环
- 多文件切换
- SACD Track change
- DAC unplug / replug
- sleep / wake
- 多应用抢占设备

---

## 23. 实施阶段

### Phase 0：技术 Spike

目标：

```text
sample.dsf
sample-raw.dff
sample-dst.dff
      ↓
   DSDStream
      ↓
┌─────┴──────────────┐
│                    │
D6s → DoP        Mac Speakers → PCM
```

不做正式 UI。

验收：

1. DSF 能稳定读取；
2. raw DSD DFF 能稳定读取；
3. DST DFF 能无损解压为 DSDStream；
4. D6s 能正确识别 DSD64 / DSD128；
5. Mac 内置输出能自动降级 PCM；
6. DoP / PCM 可以自动选择；
7. 记录 Release App size 增量。

### Phase 1：DSF / DFF 正式支持

实现：

- DSF Reader
- DFF / DSDIFF Reader
- DSTDecoder
- metadata
- `DSDStream`
- DoP
- PCM fallback
- HAL output
- seek
- device switching
- Audio Viewer UI

验收：

> 用户双击或拖入 `.dsf` / `.dff`，行为与打开其他浮箔支持文件一致。

### Phase 2：SACD ISO

实现：

- ISO / Scarlet Book
- Stereo Area
- Track list
- raw DSD
- DST → DSD
- Track seek
- gapless

最终链路：

```text
SACD ISO
   ↓
Track
   ↓
raw DSD / DST
   ↓
DSDStream
   ↓
OutputRouter
   ├── DoP → DAC
   └── PCM → other device
```

### Phase 3：完善

评估：

- Multichannel SACD
- 更复杂的 DSD128 / DSD256 PCM fallback 策略
- Native DSD
- APE
- WavPack
- 高级输出设备设置

---

## 24. 第一版技术决策

| 项目 | 决策 |
|---|---|
| UI | SwiftUI / 现有浮箔 UI |
| 普通音频 | 保持现有 macOS 原生链路 |
| DSF | 第一阶段支持 |
| DFF / DSDIFF | 与 DSF 同阶段支持 |
| DFF raw DSD | 直接进入 `DSDStream` |
| DFF DST | `DSTDecoder` 无损解压后进入 `DSDStream` |
| DSD 输出 | DoP 优先 |
| DoP Output | CoreAudio HAL |
| Exclusive | DoP 时尽量 Hog Mode |
| DoP 不支持 | 自动 DSD → PCM |
| SACD ISO | 第二阶段支持 |
| SACD DST | 与 DFF 共用 `DSTDecoder` |
| ISO 播放 | 流式，不生成临时 DSF |
| Native DSD | 第一版不做 |
| FFmpeg | 不因 DSD/SACD 默认引入 |
| Qt | 不引入 |
| Music Library | 不做 |
| 参考设备 | SMSL D6s，但不硬编码 |

---

## 25. 关键风险

### 25.1 CoreAudio 并不等于 bit-perfect

必须实测：

- physical stream format
- mixer / SRC 是否绕开
- Hog Mode
- HAL buffer layout
- DoP marker 是否完整

### 25.2 DFF 中的 DST 增加了第一阶段复杂度

但它值得提前解决，因为 SACD ISO 同样需要 DST。

正确依赖关系应是：

```text
Phase 1
DSF + DFF + DST
      ↓
完整 DSDStream pipeline
      ↓
Phase 2
SACD ISO / Scarlet Book
```

而不是把 DFF 放到 SACD 之后。

### 25.3 SACD ISO 工程量明显大于 DSF / DFF

DSF / DFF 是单文件音频容器；SACD ISO 还包含：

- 光盘结构
- Area
- Track
- frame / sector
- DST

因此先把 DSF / DFF / DST / DoP / PCM fallback 跑通，再接 ISO。

### 25.4 不要过早做 Native DSD

在 macOS 上 DoP 是更现实的第一目标。

只要 DSD payload 不变，DoP 与 Native DSD 在“是否发生 DSD → PCM”这个问题上没有本质区别。

### 25.5 软件音量与 DoP 冲突

DoP bitstream 不能经过普通 PCM 音量缩放。

这个约束必须从 UI 与播放引擎设计阶段就接受。

---

## 26. 产品定义

加入 DSD / SACD 后，浮箔仍然不是“音乐管理器”。

```text
.jpg      → Image Viewer
.pdf      → PDF Viewer
.md       → Markdown Viewer
.epub     → EPUB Viewer
.mp4      → Video Viewer
.flac     → Audio Viewer
.dsf      → DSD Audio Viewer
.dff      → DSD Audio Viewer
SACD.iso  → SACD Audio Viewer
```

SACD Track 列表与 PDF 页列表、EPUB 章节列表属于同一种抽象：

> 当前文件内部的导航结构。

这使浮箔可以增加高品质本地音频能力，而不引入音乐曲库的产品复杂度。

---

## 27. 建议下一步

先做完全与正式 UI 解耦的 `DSDPlaybackSpike`：

```text
Input:
  sample.dsf
  sample-raw.dff
  sample-dst.dff

Output:
  [Auto]
      ├── D6s → DoP
      └── Mac Speakers → PCM
```

只验证：

1. DSF → `DSDStream`
2. DFF raw DSD → `DSDStream`
3. DFF DST → `DSTDecoder` → `DSDStream`
4. `DSDStream` → DoP → D6s
5. `DSDStream` → PCM → Mac Speakers
6. 自动输出策略
7. Release App size 增量

这些成立后再接入浮箔现有 Audio Viewer；SACD ISO 放到第二阶段，只增加 ISO / Scarlet Book / Track 层，并复用已经验证过的 DST、DSDStream、DoP、PCM fallback 与 HAL 输出链路。

---

## 28. 参考实现

- SFBAudioEngine  
  https://github.com/sbooth/SFBAudioEngine  
  用于参考或快速验证 DSF、DSDIFF、DoP、DSD → PCM。

- sacd_extract / sacd-ripper  
  https://github.com/jmmaloney4/sacd-extract  
  用于参考 SACD ISO / Scarlet Book / Track / DST → DSD。

- Apple CoreAudio / Audio Hardware Services  
  最终 DoP 输出重点围绕 physical format、HAL I/O callback、设备独占与设备状态管理设计。
