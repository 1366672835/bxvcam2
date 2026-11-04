# BXFloatVCam —— 虚拟摄像头 1.0.3

把摄像头画面替换成 **RTSP 直播流** 或 **本地视频**，并把 **摄像头音频替换成流音频**。
注入抖音后可拍摄 / 可直播，效果与「百相 0.20.33」的视频、音频链路一致。

无卡密、无联网、无授权校验。

---

## 一、能力

| 能力 | 说明 |
|---|---|
| RTSP 拉流替换 | TCP，6 秒截止，断流不重连（与原版一致） |
| 本地视频替换 | 循环 / 镜像 / 旋转 |
| **音频注入** | 流音频替换麦克风（通过 AudioUnit 层重绑，非 AVCapture） |
| 诊断面板 | 运行状态 + 诊断，实时看读取/替换/停顿 |

注入方式：5 个 `method_setImplementation`（视频/音频 delegate setter、`addOutput:`、`startRunning`、`stopRunning`）
+ 1 个 delegate 桥（`class_replaceMethod`），与反汇编出的原版一致。

---

## 二、与原版的关系

**一致的**

```
开流参数      rtsp_transport=tcp / timeout=5s / rw_timeout=5s / buffer_size=1MB
截止          6 秒
断流          不重连，seek 仅用于本地循环
解码          软解，无解码器参数
缩放          sws 源尺寸→源尺寸，AV_PIX_FMT_0x1c，BILINEAR
取帧          单槽，只 retain 不清空
写入          VT 直写摄像头像素缓冲（GPU→GPU）
预览          VT 复制一份 BGRA 再进 CoreImage
音频解码      swr → float32 环形缓冲
音频注入      fishhook 重绑 AudioUnitRender，input_bus=1，ASBD 自适应
```

**有意不一致的**

```
帧队列        原版单槽，我们 6 格队列（每拍取一帧）
              → 实测 7.9 → 20.3 次/秒，这是"不卡"的关键
节流          原版每帧 usleep，我们不做
              → 实测加上会从 24fps 降到 11.6fps，画面像慢放
```

**没有的**

```
音量键手势 / 多 App 图标 / 授权系统
```

---

## 三、面板

| 入口 | 内容 |
|---|---|
| 虚拟摄像头 | 总开关（关掉后 100% 直通） |
| RTSP 拉流 | 流地址、优先 TCP、循环、镜像、旋转、声音替换 |
| 选择视频 | 本地 mp4/mov |
| 运行状态 | 读取/解码/替换 fps、包间隔、停顿、直通原因 |
| 诊断 | 一行行键值，可长按全选复制 |

排查时最有用的是「运行状态」这两行：

```
读取 fps       源送来多少帧（24 为正常）
替换 fps       实际写入摄像头缓冲的次数
直通           有多少拍交出了真实摄像头（未接管 / 取帧为空）
```

---

## 四、设置键

```
rtsp.enabled      总开关
rtsp_url          流地址
rtsp.loop         本地/流循环
rtsp.mirror       镜像
rtsp.rotation     旋转 0/90/180/270
prefer_tcp        是否优先 TCP（强烈建议开，UDP 实测收不到数据）
rtsp.audio_mode   声音替换开关
```

---

## 五、编译与注入

```bash
export THEOS=~/theos
make
# 产物：.theos/obj/*/BXFloatVCam.dylib
```

云端编译见 `BUILD-CLOUD.md`（GitHub Actions，会自动编 FFmpeg 静态库）。

注入：TrollStore + TrollFools → 选目标 App → 注入 dylib → 打开 App。

---

## 六、已知限制

- 网络断流超过约 250ms（队列深度）时画面会顿一下，这是缓冲上限，非代码缺陷
- 抖音不使用 `AVCaptureAudioDataOutput`，所以音频必须走 AudioUnit 层；若某 App 用别的采音方式，音频注入不生效
- 采集像素格式若不是 BGRA，VT 转换可能失败（诊断面板 `VT错误` 会增长）
- 音量键功能未接入

---

## 七、目录

```
Makefile                构建脚本
Tweak.xm                注入入口
BXCore/                 悬浮面板 / 菜单 / 预览 / 持久化 / 音量键类
VCam/
  BXFFmpegRTSP.m        RTSP 拉流 + 解码 + 队列 + 音频环
  BXCaptureBridge.m     delegate 劫持 + 帧写入 + 音频采样缓冲
  BXAudioUnitHook.m     AudioUnit 输入总线钩子（音频注入）
  BXFishhook.c          按符号名重绑（Mach-O 解析）
  BXVideoSource.m       本地视频
  BXLocalAudio.m        本地视频音轨
BXModules/              面板开关
docs/（可选）           反汇编笔记
```
