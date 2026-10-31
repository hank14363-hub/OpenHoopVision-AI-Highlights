<div align="center">
  <img src="./assets/logo.png" width="120" alt="AI Highlights 标志" />
</div>
<h3 align="center"><b>AI Highlights</b></h3>
<p align="center">
  <a href="./README.md"><img src="https://img.shields.io/badge/README-English-blue?style=flat-square" alt="English README" /></a>
</p>

**TL;DR：** AI Highlights 是从 [OpenHoopVision](https://github.com/feifeifei85/OpenHoopVision) 项目衍生出的原生 iOS 集锦工具：在设备本地筛选比赛视频中的进球候选，供用户复核并导出为 MP4。

## 演示截图

<table>
  <tr>
    <td align="center" width="16.66%"><a href="assets/home.jpg"><img src="assets/home.jpg" width="100%" alt="AI Highlights 首页和视频导入选项"></a><br><sub>导入</sub></td>
    <td align="center" width="16.66%"><a href="assets/analysis-progress.jpg"><img src="assets/analysis-progress.jpg" width="100%" alt="显示视频分析进度的资料库页面"></a><br><sub>分析</sub></td>
    <td align="center" width="16.66%"><a href="assets/analysis-complete.jpg"><img src="assets/analysis-complete.jpg" width="100%" alt="显示分析完成和投篮候选数量的资料库页面"></a><br><sub>结果</sub></td>
    <td align="center" width="16.66%"><a href="assets/review.jpg"><img src="assets/review.jpg" width="100%" alt="显示已检测和不确定投篮候选片段的复核页面"></a><br><sub>复核</sub></td>
    <td align="center" width="16.66%"><a href="assets/exported-highlight.jpg"><img src="assets/exported-highlight.jpg" width="100%" alt="提供分享和存入照片图库操作的集锦导出页面"></a><br><sub>导出</sub></td>
    <td align="center" width="16.66%"><a href="assets/settings.jpg"><img src="assets/settings.jpg" width="100%" alt="语言、阈值和片段时长设置"></a><br><sub>设置</sub></td>
  </tr>
</table>

## 功能

- **严格候选筛选（0.2.0）：**只有“普通篮球在筐上 → 入网目标在筐口 → 普通篮球落到筐下”的三帧时序同时满足轨迹、位置和球框形状检查，才生成视觉候选。外观命中、仅入网类别的抖动、普通球轨迹不再进入待复核列表；比分变化仍可独立补充候选。缺少完整证据的真实进球可能漏掉，可手动补充。
- **本地进球候选检测：**使用内置 Core ML 模型筛选可能的进球片段，并提供置信度供复核。
- **转播比分补充：**在画面底部 30% 区域存在带队名的清晰比分条时，使用设备端 Vision OCR 补回远景候选。连续确认单队增加 1—3 分后，标注“比分变化 · 需核对时点”；考虑到比分更新延迟，至少保留估计事件前 8 秒、后 3 秒。仅由比分提供的候选不显示虚构的模型置信度。
- **低分辨率计分牌：**当 `HOME` 和 `GUEST` 位于比分上方时，App 会放大计分牌区域再次 OCR；模型也会围绕检测到的篮筐重试，不依赖固定的球场坐标。
- **可调阈值与人工复核：**调整检测和复核阈值，检查不确定候选，并可手动添加或移除时刻。
- **灵活制作集锦：**调整片段前后延展时长，按原视频顺序合并重叠片段，保留可用原始音轨并导出 MP4。

## AI 模型与性能

YOLO26n 篮球检测模型基于 [OpenHoopVision](https://github.com/feifeifei85/OpenHoopVision) 项目训练，使用 Ultralytics 官方实现，并以输入尺寸 1280 × 736 的 INT8 Core ML 格式集成。iOS 推理实现参考了 [Ultralytics YOLO iOS app](https://github.com/ultralytics/yolo-ios-app)。前台分析启用 `.all`，由 Core ML 选择 CPU、GPU 或 Neural Engine；不强制仅用 GPU。后台推理仅使用 CPU。

分析会按时间顺序扫描整段视频，采样上限为 30 帧/秒，因此长视频需要更长时间；后台运行受 iOS 调度限制。一次 iPhone 16 Pro Max 示例显示处理速度为 47.6 帧/秒，这不是标准化基准。

## 范围与限制

- 机位不佳、画质较低、遮挡或远景都可能降低检测可靠性。
- 全图与局部裁剪都会扣除模型等比缩放产生的留边，再统一为原图坐标。运动证据使用原图宽度作为横纵共同单位，并在时间间断或篮筐位置突变时中断关联。二维穿筐轨迹仍可能把近筐擦过误当进球，遮挡也可能让真正进球无法生成候选；这不是准确率保证，模型权重没有重新训练。比分首次出现、长时间中断、回退修正或大幅跳分不会直接生成进球。比分时间减 2 秒仅是估计；缺少比分条时继续使用画面识别。回放、OCR 漏读与持续模型误判仍需人工复核。局部重试最多增加两次模型推理，OCR 和保存轨迹证据也会增加处理与存储开销。旧分析需重新运行；继续或缓存重算会使用同一套轨迹判断。
- App 仅提供投篮候选供复核，不识别球员，也不提供记分或全场统计。
- 仓库包含 App 源码和转换后的模型，不含训练数据与配置、原始 checkpoint 或模型导出脚本。

## 隐私与数据

视频分析和集锦生成均在设备端完成。AI Highlights 不会将视频上传至自身服务，也不使用分析 SDK。App 存储中的视频和项目数据可能包含在 iOS 设备备份内。从 iCloud 或其他云端位置选择视频时，照片或“文件”可能会通过网络下载素材。

## 环境要求与构建

- iOS / iPadOS 18 或更新版本
- 支持 iOS 开发的 Xcode

使用 Xcode 打开 `AI Highlights.xcodeproj` 并选择 `AI Highlights` scheme。也可以在项目目录中执行以下不签名构建：

```sh
xcodebuild -project "AI Highlights.xcodeproj" -scheme "AI Highlights" \
  -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## 许可证

AI Highlights 是用于个人学习与实验的开源项目。整个项目（包括 App 源码和内置 YOLO26n 模型）采用 AGPL-3.0，详见 [LICENSE](LICENSE)。Ultralytics 要求专有或商业部署使用 Enterprise License，具体以其[许可条款](https://www.ultralytics.com/license)为准。
