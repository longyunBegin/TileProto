# Try Shoji Live 完整规格（shojimac.com 顶部互动 demo）

> 2026-10-27，REA 逆向 + 显示文本精读 + 13:04 浏览器实测对照。
> 用途：把 demo 里的全部功能原样搬运到 TileProto 的参照规格。
> 范围：只描述行为与实现思路，不贴原始代码、不搬素材、不碰授权验证与 license 逻辑。
> 逆向证据：`~/workspace/shoji-demo-js/`（`rea/behavior-report.md` 为行为清单底本，
> `rea/rea-output.json` 为 REA 原始输出，`deps/FETCH-NOTES.md` 为补齐与失真记录）。
> 置信度说明：凡引自 browser.open 显示文本的条目，原文有缺损段（见文末“未确证”），
> 相关条目标注“置信度中”；其余结论来自本地完整文件与浏览器实测。

## 0. 这是什么 demo

- shojimac.com 顶部的可交互网页模拟：用一套与正式版相同的布局与快捷键，
  在浏览器里模拟 macOS 桌面平铺。官网 FAQ 原话：买前不能试用，
  去页面顶部玩 live demo，它 tiles windows the way the app does。
- demo 本身是单屏画布，不模拟第二块屏、不采集真实窗口、不做持久化、不走授权流程。
  真实应用的窗口采集、多屏、持久化、授权均不在 demo 代码中。
- 演示区可全屏（按容器缩放，其余行为与嵌入模式相同）。

## 1. 初始状态与窗口模型

- 初始 3 窗，未整理态（tidied=false）：browser、notes、terminal。
  自由帧按 1440×900 基准缩放：browser 150,80 760×520；notes 700,170 520×430；
  terminal 300,440 620×280。z 顺序 [1,2,3]，active=3（terminal 在最前）。
- 窗口记录：{id, app, variant, free:{x,y,w,h}}；另有 z 序列、used（最近使用计数）
  与 clock（逻辑时钟，每次激活/打开递增）。“最近使用”以 used/clock 为准，
  不是真实时间。
- 演示应用共 6 款（Dock 顺序 files、browser、notes、mail、music、terminal），
  每款有自然尺寸与若干 variant 内容（同款多开时轮换正文）：
  browser 620×430、notes 500×380、terminal 540×320、files 560×380、
  mail 600×400、music 520×400。
- 上限：demo 最多 9 窗；超限提示「That’s plenty for a demo / On your Mac,
  open as many as you like.」。

## 2. 布局模式与排布数学

### 2.1 四种样式

- fold（面板里叫 Grid）：一大窗 + 其余在旁。
- columns：并排。
- rows：上下全宽。
- side：一大窗 + 其余一列在旁。
- 名称：1 格 Full screen；rows：Two/Three rows；2 格 Side by side；
  side：One big, two/three beside；columns：Three/Four columns；
  fold：One big, two small / Grid of four。

### 2.2 画布与间距

- 菜单栏 24 + Dock 78；工作区 = {x:0, y:24, w, h-24-78}；
  演示画布 ≥900 高时用 1440×900，否则 820×640。
- 间距 gap：默认 8，设置滑杆 0–24（步进 2），同时用作屏边缘留白。
  有效 gap = max(设定 gap, 边框宽)（边框模式时）；glow 模式时至少 4。

### 2.3 格子数 fit

- limit 先 clamp 到 1–4。
- rows：宽屏时 min(limit, 3, 按高算得的排数），窄屏（h>w）恒 rows 且最多 3。
- columns：min(limit, 按宽算得的列数）。
- side：min(limit, 1+按高算得的排数）。
- fold：limit 本身。
- 另有规则：高屏（h>w）样式强制 rows。
- 设置页注记：Columns 在 MacBook 上 3 列、大屏 4 列，Rows 2–3 排，
  Side 3–4 格，高屏恒 rows。

### 2.4 帧计算

- 先把工作区内缩 gap；对 1..min(窗口数, fit)逐个尝试：
  只有当全部格子宽 ≥ minSection.w 且高 ≥ minSection.h（基准 480×320 按屏缩放；
  columns 时宽下限改用 minColumnWidth = 440 缩放值）才接受该格子数，
  否则降一格；单窗恒接受。
- 主窗份额 mainShare：默认 fold/side 首格 0.5、其余 1/(n-i)；
  用户可选 Half（null）/ 60% / Two-thirds；
  若默认份额下装不下且无自定义 ratios，对 mainShare 做 12 轮二分收敛，
  找能装下的最大份额。
- 比值 ratios：拖缝与 ⌃⌥=/- 写入，clamp 到 0.05–0.95；⌃⌥0 清空；
  改样式/上限时清空；面板有 ratios 时出现 Reset sizes。

### 2.5 分组与分隔缝几何（置信度中）

- side：首格 [0] + 其余每格一组。
- fold 且 4 格：[{first:[0,3], second:[1,2], sideBySide}, {first:[1], second:[2]},
  {first:[0], second:[3]}]。
- 其余：每格一组，sideBySide 按样式与奇偶定。
- 分隔缝几何：按分组取并集框，sideBySide 时为竖缝（缝在首格右缘），
  否则为横缝（缝在首格下缘），并给出 start/available 供拖缝换算。
- 拖缝换算：(指针坐标 - gap/2 - start) / available，再 clamp 到 0.05–0.95；
  动画插值：目标 ratios 先直接试，若帧数不符则对整体缩放做 20 轮二分，
  仍不符则线性插值过渡。
- 方向判定：24px 容差判断上下左右邻接，取重叠最大、距离最近的邻格，
  供 ⌃⌥方向键交换定位。

## 3. 悬停条

- 出现条件：hoverBar 开关开 + 已整理 + 平铺开 + 活动窗口有帧 +
  （活动窗口是某格顶层 或 悬浮窗）+ 不在拖动中 + Tab 视图未开 + Clean Space 未开。
  悬停目标是活动窗口（非指针下窗口）。
- 触发：指针进入活动格握把区 → 150ms 后出条；指针离开条 → 350ms 后关闭
  （进入条则清除关闭计时）；条打开 400ms 内的点击被吞掉（防误触）；
  条动画：入场 opacity 0→1、scale .96→1（.14s easeOut），退场 .12s。
- 位置：以握把中心为锚点居中，宽 440、高 54（堆叠时 +36 的芯片行），
  在工作区内按 6 margin 夹取不溢出。
- 按钮（自左至右，附 ⌃⌥键帽提示）：
  1. Primary（⌃⌥↩，makePrimary）：已是首格（tiled[0]）或悬浮窗时 disabled。
  2. Focus / Exit focus（⌃⌥Z，toggleZoom）：悬浮窗时 disabled；已专注时文案变 Exit focus。
  3. Tile / Float（⌃⌥F，toggleFloat）：永不 disabled；悬浮窗时文案变 Tile。
- 堆叠行（格成员 >1 时出现在按钮行上方）：‹（上一个成员）+ 成员芯片
  （应用图标 + 名；点按激活该成员；按住芯片可拖到另一格进堆，
  title 写明“Click to show it, or drag it onto another tile”）+ ›（下一个成员）。
- 点任一按钮后条消失。

## 4. 堆叠

- 握把（grip）：位于活动格顶缘中央，热区 48×18；单窗时为药丸
  （32×5，靠近时 44×5）；多窗时为一组圆点标记（显示中 26×6、其余 10×6、
  间距 4），总宽 = 26 + (n-1)×14，堆叠格再 +16。
- 格子顶部圆点行（dots）：非活动堆叠格的顶缘上方（格子上沿 - gap/2 - 7）
  有一排小圆点（显示中 16×6、其余 7×6、间距 4），点按切换成员。
- 进堆规则：
  a. 新窗开满时（见 §10）：whenFull=stack 时，新窗直接进活动格顶层；
     whenFull=float 时，新窗居中浮动（见 §7）。
  b. 重算时未分到格子的窗（overflow）：并入成员“最近使用”最久的格
     并成为顶层，首现一次提示「Stacked in this tile / Press ⌃⌥` or
     click the grip above the window to switch.」。
  c. 拖动进堆：⌃⌘/⌥⌘ 拖标题栏到某格、或拖悬停条芯片到某格（见 §5）。
  d. 上限放宽时：最大堆叠格中最久未用的非顶层成员会被拆出自成一格
     （显示文本该段有缺损，此条置信度中）。
- 切换方式：点握把圆点/格子顶缘圆点/悬停条芯片/‹ ›；⌃⌥` 下一个、
  ⌃⌥⇧` 上一个；无堆叠时 ⌃⌥` 提示「Nothing stacked here / A full screen
  stacks new windows in the tile you’re in.」。
- 格子本身不动：切换只换顶层窗口，格子位置尺寸不变；激活某成员时
  若它不是顶层则升为顶层。

## 5. 拖动

- 三种拖动 kind：move（标题栏）、chip（悬停条芯片）、split（分隔缝）。
  指针捕获 + 移动超 4pt 才算拖动；自由拖动时 y 不小于 24（不进菜单栏）。
- 修饰键判定：按住 ⌘ 或 ⌃ → swap；再加 ⌥ → stack；都不按 → none。
  即：⌘拖=交换，⌃⌘/⌥⌘拖=进堆（与设置页文案一致）。
- 拖动中：被拖窗口跟随指针（帧 = 指针位置）；目标格 = 指针所在格
  （排除自身所在格）；目标格出现 drop 高亮（chip 拖为「Move here」，
  stack 模式为「Add to stack」）。
- 松手：
  - 目标格 + swap → 两格顶层互换并激活被拖窗；
  - 目标格 + stack（且 whenFull=stack）→ 被拖窗进目标格顶层，
    原格若空出顶层则按最近使用重定；
  - 无目标 + 窗口未分格（浮动/溢出/堆叠后排）→ 提交自由帧；
  - 无目标 + 已分格 + 普通拖 → 不动并提示「A plain drag never
    rearranges. Hold ⌘ to swap.」（即弹回）；
  - 拖动中若处于 Focus → 先退出 Focus 再结算。
- 分隔缝：仅在已整理 + 平铺开 + 非 Focus + 非 Clean 时渲染，取全部帧
  的前 n-1 条缝；竖缝宽 12、横缝高 12，缝上 12px 热区；拖动时按 §2 的
  换算把指针坐标换算成 ratios 并实时重算；缝拖动时窗口动画时长归零（跟手）。
- 芯片拖：未移动时松手 = 激活该成员；移动后有目标 = 进堆，无目标 = 激活（不进堆）。

## 6. Focus

- 进入：悬停条 Focus 按钮 / ⌃⌥Z / 引导演示；条件：已整理 + 平铺开 +
  快捷键开（键盘路径）+ 有分格窗口；取活动窗（若活动窗未分格则取首格）。
- 形态：专注窗帧 = 工作区四边各内缩 gap（几乎铺满，除菜单栏与 Dock）；
  其余窗口帧未动、仍渲染在原位，但专注窗置顶盖住全部——视觉上其余
  窗口完全隐藏（盖住而非卸载；这是 13:04“完全隐藏”的机制补充）。
  专注窗标题栏下出现「Focus · ⌃⌥Z to put it back」。
- 退出：再按 ⌃⌥Z / 点 Exit focus；退出即精确还原（含堆叠关系与
  Primary），因为其余窗口帧在整个过程中根本没动过，专注窗回到原格帧。
  点专注窗内容不退出。拖动专注窗会先退出 Focus。
- 引导演示中的 Focus：试用标记后 1800ms 自动退出（仅引导流程）。
- 专注态悬停条：代码未见专注态专属禁用分支；实测“专注模式下悬停栏
  唤不出来”以表现层一致计（条的锚点是活动格握把中心，专注时握把即
  屏幕上方中央），未断言代码分支。

## 7. Float

- 脱离：悬停条 Float / ⌃⌥F；条件与 Focus 类似；脱离帧 = 工作区内缩
  gap 后取 60% 宽 × 75% 高并居中；其余窗口立即重排。
- 悬浮窗：不参与分格，可自由拖动；其悬停条第三个按钮变 Tile，
  且 Primary/Focus 变 disabled（见 §3）。
- 回铺：悬停条 Tile / 再按 ⌃⌥F → 取消浮动，重新参与分格重算
  （重新排布，非精确恢复到脱离前的位置）。
- whenFull=float 时的新窗：不进格，直接居中浮动（自然尺寸），
  直到有空位（重算时自动回铺）。

## 8. 快捷键全表

- 生效前提：除特别注明外均需 ⌃⌥；⌃⌥⌘数字与 ⌃⌥D/P 另需 shortcuts 开 +
  已整理；Tab 视图内按键另有分支。
- ⌃⌥←/→/↑/↓：与左/右/上/下邻格交换（方向判定见 §2）。
- ⌃⌥↩：Make primary（活动格与首格互换顶层；已是首格则仅激活）。
- ⌃⌥]/[：激活下一个/上一个分格窗口（沿 tiled 顺序循环）。
- ⌃⌥` / ⌃⌥⇧`：本格下一个/上一个成员。
- ⌃⌥=/-：活动窗变大/变小（按分组调整 ratios）；⌃⌥0：重置本屏尺寸。
- ⌃⌥F：Float/Tile 切换；⌃⌥Z：Focus/退出；⌃⌥D：No peek 开关；
  ⌃⌥P：Clean Space 开关。
- ⌃⌥⌘1–4：本屏分格窗数上限 1–4（需 shortcuts + 已整理）。
- ⌥Tab（仅 ⌥，不带 ⌃⌥⌘）：打开 Tab 视图；视图内 Tab/⇧Tab 移动选择、
  方向键选择、Enter 确认、Esc 关闭；选最小化窗口则恢复，选堆叠后排
  则激活。
- Esc：关闭 Tab 视图，否则关闭菜单栏面板；全屏模式下 Esc 退出全屏
  （面板/Tab/设置开着时不退出）。
- 面板内 ⌘,：打开设置（设置页链接）；设置页红灯关闭设置。

## 9. 菜单栏面板与设置页

### 9.1 菜单栏面板

- 状态头（Shoji + 状态点 + 状态文案：Tiling N windows / Focus mode · N windows /
  Automatic tiling is off / Waiting for setup to finish）+ Automatic tiling 开关；
  未整理时有提示条「Shoji is waiting to tidy this desktop.」+ Tidy it 按钮。
- 面板预览：292 宽布局缩略图（格子按实际帧比例画，活动格高亮、非专注格
  在 Focus 时 dim、堆叠格显示成员数、专注格标 Focus）；无窗时提示
  「No windows to tile on this screen」或「Tiling is off」；有 ratios 时出现 Reset sizes。
- 面板「Windows on this screen」：布局四选（Grid/Columns/Rows/Side，带
  30×17 预览）+ 格数 1–4（超 fit 的档位 disabled，未整理时全 disabled）+
  非 fold 且 fit<4 时注记「This screen fits N … Pick Grid for four.」。
- 面板快捷区：Retile（提示「Arranged again」）、Borders（none↔allBorders 切换）、
  Hover focus 开关；Clean Space 行（⌃⌥P 键帽 + 开关）、No peek mode 行
  （⌃⌥D 键帽 + 开关）+ Dim strength 滑杆（0.1–0.9，步进 0.05，显示百分比，
  仅 dim 开时出现）；活动应用行（Tile <应用名> 开关 = per-app 排除）；
  Settings（⌘,）与 Keyboard shortcuts（shortcuts 关时标 Off）链接；
  Quit Shoji 按钮 → 提示「Nice try. It’s a demo, it stays.」。

### 9.2 设置页（8 页，左侧栏 + 红灯关闭）

- General：Automatic tiling、Open at login、App icon（Washi、Lantern 等多款）、
  Clean Space 背景色（graphite #2a2a2d / stone #6e6c68 / mist #d9d8d4）、
  Accessibility access（静态「Allowed」，注“从不读窗口内容”）、
  Welcome tour（两分钟引导）。
- Layout：布局四选、Main window size（Half / 60% / Two-thirds）、
  Windows per screen（1–4）、When a screen is full（Stack in the active
  tile / Float in the middle 二选一）、Space between windows
  （0–24，步进 2，注“同时用作屏边缘留白”）。
- Highlight：Highlight 四选（None / Border on active / Border on all /
  Glow on active，注“高亮画在窗口间隙里，永不遮盖窗口内容”）、
  Border thickness（2–6，步进 1；边框模式下提示“间隙会长到 N pt 来容纳”）、
  Color（Accent/Purple/Pink/Orange/Green/Graphite；highlight=none 时禁用，
  注“Accent 跟随 Mac 系统色”）。
- Mouse：Quick actions above windows（悬停条开关）、Activate windows on
  hover（Hover focus 开关）、Always available：Swap two windows（Hold ⌘
  拖到另一窗）、Add to a stack（Hold ⌥⌘ 拖到某格）、Resize（拖两窗之间
  的边）、Move to another screen（拖到另一块屏）。
- Keyboard：Keyboard shortcuts 总开关（关时表仍列出供学习，行变暗）+
  四组表（Move / Activate / Size / More，内容见 §8）。
- Apps：Don’t tile these apps（被排除应用逐个「Tile X again」恢复；
  无排除时「Shoji tiles every app.」；Add an open app 行可把在用应用
  加进排除；被排除应用的窗口保持自由帧、不参与分格）。
- Activity：本周分格窗口数、Time saved（相对手拖）、Shortcuts used
  （最常用 + 次数；无记录时「No shortcuts yet.」）、注记「Numbers only,
  kept on this Mac. Never window titles or app names.」。
- About：Runs on this Mac / Never reads windows / Sends nothing（注
  “Shoji arranges windows without looking inside them.”）。

## 10. 打开 / 关闭 / 最小化 / 激活流程

- 打开（Dock 图标点按 / 引导开 mail）：新窗自由帧 = 自然尺寸居中 +
  (nextId%5×22-44) 的对角偏移；同款第 n 个 variant 轮换；立即成为
  活动窗并置顶；已整理且平铺开时计入 placed；若重算后溢出（未分格）
  则 300ms 后提示「This Space is full / ⌘-drag a window onto a pane to swap.」。
- 关闭（红灯）：窗口移出集合；活动窗回落到剩余窗中最近使用者
  （排除最小化窗）；是专注窗则退出 Focus；是浮动窗则解除浮动。
- 最小化（黄灯）：进 minimized，minimizedFrom 记下同格另一成员（供
  恢复时回格）；Dock 出现最小化区（点按恢复）；恢复时回到原格并成为
  顶层；活动窗最小化时活动权按最近使用转移。
- 激活（点窗体/芯片/圆点/Tab 选择）：成为活动窗、移到 z 顶、used/clock
  更新；若它在某格非顶层则升为顶层；若另一窗正专注则退出 Focus。
  Hover focus 开时：指针在某窗停留 150ms 即激活它。
- 平铺开关：关 → 全部窗口以当前帧为自由帧（原地散开，zoom 清除）；
  开（已整理过）→ 播放提示音 + sweep 动画并重算。
- Tidy（首次整理）：播放提示音（WebAudio：1396.9Hz 基频 + 1/2/2.76/5.4
  倍频泛音，增益 0.16），tidied=true、tiling=true、sweep+1、placed 累加
  当前窗数。

## 11. 最小尺寸与装不下

- 自然尺寸（见 §1）；自由帧居中函数：宽/高分别 min(自然, 工作区-40) 后居中。
- 分格门槛：minSection 480×320（按屏缩放），columns 时宽下限 440（缩放值）；
  帧计算时逐格验证，任一格不达标即降格子数；单窗恒接受。
- 装不下时的两条路（When a screen is full）：
  stack（默认）：新窗/溢出窗进活动格（或最近使用格）顶层；
  float：各格只留顶层，其余成员全部回到自由帧（居中自然尺寸）。
- 溢出窗的自由帧：自然尺寸居中，不在任何格内，直到重算有空位。
- 份额收敛：见 §2（12 轮二分）。ratios 自定义后不再自动收敛份额。

## 12. 对话框 / 面板类窗口是否排除

- demo 里没有系统对话框/面板类演示窗口；全部演示窗口均为标准应用窗。
- 不进分格的 UI 一律是 demo 自身的覆盖层，均带 stopPropagation 且
  不参与 tile 计算：悬停条、握把、圆点、分隔缝、菜单栏面板、设置页、
  Tab 视图（含其 catcher 点按关闭）、引导 coach、提示 hud、Dock、
  菜单栏；分隔缝与 Tab catcher 点按会关闭面板/Tab。
- 窗口红绿灯：红=关闭、黄=最小化（均 stopPropagation，不触发激活外的
  拖动）；绿灯为 inert span（无动作）。
- 被排除的应用（Apps 页）窗口：保持自由帧，不参与分格与重算。

## 13. 多屏

- demo 本身是单屏画布（工作区一个）；Tab 视图标题写「Built-in Display」。
- 多屏行为只存在于文案层：设置页「Move to another screen：Drag a
  window onto the other screen.」；布局/上限/主窗份额的文案均按
  “on this screen / Every screen starts with this number”表述（即
  真实应用按屏独立，demo 不模拟第二块屏）。

## 14. 提示 / toast / 引导文案

- 提示（notice）统一 2600ms 自动消失；图标 + 标题 + 可选正文；计数 n 累增。
- 提示文案全集（标题 / 正文 / 触发）：Arranged again（Retile）；Stacked in
  this tile / Press ⌃⌥` or click the grip…（首现进堆）；This Space is full /
  ⌘-drag a window onto a pane to swap.（开窗溢出）；That’s plenty for a demo /
  On your Mac, open as many as you like.（超 9 窗）；Nothing stacked here /
  A full screen stacks new windows in the tile you’re in.（空格 ⌃⌥`）；
  A plain drag never rearranges. Hold ⌘ to swap.（普通拖已分格窗）；Open
  another window first（格数 <2 时的 swap/resize 演示）；Open a window
  first（无窗时的 focus 演示）；No peek mode on/off（正文含 ⌃⌥D 往返提示）；
  Nice try. It’s a demo, it stays.（Quit）；布局/格数切换提示（样式名 + 拟合
  说明，如「Columns on this screen fits up to 3.」）；1 window / Up to N
  windows（格数切换）。
- 引导（coach，7 步，顺序见下；Show me 自动演示；可 Skip；试用过的步
  不再出现；当前步试用后 1100ms 过渡到下一步；全部完成显示「You’ve got
  it.」+ 进度条 100%）：
  1. tidy「Look familiar?」：三窗堆叠、相互遮挡一半——点 Show me 整理。
  2. layout「Prefer a different layout?」：点菜单栏图标选布局/格数，或
     ⌃⌥⌘+数字——Show me 开面板并在 450ms 后切换 fold↔columns。
  3. stack「Need your mail too?」：屏满时新窗进活动格顶层、不遮挡——
     Show me 切到已堆叠格并 ⌃⌥`，或先开 mail 再切。
  4. swap「Want them the other way round?」：⌘拖标题栏互换，或 ⌃⌥+方向键。
  5. resize「One window feels cramped?」：拖两窗之间的线，另一边让位。
  6. focus「Time to concentrate?」：悬停条 Focus 或 ⌃⌥Z（演示中 1800ms
     后自动退出）。
  7. customize「Make it yours」：菜单栏面板的 No peek / Clean Space 等。
- 引导辅助 UI：hint 气泡（带指针光标动画，可演示拖动路径与按键）、
  coach 卡片（步骤 x/7 + 进度条 + Show me/Skip）、完成态 celebrating。

## 15. 其它行为

- 动画：窗口移动弹簧（bounce .16，duration .62）；拖动/拖缝时动画时长
  归零；窗口入场 opacity 0/scale .9 → 1；退场：最小化窗 opacity 0/scale .2
  并下沉 45% 屏高（.32s），其余 opacity 0/scale .9（.2s）；悬停条/提示/
  Tab 视图各有 .12–.25s 过渡；支持 prefers-reduced-motion（引导 Show me
  降级为直接执行）。
- 边框/高亮渲染：边框以 box-shadow 轮廓画在窗口间隙里（不盖内容），
  宽 = borderWidth，色 = 所选 swatch 或系统 Accent；allBorders 全画、
  activeBorder 只画活动窗、glow 在活动窗上方画一条 80% 宽的线
  （y = 格上沿 - max(gap,4)/2 - 1.5）；highlight=none 时颜色选择禁用。
- No peek（dim）：活动窗下一层盖一张全屏 veil（rgba(0,0,0,dimAmount)，
  可选 blur(28px) 背景模糊），其余窗口变暗但仍可正常操作（设置页注
  “Nothing is covered or changed: windows under the dim still work as
  usual.”）；菜单栏与 Dock 不受影响。
- Clean Space：活动窗居中，两侧滑入纯色面板（graphite/stone/mist），
  宽分别为活动窗左缘与右缘余量；开 Clean 时悬停条与分隔缝不渲染。
- 菜单栏：左侧为活动应用名（无活动时 Finder）+ Shoji 图标（点按开关
  面板），右侧时钟；面板开时点 demo 其它区域（catcher）关闭面板。
- 统计：placed（整理/打开计入的窗数）、shortcuts（快捷键次数）、moves
  （交换/进堆次数）、used（分快捷键计数）；Activity 页只展示数字，
  不展示窗口标题与应用名。
- 菜单栏时钟每 15s 刷新；Dock 图标悬停放大（46×(1+0.42s²)，s 为距离衰减）
  + 运行圆点 + 最小化区。

## 16. 与 13:04 浏览器实测逐条对照（全部一致）

- Primary 互换格子、尺寸随格子变 → 一致（活动格顶层与 tiled[0] 互换，帧随格走）。
- Primary 无专属边框 → 一致（边框只来自 highlight 模式，与 Primary 无关）。
- 已是 Primary 时按钮 disabled → 一致（disabled = 是首格 或 悬浮窗）。
- Focus 铺满（除菜单栏 Dock 外）→ 一致（帧 = 工作区内缩 gap）。
- Focus 其余窗口完全隐藏 → 一致（视觉）；机制补充：专注窗置顶盖住，
  其余窗口仍渲染在原位（非卸载）。
- Focus 底部提示 ⌃⌥Z 退出 → 一致（文案逐字相同）。
- Focus 退出精确还原（含堆叠与 Primary）→ 一致（其余窗口帧全程未动）。
- 点专注窗内容不退出 → 一致（无此退出路径；只有 ⌃⌥Z / Exit focus /
  拖动专注窗会退出）。
- 专注模式下悬停栏唤不出来 → 表现层一致（见 §6 末）。
- Float 脱离网格、居中明显缩小 → 一致（60%×75% 居中）。
- Float 可拖动标题栏 → 一致（moveFree）。
- Float 其余立即重排 → 一致（取消分格后即时重算）。
- 悬浮窗悬停栏第三按钮变 Tile、Primary/Focus 变 disabled → 一致。
- 点 Tile 重新排布（非精确恢复）→ 一致（取消浮动后重算，不记脱离前帧）。
- 悬停栏只对活动窗口顶部中央蓝色小圆手柄出现 → 补充：代码里的握把
  是中性圆点/药丸（颜色由样式定，demo 中呈蓝色系小圆点），锚点确为
  活动格顶缘中央；“只对活动窗口”准确。
- 深色药丸条居中压在窗口上沿 → 一致（440×54，锚点格顶缘中央，
  工作区内夹取）。
- 点任一按钮后消失 → 一致。
- 指针移开后短暂淡出 → 一致（350ms 关闭计时 + .12s 退场）。
- 堆叠：新窗口堆进活动窗口所在格 → 一致（whenFull=stack 默认；但
  注意 whenFull=float 时改为居中浮动，实测默认态为 stack）。
- 点格子顶部中央切换柄切换、格子不动 → 一致（握把/圆点切换只换顶层）。

## 17. 未确证与缺口（不再展开猜测）

1. Mark 拆分器本体（fold/side/columns/rows 的 v/b/y、包围盒 x、分组 h、
   比值 C/j）与 desktop 的 ee() 尾部、tile 重建中段：browser.open 显示文本
   提取有缺损，未恢复；§2.5 分组结论与 §4(d) 拆格规则置信度中。
2. 专注态悬停条：代码未见专注态专属禁用分支，实测“唤不出来”以表现
   层一致计，未断言代码分支。
3. react-dom / motion / AnimatePresence：通用运行时，未入闭包；其行为
   （弹簧插值细节、进出场动画）不影响行为清单结论。
4. config：定价/结账配置，已确认身份但未转存、未引用取值（超出行为范围）。
5. 真实应用与 demo 的差异：本规格只描述 demo；真实应用的窗口采集、
   多屏、持久化、授权流程均不在 demo 代码中，无从确证。
6. REA 版本说明：本地实装是 6.4.0（此前记录称 6.8.0，未见该版本）；
   analyze-javascript-application 在本输入上只产出模块/导入图
   （30 节点、83 边），无函数级节点——行为细节来自直接精读，
   报告中已区分两种来源。

## 18. 搬运到 TileProto 的对照（简版）

已对齐（2026-10-27 13:15 / P0 两轮后）：Primary 互换、Focus 精确还原、
Float 居中与 Tile 回铺、悬停条三按钮、堆叠切换、⌘拖交换与普通拖弹回、
拖缝同步与顶回、学习最小尺寸与溢出浮动、高亮 Accent 固定、变暗固定。
本轮 P0 后仍待用户鼠标验证：悬停条出现/点击、拖缝手感、⌘交换、Focus 点击。
demo 有、TileProto 尚无（按 DEMO-GAP-2026-10-27.md 本轮不做）：
布局族 Grid/Columns/Rows/Side、主窗份额 Half/60%/⅔、间距可调、
减弱其他（No peek / Dim 滑杆）、演示清屏（Clean Space）、Borders 四档、
Tab 视图（⌥Tab）、7 步引导、per-app 排除、Activity 统计。
注：TileProto 已按用户定型走鼠标 + 菜单栏 only 路线，全局快捷键不恢复；
上表快捷键仅作 demo 行为记录，不作为 TileProto 的恢复清单。
