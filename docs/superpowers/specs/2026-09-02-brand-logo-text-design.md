# 品牌区文字化设计(2026-09-02)

## 目标

右边栏底部品牌区目前是一整幅图片(`BrandLogo.imageset`,含图形标记 + FrameScoop 大字 + 中文标语 + version 1.0)。改为「图形标记保留图片 + 三行文字」,显示效果与原图一致(大小比例、颜色、透明度、明暗双模式适配)。

## 现状

- 引用点仅一处:`FrameScoop/Views/FilterSidebarView.swift:129`(`Image("BrandLogo")`,私有 `brandLogo` 计算属性,行 128-136)。
- 容器样式:`.resizable().scaledToFit().opacity(0.55).padding(.vertical, 14).padding(.horizontal, 12).frame(maxWidth: .infinity)`。
- 原图 480×281,两变体(dark 供浅色 UI、light 供深色 UI)。内容自上而下:图形标记(≈y20-95,高约 27%)、FrameScoop 粗体(34px,≈12%)、标语「光影为诗，拾帧成集」(≈11%)、version 1.0(≈4%)。文字色:浅色 UI 用 rgb(79,79,81),深色 UI 用 rgb(236,236,236)。

## 方案

### 1. 新资产 BrandMark.imageset

- 脚本从现有两变体裁剪顶部图形标记:扫描 alpha 通道求内容边界框,四边各留少量余量,输出 `framescoop-mark-dark.png` / `framescoop-mark-light.png`(命名沿用 luminosity 语义:dark=浅色 UI 用,light=深色 UI 用)。
- `Contents.json` 与现有 BrandLogo 同构:universal + luminosity dark/light 两个 appearance 条目。
- 裁剪完成后删除 `BrandLogo.imageset`(无其他引用)。

### 2. FilterSidebarView.brandLogo 改为 VStack 四层

```
VStack(spacing: 按比例) {
    Image("BrandMark")   // resizable/scaledToFit,高度 ≈ 总高 27%
    Text("FrameScoop")   // SF Pro bold,字高 ≈ 总高 12%
    Text("光影为诗，拾帧成集") // 常规字重,字高 ≈ 总高 11%
    Text("version \(ver)")    // 小字,字高 ≈ 总高 4%
}
```

- 整体保持现有容器样式:`scaledToFit` 改为宽度约束下的等比缩放,保留 `.opacity(0.55)`、`.padding(vertical 14, horizontal 12)`、`.frame(maxWidth: .infinity)`、居中。
- 文字颜色用 `.foregroundStyle(.primary)`:系统明暗自动适配,等效于原图两套灰(79,79,81 / 236,236,236),无需两套颜色。
- 字号以原图相对比例映射到实际渲染宽度(原图按宽度缩放到侧边栏宽,高度 = 宽 / 1.708,各层字高取对应百分比)。

### 3. version 行

- 动态读取 `Bundle.main` 的 `CFBundleShortVersionString`(MARKETING_VERSION),取前两位组件(如 1.0.0 → "version 1.0"),与原图显示一致且随版本自动更新。

## 改动文件

- `FrameScoop/Assets.xcassets/BrandMark.imageset/`(新增,含裁剪脚本产物)
- `FrameScoop/Assets.xcassets/BrandLogo.imageset/`(删除)
- `FrameScoop/Views/FilterSidebarView.swift`(brandLogo 重写)

## 验证

1. `xcodebuild` 构建通过。
2. 运行 app,浅色/深色模式各目测一次,对比原效果:元素齐全(标记/FrameScoop/标语/version)、整体透明度 0.55、位置在右边栏底部、宽度自适应。

## 权衡与已知差异

- 字体:原图字体无法从图片识别,用系统 SF Pro(粗体/常规)最接近;如用户提供原字体名可替换。
- 文字抗锯齿/字距与原图位图渲染有细微差异,属预期。
- 放弃整幅图片后,品牌区不再依赖图片重绘(标语改动无需重新出图)。
